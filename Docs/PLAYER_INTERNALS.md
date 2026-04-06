# Rivulet Player — Internals Reference

A deep reference for the custom Rivulet player. Complements `RIVULET_PLAYER.md` (high-level overview) with file-by-file inventory, critical control flows, and a status tracker for known HDR/DV issues.

> **Scope**: All Swift files under `Rivulet/Services/Plex/Playback/`. UI hosting (`UniversalPlayerView`, `UniversalPlayerViewModel`) is referenced but not catalogued here.

---

## 1. Player at a Glance

```
┌────────────────────────────────────────────────────────────────────┐
│  UniversalPlayerView (SwiftUI)                                     │
│       │                                                            │
│       ▼                                                            │
│  UniversalPlayerViewModel  ──▶  ContentRouter.plan()               │
│       │                              │                             │
│       ▼                              ▼                             │
│  RivuletPlayer ◄─────────  PlaybackPlan { primary, fallbacks }     │
│       │                                                            │
│       ├──▶ DirectPlayPipeline   (primary for native + DV/HDR)      │
│       │       │                                                    │
│       │       ├─ FFmpegDemuxer    (libavformat)                    │
│       │       ├─ FFmpegAudioDecoder (TrueHD/DTS → PCM)             │
│       │       ├─ FFmpegSubtitleDecoder (PGS → RGBA)                │
│       │       ├─ DoviProfileConverter (P7/P8.6 → P8.1)             │
│       │       └─ SampleBufferRenderer  (shared)                    │
│       │                                                            │
│       └──▶ HLSPipeline           (fallback / server transcode)     │
│               │                                                    │
│               ├─ HLSSegmentFetcher                                 │
│               ├─ FMP4Demuxer                                       │
│               ├─ DoviProfileConverter (optional)                   │
│               └─ SampleBufferRenderer  (shared)                    │
│                                                                    │
│  SampleBufferRenderer                                              │
│       ├─ AVSampleBufferDisplayLayer                                │
│       ├─ AVSampleBufferAudioRenderer                               │
│       └─ AVSampleBufferRenderSynchronizer                          │
└────────────────────────────────────────────────────────────────────┘
```

The two pipelines share **one** `SampleBufferRenderer`. Only the source of CMSampleBuffers differs.

---

## 2. File Catalog

Each entry has: file, line count, role, status. Status is one of:

- **Active** — required for current playback paths.
- **Optional** — wired in but only used in narrow conditions (e.g. AirPlay surround re‑encode).
- **Dead** — no live call sites; safe to remove after a final grep.

### Core Player

| File | LOC | Role | Status |
|---|---:|---|---|
| `RivuletPlayer.swift` | 1045 | Top-level player implementing `PlayerProtocol`; bridges DirectPlay and HLS pipelines, owns the renderer, handles AirPlay instability recovery and track selection. | **Active** |
| `PlayerProtocol.swift` | 161 | `PlayerProtocol` contract, `UniversalPlaybackState`, `PlayerError`. No internal Rivulet deps. | **Active** |
| `MediaTrack.swift` | 193 | Unified audio/subtitle track struct shared across UI and engine. Bridges `PlexStream` ↔ engine track. | **Active** |

### Routing & Analysis

| File | LOC | Role | Status |
|---|---:|---|---|
| `Pipeline/ContentRouter.swift` | 342 | Picks one of 4 routes (`avPlayerDirect`, `localRemux`, `hls`, fallback) from `ContentRoutingContext`. | **Active** |
| `Remux/RemuxContentAnalyzer.swift` | 140 | Classifies content (`needsRemux`, `needsAudioTranscode`, `needsDVConversion`) from `PlexMetadata`. | **Active** |

### Pipelines (data path)

