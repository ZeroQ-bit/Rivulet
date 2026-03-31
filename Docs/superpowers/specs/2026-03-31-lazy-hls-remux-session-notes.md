# Lazy HLS Remux — Session Notes

**Date:** 2026-03-31
**Status:** In progress, needs testing after latest changes

## Goal

The FFmpeg remux pipeline (Plex → FFmpegRemuxSession → LocalRemuxServer → AVPlayer) was too slow to start and couldn't handle seeking. We want a continuous streaming flow that feels like Plex direct play — fast startup, full seekability.

## What Was Changed

### 1. FFmpegRemuxSession — Simplified open() (DONE, working)

**Before:** `open()` scanned keyframes from container index or probed 20k packets (500-1500ms).
**After:** `open()` just estimates segments from duration at 6s intervals. No I/O beyond format probing.

- Deleted `buildKeyframeSegmentList()`, `probeKeyframeInterval()`
- Deleted `usesEstimatedSegments`, `actualSegmentStartPTS` cross-segment tracking
- `targetSegmentDuration` changed from 2s to 6s
- Segments are always estimated: `ceil(duration / 6.0)` segments

### 2. LocalRemuxServer — Direct generation, no producer queue (DONE, working)

**Before:** Complex sequential producer with 12-segment lookahead, 100ms polling, 5s timeout, priority jump logic.
**After:** Direct generation on cache miss + lightweight 3-segment read-ahead.

Key improvements:
- **Seek detection** via `lastRequestedIndex`: only cancels read-ahead on non-sequential requests
- **In-flight tracking** (`inFlightSegments`): prevents duplicate actor calls, allows waiting for read-ahead
- **Stale read-ahead prevention**: `startReadAhead()` refuses to read ahead from positions behind `lastRequestedIndex`
- **Wait abandonment**: `waitForCachedSegment()` gives up immediately if AVPlayer seeked away

### 3. UniversalPlayerViewModel — No preflight (DONE, working)

**Before:** Generated init segment + first media segment before starting server.
**After:** Just `open()` → create server → start → load AVPlayer. Everything on-demand.

### 4. Session lifecycle fix (DONE, working)

**Before:** `stopRemuxServer()` was fire-and-forget — old session's HTTP connections stayed open.
**After:** `stopRemuxServer()` is async, awaits `session.cancel()` + `session.close()`. In sync contexts (`stopPlayback()`), cancel/close is inlined. `generateSegment()` packet loop checks `Task.isCancelled` for cooperative cancellation.

### 5. Sequential seek skip (DONE, untested)

**Before:** Every `generateSegment()` did `avformat_seek_file` — expensive HTTP range request even for sequential access.
**After:** Tracks `lastGeneratedSegmentIndex`. For sequential segments (N+1 after N), skips the seek entirely. The format context is already positioned near the next segment's start. Log shows `(seq)` for skipped seeks.

## What Was Tried and Reverted

### Timestamp rebasing (REVERTED)

**Hypothesis:** The `-12860` (`kCMSampleBufferError_DataFailed`) errors were caused by fMP4 fragment timestamps not matching HLS playlist positions. With estimated 6s segments, actual keyframes might be at 7.2s instead of 6.0s, creating gaps in the timeline.

**Implementation:** Added `videoRebaseOffset`/`audioRebaseOffset` computed from `expectedBasePTS - actual first keyframe PTS`. Applied to all video and audio packets before writing.

**Result:** Made things worse — playback stopped working entirely after seeks. Reverted. The -12860 errors are likely cosmetic warnings, not the cause of playback stalls.

### 6. FFmpeg interrupt callback for seek cancellation (DONE, untested)

**Before:** When the server detected a seek, it cancelled read-ahead Tasks, but the actor was still blocked inside `av_read_frame()` for the stale segment. The seek target segment had to wait 3-5s for the stale generation to finish.

**After:** `FFmpegRemuxSession.interruptFlag` is a `nonisolated(unsafe)` pointer that the server sets to 1 on seek detection. FFmpeg's `interrupt_callback` checks this flag during I/O operations, causing `av_read_frame()` to abort within one poll cycle (~10-50ms). The flag is cleared to 0 at the start of each `generateSegment()` so fresh generations aren't affected.

### 7. Connection leak fix (DONE, untested)

**Before:** `waitForCachedSegment()` returned without closing the NWConnection when it detected AVPlayer had seeked away, leaking the connection.

