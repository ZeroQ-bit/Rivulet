# Lazy HLS Remux — Design Spec

**Date:** 2026-03-31
**Status:** Approved

## Problem

The FFmpeg remux pipeline (FFmpegRemuxSession + LocalRemuxServer) has two critical issues:

1. **Slow startup (600-2500ms):** `open()` scans keyframes from the container index or probes up to 20k packets. Preflight then generates init + first segment before AVPlayer sees a URL.
2. **Broken seeking:** Seek requests wait behind a sequential producer queue (100ms polling, 5s timeout) before falling back to direct generation. Users experience multi-second stalls.

## Solution

"Lazy HLS" — keep HLS VOD serving to AVPlayer, but remove all upfront work and generate everything on demand.

## Design

### FFmpegRemuxSession Changes

**`open()` simplification:**
- Keep: `avformat_open_input`, `avformat_find_stream_info`, DV detection, audio analysis, audio transcoder setup
- Remove: `buildKeyframeSegmentList()` (container index scanning)
- Remove: `probeKeyframeInterval()` (20k packet probe)
- Remove: `usesEstimatedSegments` flag and `actualSegmentStartPTS` tracking
- Segments are always estimated from duration: `ceil(duration / 6.0)` segments, each ~6s, with startPTS computed from `index * 6.0` in stream timebase

**`generateSegment()` keyframe snapping:**
- Seek to estimated time position for the segment
- Skip packets until first video keyframe at or after seek target
- Read packets until next video keyframe at or after estimated end time
- Mux into fMP4 fragment (per-segment avformat output context, same as today)
- No cross-segment state tracking needed — each generation is self-contained

**`generateInitSegment()`:**
- Same logic as today (write one video + one audio packet to produce moov)
- Generated on first request instead of preflight

### LocalRemuxServer Changes

**Delete sequential producer system:**
- Remove: `producerTask`, `producerCursor`, `producerMaxRequested`, `producerLookahead`
- Remove: `runSequentialProducer()`, `requestSequentialProduction()`
- Remove: `waitForCachedSegment()`, `shouldPrioritizeDirectGeneration()`
- Remove: `producerLock` and all associated locking

**Direct generation model:**
- Segment request → check cache → miss → generate immediately → cache → respond
- After serving, kick off background generation of next 2-3 segments (fire-and-forget)
- Background results go into cache; if AVPlayer asks before they finish, direct generation handles it

**Keep:**
- Segment cache (ring buffer, 60 slots)
- Init segment caching
- HLS playlist serving (master + media + init + segments)
- HTTP response helpers
- NWListener infrastructure

### UniversalPlayerViewModel Changes

**Remove preflight in `loadWithRemuxServer()`:**
- Before: open → generateInitSegment → generateSegment(0) → validate → create server → start → load AVPlayer
- After: open → create server (no prebuilt data) → start → load AVPlayer
- Init segment and first media segment generated on-demand when AVPlayer requests them
- If generation fails, AVPlayer gets HTTP 500, existing fallback-to-Plex-HLS handles it

## Unchanged

- Init segment generation internals (moov writing, EAC3 dec3 box handling)
- Media segment muxing internals (fMP4 output format)
- Audio transcoding (DTS/TrueHD → EAC3)
- DV P7 → P8.1 conversion
- HLS playlist format
- Segment cache
- Fallback-to-Plex-HLS path

## Expected Performance

| Metric | Current | New |
|--------|---------|-----|
| Startup to first frame | 600-2500ms | 300-800ms |
| Seek latency | 0-5000ms | 100-300ms |
| Lines removed | — | ~200 |