| File | LOC | Role | Status |
|---|---:|---|---|
| `Pipeline/DirectPlayPipeline.swift` | 1944 | Main read‑loop: FFmpeg demux → optional DV conversion → optional client audio decode → renderer. Implements preroll, lookahead pacing, late‑frame thresholds, grace period. | **Active** |
| `Pipeline/HLSPipeline.swift` | 520 | Producer/consumer pipeline that downloads HLS segments and feeds the renderer. Used as fallback. | **Active** |
| `Pipeline/SampleBufferRenderer.swift` | 1256 | Owns display layer, audio renderer, render synchronizer; handles push/pull audio modes, optional `AVAudioEngine` mode for stereo AirPlay, lookahead pacing, jitter stats. | **Active** |
| `Pipeline/SegmentBuffer.swift` | 113 | Bounded async actor queue; producer/consumer with capacity 3 for HLS segments. | **Active** |
| `Pipeline/PlaybackJitterStats.swift` | 386 | Frame timing, drift, underrun & enqueue stall metrics. Emits health reports. | **Active** |

### FFmpeg integration

| File | LOC | Role | Status |
|---|---:|---|---|
| `FFmpeg/FFmpegDemuxer.swift` | 1560 | libavformat wrapper. Discovers tracks, applies `AVDISCARD_ALL` to unselected streams (handles 90+ stream MKVs), produces `DemuxedPacket`s, builds `CMFormatDescription`s, contains the dvh1 FD rebuild for DV. | **Active** |
| `FFmpeg/FFmpegAudioDecoder.swift` | 963 | Decodes TrueHD/DTS/etc. to PCM. Batches small frames (~40 samples) into ~960‑sample chunks. Handles TrueHD‑in‑AC3 codec lookup by name hint. | **Active** |
| `FFmpeg/FFmpegAudioEncoder.swift` | 544 | Re‑encodes PCM to EAC3 for AirPlay surround passthrough. | **Optional** (only when `enableSurroundReEncoding`) |
| `FFmpeg/FFmpegSubtitleDecoder.swift` | 226 | PGS / DVB‑SUB → RGBA bitmap subtitle frames. | **Active** |
| `FMP4Demuxer.swift` | 1237 | Manual ISO BMFF parser used by HLSPipeline (init segment + moof/mdat). Supports per‑sample DV conversion via `DoviProfileConverter`. | **Active** (HLS path) |

### Dolby Vision & display

| File | LOC | Role | Status |
|---|---:|---|---|
| `Dovi/DoviProfileConverter.swift` | 235 | Orchestrates per‑frame P7/P8.6 → P8.1 conversion: parses RPU, calls libdovi, strips EL NALs, fixes VPS. Tracks rolling 48‑frame timing. | **Active** (when conversion enabled) |
| `Dovi/HEVCNALParser.swift` | 537 | Length‑prefixed HEVC NAL parsing, RPU extract/replace, EL stripping, VPS `max_layers_minus1=0` patch, hvcC cleanup. | **Active** |
| `Dovi/LibdoviWrapper.swift` | 217 | Swift bindings around `Libdovi` C API: parse RPU, get profile/EL type, convert RPU, write NAL. | **Active** |
| `DisplayCriteriaManager.swift` | 277 | Drives tvOS Match Content (frame‑rate + dynamic‑range) by setting `AVDisplayCriteria` on the window's `AVDisplayManager`. Has zero‑latency path from Plex metadata and a slower URL‑based path. | **Active** |

### Local remux

| File | LOC | Role | Status |
|---|---:|---|---|
| `Remux/FFmpegRemuxSession.swift` | ~800 | Actor that opens a source via FFmpeg and emits HLS init + media segments on demand. Hosts the `interruptFlag` for instant seek cancel. Performs DV P7→P8.1 conversion and DTS/TrueHD → EAC3 transcoding inline. | **Active** |
| `Remux/LocalRemuxServer.swift` | 671 | `NWListener` HTTP server that serves `/master.m3u8`, `/stream.m3u8`, `/init.mp4`, `/segment_N.m4s` from a `FFmpegRemuxSession`. Used by AVPlayer for the `localRemux` route. | **Active** |

