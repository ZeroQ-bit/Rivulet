# Lazy HLS Remux — Session Notes

**Date:** 2026-03-31 → 2026-04-01
**Status:** Working — sustained playback confirmed for H.264 and HEVC content

## Goal

The FFmpeg remux pipeline (Plex → FFmpegRemuxSession → LocalRemuxServer → AVPlayer) was too slow to start and couldn't handle seeking. We want a continuous streaming flow that feels like Plex direct play — fast startup, full seekability.

## Architecture

```
Plex Server (MKV/DTS/DV files)
       ↓ HTTP
FFmpegRemuxSession (actor)
  ├─ open(): format probe + estimated 6s segment list
  ├─ generateInitSegment(): moov atom (cached, delay_moov)
  ├─ generateSegment(N): seek + read packets + mux fMP4
  │     ├─ DTS synthesis: monotonic counter, carried across sequential segments
  │     ├─ tfdt patching: overwrite delay_moov's 0 with actual DTS (both tracks)
  │     └─ duration fix: set packet.duration = frameDur after rescaling
  └─ interruptFlag: nonisolated pointer for immediate I/O abort
       ↓
LocalRemuxServer (NWListener on localhost)
  ├─ /master.m3u8 → HLS master playlist (codec-aware CODECS string)
  ├─ /stream.m3u8 → media playlist (+ INDEPENDENT-SEGMENTS, + EXT-X-START)
  ├─ /init.mp4 → cached init segment
  └─ /segment_N.m4s → direct generation or cache hit, 3-segment read-ahead
       ↓ seek → sets interruptFlag = 1 → stale av_read_frame aborts
AVPlayer + AVPlayerViewController (HLS client)
  ├─ automaticallyWaitsToMinimizeStalling = false (prevents deadlock)
  ├─ playImmediately(atRate:) for initial play
  ├─ KVO on isPlaybackLikelyToKeepUp + 500ms delayed resume for buffer recovery
  └─ KVO-based waitForCurrentItemReady (not polling)
```

## What Was Implemented

### 1. Simplified open() — estimated segments
`open()` just estimates segments from duration at 6s intervals. No I/O beyond format probing (~150-700ms).

### 2. Direct generation + read-ahead server
LocalRemuxServer serves segments on-demand with 3-segment read-ahead. Seek detection cancels stale read-ahead. Cache holds 60 segments.

### 3. Prefetch init + target segment
Before starting the server, pre-generate the init segment and the target segment (using EXT-X-START offset). AVPlayer gets instant cache hits on first request → readyToPlay in ~1.5-2s.

### 4. FFmpeg interrupt callback
`interruptFlag` (nonisolated pointer) allows the server to abort in-progress `av_read_frame()` immediately when a seek is detected. Reduces seek response from ~4s to ~50ms.

### 5. Sequential seek skip + DTS continuity
Sequential segments skip `avformat_seek_file` (expensive HTTP range request). DTS is carried across sequential segments via `continuationVideoDTS` actor state, ensuring `baseMediaDecodeTime` is continuous across segments.

### 6. tfdt patching (THE critical fix)
`delay_moov` normalizes all timestamps to 0 for each per-segment muxer context. After stripping ftyp/moov, the moof's tfdt always shows `baseMediaDecodeTime=0`. We patch BOTH video and audio track tfdt with the actual DTS values post-muxing. Without this, every segment claims to start at time 0 → AVPlayer can't build a timeline.

### 7. Sample duration fix
Packet durations of 1 tick in source timebase (e.g., 1/1000) rescale to 0 in output timebase (e.g., 1/25) via integer division. Now sets `packet.duration = frameDur` after DTS synthesis, ensuring non-zero sample durations in the trun box.

### 8. Audio endPTS filter removal
Audio packets were filtered by the estimated `endPTS`, but video reads far past `endPTS` to reach the actual keyframe. This consumed audio packets without writing them, leaving sequential segments with only a 1-sample primer. Removed the filter — audio naturally stops when the video loop breaks.

### 9. Codec tag fixes
Apple HLS requires specific codec tags — FFmpeg defaults are wrong:
- HEVC → `hvc1` (0x31637668), NOT FFmpeg's default `hev1`
- DV → `dvh1` (0x31687664)
- H.264 → `avc1` (0x31637661)
Master playlist CODECS string dynamically matches the actual video codec.

### 10. Buffer recovery
With `automaticallyWaitsToMinimizeStalling = false`, AVPlayer pauses (rate=0) on buffer underruns instead of waiting. We observe `isPlaybackLikelyToKeepUp` via KVO and auto-resume when buffer refills. Also a 500ms delayed resume in the rate observer as fallback.

### 11. Miscellaneous
- Connection leak fix in `waitForCachedSegment`
- `#EXT-X-INDEPENDENT-SEGMENTS` in playlists
- Instant exit via `interruptFlag` before actor cancel/close
- Skip redundant seek for segment 0 (`isFirstSegmentFromStart`)
- Skip tiny trailing segments (< 1s)
- `[Remux]` tagged diagnostic logging throughout

## What Was Tried and Reverted

### Timestamp rebasing (REVERTED early)
Tried rebasing PTS to match expected playlist positions. Made things worse — reverted. The actual fix was tfdt patching + DTS continuity.

### Chunked transfer encoding (REVERTED)
Sent HTTP 200 headers immediately with `Transfer-Encoding: chunked` for slow segments. AVPlayer misinterpreted the delivery rate and deadlocked in `evaluatingBufferingRate`. Reverted to Content-Length responses — with interrupt callback, generation is fast enough.