**After:** Abandoned connections are explicitly cancelled and removed.

### 8. `#EXT-X-INDEPENDENT-SEGMENTS` (DONE, untested)

Added to both master and media playlists. Tells AVPlayer that each segment starts at a random access point and can be decoded independently — important for correct seek behavior.

## Current State

The code is in a testable state with changes 1-8 above. Changes 5-8 are the latest and haven't been tested yet.

**What works:**
- Fast startup (~500ms to first segment)
- Initial playback starts
- Seek handling (read-ahead cancellation, stale segment prevention)
- Second-item playback (async session cleanup)

**What still has issues:**
- `-12860` errors persist (appear to be cosmetic — playback works despite them)
- Segment 1 consistently slow (5-8 seconds) — the sequential seek skip should fix this
- After intro skip, playback stalls after a few seconds (buffer underrun from slow segments)
- **Seek stalls — primary hypothesis:** actor serialization delay (stale read-ahead blocks seek target for ~4s), causing AVPlayer to fail the seek internally. Fix #6 (interrupt callback) should reduce this to <100ms.
- Some files don't play at all (unclear which, might be content-dependent)

## Key Observations

1. **Segment generation speed varies wildly**: 400ms to 8000ms for 6s segments. Over HTTP, seeks are expensive.
2. **The actor serializes everything**: Read-ahead and direct requests queue on the FFmpegRemuxSession actor. Stale read-ahead blocks fresh requests. **Fix #6 mitigates this** by aborting stale I/O immediately.
3. **AVPlayer requests segments aggressively**: It doesn't wait for playback to catch up — it requests the next segment immediately after receiving the current one.
4. **`-12860` errors happen at segment boundaries**: After segment 0 and after the first segment post-seek. They appear to be non-fatal timestamp discontinuity warnings.
5. **Seek log analysis (2026-03-31)**: Segments 47/48 are requested after seek, meaning AVPlayer received segment 46. But playback doesn't resume — likely because the 5.7s delay to serve segment 46 causes AVPlayer's internal seek to fail/stall.

## Files Changed

| File | Summary |
|------|---------|
| `Rivulet/Services/Plex/Playback/Remux/FFmpegRemuxSession.swift` | Simplified open(), removed keyframe scanning, added sequential seek skip, Task.isCancelled checks, interrupt callback |
| `Rivulet/Services/Plex/Playback/Remux/LocalRemuxServer.swift` | Replaced producer with direct generation + read-ahead, seek detection, stale prevention, interrupt on seek, connection leak fix, `#EXT-X-INDEPENDENT-SEGMENTS` |
| `Rivulet/Views/Player/UniversalPlayerViewModel.swift` | Removed preflight, async stopRemuxServer(), inline cancel for stopPlayback() |
| `docs/superpowers/specs/2026-03-31-lazy-hls-remux-design.md` | Design spec (approved) |

## Architecture Reference

```
Plex Server (MKV/DTS/DV files)
       ↓ HTTP
FFmpegRemuxSession (actor)
  ├─ open(): format probe + estimated segment list
  ├─ generateInitSegment(): moov atom (cached)
  ├─ generateSegment(N): seek + read packets + mux fMP4
  └─ interruptFlag: nonisolated pointer for immediate I/O abort
       ↓
LocalRemuxServer (NWListener on localhost)
  ├─ /master.m3u8 → HLS master playlist (+ INDEPENDENT-SEGMENTS)
  ├─ /stream.m3u8 → VOD media playlist (+ INDEPENDENT-SEGMENTS)
  ├─ /init.mp4 → cached init segment
  └─ /segment_N.m4s → direct generation or cache hit
       ↓ seek → sets interruptFlag = 1 → stale av_read_frame aborts
AVPlayer (HLS client)
```

## Next Steps

1. **Test seek after interrupt callback fix** — segment after seek should generate in ~2s (actual generation time) instead of ~6s (blocked behind stale read-ahead)
2. **If stalls persist**: Add diagnostic logging for AVPlayer `timeControlStatus` and `reasonForWaitingToPlay` during/after seeks to determine if AVPlayer enters an unrecoverable state
3. **If timestamps are the issue**: Rebase each segment's PTS so `baseMediaDecodeTime` aligns with the expected playlist position (approach was tried and reverted before — may need more careful A/V sync)
4. **Long-term**: Consider keeping a persistent muxer context instead of per-segment contexts to eliminate overhead and ensure timestamp continuity