### HLS support

| File | LOC | Role | Status |
|---|---:|---|---|
| `HLSSegmentFetcher.swift` | 360 | Fetches Plex HLS master/variant playlists and downloads fMP4 segments. Used by `HLSPipeline`. | **Active** (HLS path) |
| `HLSManifestEnricher.swift` | 239 | `AVAssetResourceLoaderDelegate` that injects `#EXT-X-MEDIA` audio tracks into Plex's master playlist for `AVPlayer`‑native HLS playback. Used by `UniversalPlayerViewModel.swift:1544` (the legacy AVPlayer fallback). | **Active** (legacy AVPlayer path only) |
| `StreamURLCache.swift` | 61 | 5‑minute MainActor URL cache used by detail‑page prewarm. | **Active** |

### Audio session, now playing, progress

| File | LOC | Role | Status |
|---|---:|---|---|
| `PlaybackAudioSessionConfigurator.swift` | 243 | Picks `RouteAudioPolicy` (local / AirPlay stereo / AirPlay multichannel) from a route snapshot. Activates the session with throttling. | **Active** |
| `AudioRouteDiagnostics.swift` | 138 | Singleton that observes route/interruption notifications and logs them. Pure side‑effect logging. | **Active** |
| `NowPlayingService.swift` | 594 | `MPNowPlayingInfoCenter` integration, remote command center, artwork cache. | **Active** |
| `PlexProgressReporter.swift` | 139 | Actor that reports timeline progress / scrobbles to the Plex server. 5s throttle. | **Active** |

### Subtitles

| File | LOC | Role | Status |
|---|---:|---|---|
| `Subtitles/SubtitleManager.swift` | 310 | Loads, parses, and time‑slices text + bitmap cues. `@Published` cue arrays drive the SwiftUI overlay. | **Active** |
| `Subtitles/SubtitleParser.swift` | 457 | SRT, WebVTT, ASS/SSA parsers behind a `SubtitleFormat` factory. | **Active** |
| `Subtitles/SubtitleCue.swift` | 89 | `SubtitleCue`, `SubtitleTrack`, `BitmapSubtitleCue`, `BitmapSubtitleRect` value types. | **Active** |
| `Subtitles/SubtitleClockSyncController.swift` | 105 | `CADisplayLink` 30 fps tick that calls `SubtitleManager.update(time:)` from the renderer clock. | **Active** |
| `Subtitles/SubtitleOverlayView.swift` | 145 | SwiftUI overlay rendering text and bitmap cues, scaled from a 1920×1080 reference frame. | **Active** |

**Total**: ~14,000 LOC across 33 files.

---

## 3. The Two Pipelines

### 3.1 DirectPlayPipeline

The primary path. FFmpeg demuxes the source (file or HTTP) on a background task, then enqueues sample buffers to the renderer.

**Read loop sketch (`startReadLoop`)**

```
loop:
  packet = demuxer.readPacket()       // libavformat
  switch packet.trackType {
    case .video:
      lateness = renderer.currentTime - packet.pts
      if lateness > drop threshold:    // grace period gates this
          softDrop / forcedResync logic
      data = packet.data
      if requiresConversion:           // DV P7 → P8.1
          data = profileConverter.processVideoSample(data)
      sampleBuffer = demuxer.createVideoSampleBuffer(data, FD)
      if first frame:
          renderer.setRate(0, time: packet.cmPTS)   // anchor
      preroll bookkeeping...
      await renderer.enqueueVideo(sampleBuffer, bypassLookahead: preroll)

    case .audio:
      if audioDecoder != nil:
          enqueue to async decode queue (cap 512)
          decoder writes PCM, batches into ~960 samples,
          createPCMSampleBuffer → enqueueAudioBuffer
      else:
          // passthrough
          createAudioSampleBuffer(packet, audioFD) → enqueueAudioBuffer

    case .subtitle:
      if bitmap subtitle decoder available:
          decode → onBitmapSubtitleCue
      else:
          onSubtitleCue (text)
  }
```