### Cue preload at open() (REVERTED)
Sought near end of file to force MKV Cue loading. Added 6+ seconds to startup and sometimes caused HTTP reconnection errors. Removed.

### Keyframe scanning at open() (REVERTED)
Scanned first 60s of packets to find keyframe interval. Took 4-5s, and the average interval didn't represent the actual irregular GOPs. The estimated segments + tfdt patching approach works better.

### 2-second segments (REVERTED)
Tried reducing segment duration to 2s. Generation time (~1.5-2.5s) exceeded the 2s real-time threshold. 6s segments generate in ~300-700ms — well under real-time.

### automaticallyWaitsToMinimizeStalling = true (INCOMPATIBLE)
Default setting causes `toMinimizeStalls` deadlock after seeks — AVPlayer evaluates buffering rate, sees slow delivery, refuses to play despite having 60+ seconds buffered. `playImmediately(atRate:)` can't override `toMinimizeStalls`. Must use `= false`.

### EXT-X-START with PRECISE=YES (REVERTED)
Caused AVPlayer to take 12+ seconds for readyToPlay. Without PRECISE, readyToPlay is fast with prefetched target segment.

## Critical Discoveries

### 1. delay_moov normalizes tfdt to 0
Each segment creates a new `AVFormatContext` with `delay_moov`. The muxer always writes `baseMediaDecodeTime = 0` in the tfdt box because it treats each context as a new movie. **Must patch tfdt in the binary output.**

### 2. Integer division kills sample durations
Source timebase 1/1000 → output timebase 1/25. Packet duration of 1 tick: `1 * 25 / 1000 = 0` (integer division). The muxer writes 0-duration samples in trun → AVPlayer can't calculate presentation times.

### 3. Audio must cover the full video range
The estimated `endPTS` filter caused audio to stop at the estimated boundary while video read to the actual keyframe (often much further). This left sequential segments with only a 1-sample primer. Removing the filter fixed it.

### 4. AVAssetResourceLoaderDelegate can't serve segments
Research confirmed: only playlists and keys can be served via `respondWithData`. Segments MUST come from HTTP. The local NWListener server is the only viable approach for HLS + AVPlayerViewController.

### 5. AVPlayer's buffering evaluation deadlocks on local content
`automaticallyWaitsToMinimizeStalling = true` → `toMinimizeStalls` → deadlock (segments flowing but AVPlayer won't play). Only fix: `= false` + our own buffer recovery via KVO.

## Current Test Results (2026-04-01)

| File | Codec | Container | Audio | Startup | Sustained |
|------|-------|-----------|-------|---------|-----------|
| 176799 | HEVC 1080p | MKV | EAC3 | readyToPlay 1.6s | 90s continuous ✓ |
| 160628 | H.264 720p | MKV | AAC | readyToPlay ~2s | 90s continuous ✓ |
| 175286 | HEVC 1080p | MP4 | AAC | AVPlayerDirect (no remux) | N/A |
| 143855 | HEVC 4K DV P4 | MKV | TrueHD | FAILED: -12927 | DV P4 unsupported |

### moof Structure Verification

```
Seg0 video: tfdt=0       samples=144  trackId=1  (HEVC)
Seg1 video: tfdt=94464   samples=120  trackId=1  (continuous ✓)
Seg2 video: tfdt=173184  samples=120  trackId=1  (continuous ✓)

Seg0 audio: tfdt=0       samples=188  trackId=2
Seg1 audio: tfdt=336384  samples=157  trackId=2  (non-zero ✓)
Seg2 audio: tfdt=625152  samples=157  trackId=2  (non-zero ✓)
```

## Known Remaining Issues

1. **Initial brief pause** — At 0.0s after play(), buffer is empty momentarily. Recovers via keepUp KVO within ~100ms. Cosmetic.
2. **DV Profile 4** — `dvh1` codec tag causes -12927 error. May need `dvhe` for P4, or P4 may be unsupported in HLS.
3. **"No keyframe found" errors** — Happens at certain segment boundaries (irregular GOPs). Reconnect recovers but adds latency.
4. **Seeking not yet tested** — Startup and sustained playback confirmed, but seek-resume flow needs verification.
5. **EXTINF approximation** — Playlist declares 6.0s per segment, actual varies. With correct tfdt this is handled by AVPlayer, but may cause minor seek position inaccuracy.
6. **AirPlay audio-only bug** — Some MP4 files over AirPlay show video but no audio (separate issue, filed in `Docs/bugs/`).

## Files Changed

| File | Summary |
|------|---------|
| `FFmpegRemuxSession.swift` | DTS continuity, tfdt patching, duration fix, audio endPTS removal, interrupt callback, codec tags, sequential seek skip |
| `LocalRemuxServer.swift` | Direct generation + read-ahead, seek detection, INDEPENDENT-SEGMENTS, codec-aware CODECS, actual duration tracking |
| `UniversalPlayerViewModel.swift` | Prefetch + EXT-X-START, KVO readyToPlay, playImmediately, buffer recovery, automaticallyWaitsToMinimizeStalling=false |
| `Docs/bugs/avplayer-direct-audio-only-airplay.md` | Bug report for AirPlay audio-only issue |
| `Docs/bugs/remux-stale-connection-after-pause.md` | Bug report for stale connection after long pause |