**Lookahead pacing** lives in `SampleBufferRenderer.enqueueVideo`. The read task sleeps when `samplePTS - syncTime > maxVideoLookahead` (currently 0.35s non‑DV, 0.6s DV).

**Preroll** is a small handshake near the top of the read loop:

1. First video sample sets `rate = 0` and anchors `prerollAnchorPTSSeconds`.
2. The loop accumulates frames (with `bypassLookahead = true`) until either the audio side is primed AND `videoLead ≥ requiredPrerollLeadSeconds`, or the timeout expires.
3. `renderer.setRate(playbackRate, time: anchor, atHostTime: now + 30 ms)` starts the synchronizer.

The required video lead is now:

| Mode | Required lead |
|---|---:|
| `requiresConversion` (DV P7) | 5.0 s |
| `hasDV` (P8 native) | 0.6 s |
| Everything else | 0.20 s |

**Late‑video & resync thresholds (post‑grace period)**

| Threshold | DV (`hasDV`) | Non‑DV |
|---|---:|---:|
| `lateVideoDropThreshold` | 3.0 s | 1.5 s |
| `forceLateResyncThreshold` | 8.0 s | 4.0 s |
| `maxConsecutiveLateFramesBeforeResync` | 120 | 48 |
| `lateResyncCooldown` | 2.0 s | 1.0 s |
| `softLateDropThreshold` | 3.0 s | 2.0 s |
| `maxSoftLateDropsPerBurst` | 24 | 12 |
| `keyframeResyncThreshold` | 48 | 4 |

**Startup grace period** disables all of the above for the first **15 s** of playback (60 s for DV) so the read loop can fill its buffers and reach steady state without flushing the decoder. This was added after the HDR test that died on the very first frame in a resync cascade.

### 3.2 HLSPipeline

Used as fallback (or for live TV). Producer/consumer:

- **Producer task**: walks segments returned by `HLSSegmentFetcher`, downloads each with up to 3 retries (3/6/9s backoff), puts the bytes into a `SegmentBuffer` (capacity 3).
- **Consumer task**: takes a segment, hands it to `FMP4Demuxer.parseMediaSegment`, and enqueues the resulting samples on `SampleBufferRenderer`. Treats an empty buffer as an underrun and emits `.loading` until segments resume.

Seek deduplicates aggressive scrubbing (drops a seek if it lands within 0.2s of the previous one or 250ms wall‑clock).

`HLSPipeline` shares the same `SampleBufferRenderer`, so the lookahead, preroll, and audio policy logic is identical from the renderer's point of view.

---

## 4. Routing Decision Tree (`ContentRouter.plan`)

```
ContentRoutingContext
  ├─ if isLiveTV               → HLS
  ├─ if forceHLS               → HLS
  ├─ if FFmpeg unavailable
  │     ├─ native container & audio  → AVPlayerDirect (+ HLS fallback)
  │     └─ otherwise                  → HLS
  └─ FFmpeg available
        ├─ native container & audio & no DV P7
        │     → AVPlayerDirect (+ HLS fallback)
        ├─ needs remux & (useLocalRemux || needsDVConversion)
        │     → LocalRemux (+ HLS fallback)
        ├─ needs remux
        │     → HLS (server remux)
        └─ default
              → HLS
```

`needsDVConversion` is currently computed as `dvProfile == 7`. Plex may report `DOVIProfile = -1` for some files; we cast that to `UInt8(255)` and the routing then bypasses the conversion path. Runtime DV detection in `FFmpegDemuxer` (from packet/codecpar side data) corrects this *after* routing.

---

## 5. Critical Flows

### 5.1 Load (DirectPlay)

`UniversalPlayerViewModel.startRivuletPlayback`
→ `DisplayCriteriaManager.shared.configureForContent(videoStream:)`
→ `ContentRouter.plan(for: ctx)`
→ `RivuletPlayer.load(route: plan.primary, startTime:)`
→ `loadDirectPlay(url:, headers:, startTime:, isDolbyVision:, enableDVConversion:)`
→ `pipeline.load(...)`

Inside `DirectPlayPipeline.load`:

1. `demuxer.open(url, forceDolbyVision: ...)` (libavformat).
2. Logs `[DirectPlay] Opened: ...` with the discovered tracks, DV profile, FD presence.
3. **DV lookahead bump** (after open): if `hasDolbyVision || isDolbyVision`, set `renderer.maxVideoLookahead = 0.6`.
4. **Format description rebuild**:
   - `hasDolbyVision && enableDVConversion` → `rebuildFormatDescriptionForConversion(dvProfile: 8, blCompatId: 1)` and create a `DoviProfileConverter`.
   - `hasDolbyVision` only → same call with the actually detected profile/blCompat (no conversion). VideoToolbox needs the dvh1 tag to engage the DV decoder even for native P8.
5. **DV audio fallback**: if `hasDolbyVision` and the selected audio is `truehd / dts / dca / dts-hd / mlp`, switch to a lighter codec (EAC3 > AC3 > AAC) using `preferredLighterAudioTrack`. If the demuxer has a native `audioFormatDescription` for the new track, mark `dvAudioFallbackToPassthrough = true` and **skip the FFmpeg client decoder entirely** — packets are then wrapped via `createAudioSampleBuffer` and sent straight to the audio renderer.
6. Set up subtitle decoder if a bitmap subtitle stream is selected.
7. `state = .ready` → caller calls `play()` → `start(rate:)` spins up `startReadLoop()`.

### 5.2 Seek

`RivuletPlayer.seek(to:)` → `pipeline.seek(to:isPlaying:)`. Inside the pipeline:

1. Set `interruptFlag = 1` if a remux is in flight (instant cancel).
2. Cancel the read task; flush `renderer` (audio + video).
3. `demuxer.seek(to: time)`.
4. Restart the read loop. Anchor the next first video frame as the new preroll target.
5. If the player was paused, deliver only one preview frame (`pausedSeek` exit reason).

### 5.3 DV P7 → P8.1 conversion (per packet)

```
processVideoSample(data):
   nalUnits = HEVCNALParser.parseNALUnits(data)   # length-prefixed
   rpu = nalUnits.first(where: \.isRPU)
   if first frame:
       info = LibdoviWrapper.getInfo(rpu)
       detectedProfile = info.profile     # 5/7/8
       needsConversion = (profile == 7 || isFEL)
   if needsConversion:
       handle = LibdoviWrapper.parseRPU(rpu.data)
       LibdoviWrapper.convert(handle, mode: .toProfile81)
       newRPU = LibdoviWrapper.writeNAL(handle)
       data = HEVCNALParser.replaceRPU(data, with: newRPU)
       data = HEVCNALParser.stripEnhancementLayer(data)   # type 63 / layer_id ≠ 0
   data = HEVCNALParser.modifyVPSForSingleLayer(data)     # max_layers_minus1 = 0
   return data
```

`FFmpegDemuxer.rebuildFormatDescriptionForConversion` then ensures the CMFormatDescription is dvh1‑tagged and carries BT.2020 PQ extensions, so VideoToolbox routes the buffers through the DV decoder. Without that VPS patch the decoder shows a black screen even when the bitstream is otherwise valid.

### 5.4 AirPlay instability recovery (`RivuletPlayer.maybeApplyStabilityFallback`)

A rolling 20‑second window counts auto‑flush, output reconfig, and renderer failure events. Thresholds:

- `≥ 1` renderer failure, `≥ 2` auto‑flush, `≥ 2` output recoveries, or `≥ 3` total events → reload the same DirectPlay URL with `RouteAudioPolicy.airPlayStereo` (forced stereo PCM, larger pull buffers) and resume at the current position.
- `≥ 3` auto‑flush, `≥ 3` output recoveries, `≥ 2` renderer failures, or `≥ 5` total events → escalate to `PlayerError.networkError` and let the view model fall back to HLS.

Recovery attempts are debounced (200ms minimum) and reset on every fresh `load`.

### 5.5 Audio policy selection

`PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for snapshot)` returns:

| Snapshot | Pull mode | Resample | Decode all | Re‑encode | Downmix | Backpressure |
|---|---|---|---|---|---|---|
| Local HDMI | yes | no | no | no | no | 0.75 s |
| AirPlay stereo | yes (1.0/0.3) | yes (route rate) | yes (S16) | no | yes | 2.0 s |
| AirPlay multichannel | yes (1.0/0.3) | yes (route rate) | yes (S16) | yes | no | 1.0 s |

The "decode all" flag forces every codec through `FFmpegAudioDecoder` even if the demuxer has a native FD — required for AirPlay because compressed passthrough is silent on AirPlay routes (`Docs/bugs/avplayer-direct-audio-only-airplay.md`).

---

## 6. Known issues and ongoing work

### 6.1 Throughput on high‑bitrate 4K (HDR & DV)

`DirectPlayPipeline` cannot consistently sustain 24 fps for 4K HEVC streamed over HTTP from Plex. The latest timing breakdown was:

```
[DirectPlayTiming] 120f avg: readGap=77.7ms convert=0.0ms sample=0.9ms
                              sync=0.3ms enqueue=0.4ms total=2.5ms budget=41.7ms
```

Per‑frame work is **2.5 ms**. The bottleneck is the **77 ms read gap** between consecutive video frames — that's where we drain audio packets, do MainActor hops, and wait on `av_read_frame` over HTTP. The DV file reached 24 fps after warmup once the grace period prevented the resync cascade; the HDR file didn't, because it had no grace period until this work.

**Status**

- [x] Add a 15 s startup grace period for non‑DV content.
- [x] Relax the non‑DV resync thresholds.
- [x] Move lookahead config after `demuxer.open()` so it sees runtime DV detection.
- [x] Rebuild the FD as dvh1 for native P8 (no conversion needed).
- [x] DV audio fallback from TrueHD/DTS to a lighter codec.
- [x] Mark the lighter track as passthrough when it has a native CMFormatDescription.
- [ ] Verify the passthrough path actually engages on real hardware (needs new log capture — last log started after preroll and didn't include the `[DirectPlay] Opened:` lines).
- [ ] Investigate the 77 ms read gap directly. Candidates: prefetched packet queue, fewer MainActor hops in the video path, smarter `AVDISCARD` usage on subtitle streams.
- [ ] Decide whether AC3/EAC3 on HDMI should bypass `FFmpegAudioDecoder` even outside the DV fallback (currently it always goes through software decode because the codec is in `FFmpegAudioDecoder.supportedCodecs`).

### 6.2 DV P7 → P8.1 conversion still glitches

The FourCC patch + EL strip approach yields visible but corrupted frames on P7 content. Converted RPU + clean VPS isn't enough — we still see breakup that may be RPU artifacts, GOP boundaries, or timing issues. Picking back up requires a known‑good P7 sample and the timing diagnostic confirming no late drops on the conversion path.

### 6.3 Plex `DOVIProfile = -1` corner case

`RemuxContentAnalyzer.detectDVProfile` casts an `Int(-1)` to `UInt8` (= 255) and never matches. Pipelines still detect DV at runtime via `FFmpegDemuxer.parseDolbyVisionConfig`, but routing happens before that, so a P7 file with bad metadata can be routed to plain `localRemux` instead of the DV conversion path.

### 6.4 Cleanups completed in this pass

- Deleted `DVHLSProxyServer.swift` and the unused `dvProxyServer` declaration in `UniversalPlayerViewModel`.
- Removed `airPlayVideoDelay`, `videoDelayQueue`, `isVideoDelayQueueActive`, `disableAirPlayVideoCompensation()` and the associated branches in `SampleBufferRenderer.enqueueVideo`, `displayTime`, and `flush()`. Removed the call site in `RivuletPlayer.applyAudioPolicy(...)`. The synchronizer handles AirPlay latency natively.
- Removed the empty `segmentParseCount == 1` branch in `FMP4Demuxer.parseMediaSegment` along with the unused counter.
- Removed the legacy `NowPlayingService.updatePlaybackRate` (no callers; `updatePlaybackRateAndState` is the only path).
- `RemuxContentAnalyzer` now delegates `isNativeAudioCodec` / `isTranscodeRequired` checks to `ContentRouter` so the codec sets only live in one place.
- Subtitle codec normalization moved to `MediaTrack.normalizedSubtitleCodec(_:)`. `RivuletPlayer.selectEmbeddedSubtitle` now calls it directly instead of carrying its own copy.
- Verified: `xcodebuild` succeeds for the tvOS simulator.

`HLSManifestEnricher.swift` is still referenced by `UniversalPlayerViewModel.swift` for the legacy AVPlayer HLS path, so it stays.

`ContentRouter.DirectPlayFailureKind` is *not* dead — it's used in 5 places by `UniversalPlayerViewModel` for fallback classification. The earlier doc revision called it dead by mistake.

---

## 7. Sentry & log markers

Useful prefixes when grepping logs from a test run:

| Prefix | Source | Meaning |
|---|---|---|
| `[ContentRouter]` | `ContentRouter.swift` | Routing decision and reasoning. |
| `[RivuletPlayer]` | `RivuletPlayer.swift` | Load entry, audio policy, AirPlay recovery. |
| `[DirectPlay]` | `DirectPlayPipeline.swift` | Open, FD rebuild, audio switch, preroll, read‑loop config. |
| `[DirectPlayDiag]` | `DirectPlayPipeline.swift` | Late frames, drops, resyncs, preroll waits. |
| `[DirectPlayTiming]` | `DirectPlayPipeline.swift` | 120‑frame timing breakdown. |
| `[PlaybackHealth]` | `DirectPlayPipeline.swift` | 5‑second health verdict (GOOD/WARN/BAD). |
| `[Renderer]` | `SampleBufferRenderer.swift` | Rate changes, audio pull diagnostics, stalls. |
| `[FFmpegDemuxer]` | `FFmpegDemuxer.swift` | DOVI parse, FD rebuild, stream discard. |
| `[AudioDecoder]` | `FFmpegAudioDecoder.swift` | Codec open, batch config, PCM validate. |
| `🖥️ DisplayCriteria` | `DisplayCriteriaManager.swift` | Match Content engagement. |
| `🎵 [AudioRoute]` / `🎵 NowPlaying` | `AudioRouteDiagnostics`, `NowPlayingService` | Route snapshots, session activation. |

When asking the user for a log dump for a throughput problem, the minimum useful slice is:

```
[ContentRouter] ...
[RivuletPlayer] load(route:) ...
[DirectPlay] Opened: ...
[FFmpegDemuxer] Rebuilt FD: ... (if DV)
[DirectPlay] DV ... direct play mode: ... (if audio fallback)
[DirectPlay] Renderer lookahead set to ...
[DirectPlay] Starting read loop ...
[PlaybackHealth] CONFIG ...
... at least one [DirectPlayTiming] line ...
... at least one [PlaybackHealth] verdict line ...
```

Without the lines above the read‑loop start, it's not possible to confirm whether the dvh1 rebuild and audio fallback actually engaged.
