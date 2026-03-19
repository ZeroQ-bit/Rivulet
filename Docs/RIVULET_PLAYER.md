# RivuletPlayer — Custom Video Player Architecture

RivuletPlayer is Rivulet's native video player, replacing the MPV-based stack for VOD playback. It uses FFmpeg for demuxing/decoding and Apple's `AVSampleBufferDisplayLayer` for rendering, with native HDR / Dolby Vision-compatible playback plus a custom DV profile-conversion path for unsupported sources.

## High-Level Architecture

```
UniversalPlayerViewModel (player selection + state)
        │
        ▼
   RivuletPlayer (PlayerProtocol)
        │
        ▼
  ContentRouter.plan()
        │
        ├── primary: DirectPlayPipeline
        │
        └── fallback: HLSPipeline
                     (HLS used only as fallback for VOD)
   ┌────┼────────────────┐
   ▼    ▼                ▼
FFmpegDemuxer    FFmpegAudioDecoder    SampleBufferRenderer
   │                │                  (AVSampleBufferDisplayLayer +
   │                │                   AVSampleBufferAudioRenderer +
   │                │                   AVSampleBufferRenderSynchronizer)
   ▼                ▼
FFmpegSubtitleDecoder
   │
   ▼
SubtitleManager → SubtitleOverlayView
```

## File Inventory

### Core Player

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/RivuletPlayer.swift` | 559 | `PlayerProtocol` conformance. Bridges DirectPlayPipeline and HLSPipeline to UniversalPlayerViewModel. Manages play/pause/seek/stop, audio/subtitle track selection, state publishing, and deterministic pipeline shutdown during reload/fallback. |
| `Services/Plex/Playback/PlayerProtocol.swift` | ~60 | `@MainActor` protocol all players conform to. Defines `play()`, `pause()`, `seek()`, `selectAudioTrack()`, `selectSubtitleTrack()`, state publishers. |
| `Views/Player/SampleBufferDisplayView.swift` | ~80 | SwiftUI `UIViewRepresentable` wrapping `AVSampleBufferDisplayLayer` for rendering. |

### Pipeline

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` | 1252 | Core playback engine. Runs the read loop (demux → decode → enqueue), handles seeking (with dedup), preroll buffering, audio track switching, and pause/resume with dead-loop detection. |
| `Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift` | 289 | Owns `AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`, and `AVSampleBufferRenderSynchronizer`. Handles video/audio enqueue with pacing, backpressure, and error recovery. |
| `Services/Plex/Playback/Pipeline/ContentRouter.swift` | ~170 | Produces `PlaybackPlan` (primary + fallback routes) using direct-play-first policy for VOD and HLS for hard blockers. |
| `Services/Plex/Playback/Pipeline/SegmentBuffer.swift` | ~200 | Actor-based producer/consumer buffer for HLS segments. |

### FFmpeg Integration

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/FFmpeg/FFmpegDemuxer.swift` | 1241 | Wraps libavformat. Opens MKV/MP4 via HTTP, reads packets, handles seeking (`av_seek_frame`), discovers streams (video/audio/subtitle). Thread-safe actor isolation. |
| `Services/Plex/Playback/FFmpeg/FFmpegAudioDecoder.swift` | 573 | Client-side audio decoding via libavcodec + libswresample. Handles codecs Apple TV can't natively decode: TrueHD, DTS, PCM variants, FLAC. Converts to 32-bit float PCM for `AVSampleBufferAudioRenderer`. |
| `Services/Plex/Playback/FFmpeg/FFmpegSubtitleDecoder.swift` | ~350 | Decodes text (SRT/ASS) and bitmap (PGS/DVB) subtitles from FFmpeg packets. Handles PGS display-set semantics where `end_display_time = UInt32.max` means "until next cue". |

### Dolby Vision

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/Dovi/DoviProfileConverter.swift` | ~300 | Converts incompatible DV profiles (P7 MEL, P8.6) to P8.1 on-the-fly by modifying RPU NAL units. Uses libdovi for RPU parsing/rewriting. |
| `Services/Plex/Playback/Dovi/HEVCNALParser.swift` | 338 | Parses HEVC NAL units from Annex-B or length-prefixed bitstreams. Extracts RPU (NAL type 62) for DV processing, injects converted RPUs back. |
| `Services/Plex/Playback/Dovi/LibdoviWrapper.swift` | ~180 | Swift wrapper around the C libdovi library. Manages `DoviRpuOpaque` lifecycle (parse, convert profile, write). |

### Subtitles

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/Subtitles/SubtitleManager.swift` | 309 | Accumulates text and bitmap cues, polls for active cues at current playback time. Auto-closes PGS cues with infinite end times when the next cue arrives. |
| `Services/Plex/Playback/Subtitles/SubtitleCue.swift` | ~80 | Data models for `TextSubtitleCue` and `BitmapSubtitleCue`. Bitmap cues have mutable `endTime` for PGS auto-close. |
| `Services/Plex/Playback/Subtitles/SubtitleOverlayView.swift` | ~150 | SwiftUI overlay rendering text and bitmap subtitles over the video. |
| `Services/Plex/Playback/Subtitles/SubtitleParser.swift` | 456 | Parses SRT and ASS/SSA subtitle files downloaded from Plex. |
| `Services/Plex/Playback/Subtitles/SubtitleClockSyncController.swift` | ~100 | Syncs subtitle display timing with the render synchronizer clock. |

### HLS / FMP4

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/Pipeline/HLSPipeline.swift` | 435 | HLS variant of the playback pipeline for Plex transcoded streams. |
| `Services/Plex/Playback/FMP4Demuxer.swift` | 1237 | Parses fragmented MP4 segments for HLS playback. |
| `Services/Plex/Playback/HLSSegmentFetcher.swift` | 359 | Downloads HLS segments with retry and prefetch. |
| `Services/Plex/Playback/HLSCodecPatchingResourceLoader.swift` | 345 | `AVAssetResourceLoaderDelegate` that patches codec strings in HLS manifests (e.g., adding DV codec info). |
| `Services/Plex/Playback/DVHLSProxyServer.swift` | 397 | Local HTTP proxy for DV HLS streams. Rewrites segments to inject converted RPU NAL units. |

### Display & Audio Services

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/DisplayCriteriaManager.swift` | ~150 | Manages tvOS Match Content (frame rate + dynamic range switching) via `AVDisplayManager`. |
| `Services/Plex/Playback/PlaybackAudioSessionConfigurator.swift` | ~120 | Configures `AVAudioSession` for spatial audio, Atmos passthrough, and multichannel output. |
| `Services/Plex/Playback/AudioRouteDiagnostics.swift` | ~80 | Logs current audio route (HDMI, eARC) for debugging. |
| `Services/Plex/Playback/NowPlayingService.swift` | 683 | Updates `MPNowPlayingInfoCenter` with artwork, progress, and transport controls. |

### Shared Services

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/MediaTrack.swift` | ~60 | Unified model for audio/subtitle tracks across all player backends. |
| `Services/Plex/Playback/StreamURLCache.swift` | ~80 | Caches Plex decision/stream URLs to avoid re-fetching during player init. |
| `Services/Plex/Playback/PlexProgressReporter.swift` | ~120 | Reports playback progress to Plex server (scrobbling). |
| `Services/Plex/Playback/MPVPrewarmService.swift` | 185 | Pre-warms MPV context for Live TV. Skips prewarm when RivuletPlayer is active. |

### Views

| File | Lines | Description |
|------|-------|-------------|
| `Views/Player/UniversalPlayerView.swift` | 1588 | Main SwiftUI player container. Hosts video layer, controls overlay, subtitle overlay, post-video views. |
| `Views/Player/UniversalPlayerViewModel.swift` | 3678 | Player selection logic, state management, marker detection, chapter/track handling. Routes to RivuletPlayer, MPV, AVPlayer, or DVSampleBuffer based on content and settings. |
| `Views/Player/PlayerControlsOverlay.swift` | 729 | Transport controls (play/pause, seek, progress bar, track selection). |
| `Views/Player/PlayerContainerViewController.swift` | 449 | `UIViewController` container that manages display criteria and player lifecycle. |
| `Views/Player/PlayerProgressBar.swift` | ~200 | Custom progress bar with chapter markers and seek preview. |
| `Views/Player/TrackSelectionSheet.swift` | ~180 | Audio/subtitle track picker sheet. |
| `Views/Player/VideoInfoOverlay.swift` | 434 | Displays codec, resolution, HDR format, bitrate diagnostics. |

### Legacy Players (Fallbacks)

| File | Lines | Description |
|------|-------|-------------|
| `Services/Plex/Playback/MPVPlayerWrapper.swift` | 573 | MPV bridge. Still used for Live TV multi-stream. |
| `Services/Plex/Playback/AVPlayerWrapper.swift` | 1346 | AVPlayer wrapper. Available via "Use AVPlayer for DV" setting. |
| `Services/Plex/Playback/DVSampleBufferPlayer.swift` | 889 | DV-specific sample buffer player. Fallback for DV P7/P8.6 when RivuletPlayer is off. |
| `Views/Player/MPV/MPVMetalViewController.swift` | 985 | UIViewController hosting Metal layer for MPV rendering. |
| `Views/Player/MPV/MPVPlayerView.swift` | ~80 | SwiftUI wrapper for MPVMetalViewController. |
| `Views/Player/MPV/MPVPlayerDelegate.swift` | ~40 | Delegate protocol for MPV events. |
| `Views/Player/MPV/MetalLayer.swift` | ~30 | CAMetalLayer subclass for MPV. |
| `Views/Player/MPV/MPVProperty.swift` | ~50 | MPV property name constants. |
| `Views/Player/AVPlayerView.swift` | ~100 | SwiftUI wrapper for AVPlayer. |
| `Views/Player/DVSampleBufferView.swift` | ~80 | SwiftUI wrapper for DVSampleBufferPlayer. |

## Player Selection Logic

`UniversalPlayerViewModel.selectPlayer()` chooses the player based on content and user settings:

1. **RivuletPlayer** (default) — Used for all VOD content unless disabled in settings
2. **AVPlayer** — Used when "Use AVPlayer for DV" or "Use AVPlayer for All" is enabled
3. **DVSampleBufferPlayer** — Fallback for Dolby Vision P7/P8.6 when RivuletPlayer is off
4. **MPV** — Fallback for everything else; primary player for Live TV

## VOD Routing Policy (Rivulet)

Rivulet now uses a strict direct-play-first policy for VOD:

1. Build a `PlaybackPlan` from `ContentRouter.plan(...)`.
2. Start `primary` route immediately (normally DirectPlay when FFmpeg and part key are available).
3. On direct-play init/runtime fatal error, auto-fallback once to HLS at current playback time.
4. No auto-fallback from Rivulet to MPV in this path.

Hard blockers that start on HLS immediately:
- FFmpeg unavailable
- No direct-play source/part key
- Live TV / forced HLS

## Key Codec Handling

### Video
- **H.264/H.265**: Hardware decode via VideoToolbox → `CMSampleBuffer` → `AVSampleBufferDisplayLayer`
- **Dolby Vision P5/P8.1**: Native VideoToolbox decode with DV metadata
- **Dolby Vision P7/P8.6**: On-the-fly RPU conversion to P8.1 via libdovi before decode

### Audio
- **AAC/AC3/EAC3**: Passthrough to `AVSampleBufferAudioRenderer` (Apple-native decode)
- **TrueHD/DTS/PCM/FLAC**: Client-side decode via FFmpeg (`FFmpegAudioDecoder`) → 32-bit float PCM → `AVSampleBufferAudioRenderer`

### Subtitles
- **SRT/ASS**: Parsed via `SubtitleParser`, rendered as text overlay
- **PGS/DVB**: Decoded via `FFmpegSubtitleDecoder` as bitmap images, rendered as image overlay
- PGS uses display-set semantics: `end_display_time = UInt32.max` sentinel means "until next cue"

## Data Flow: Direct Play

```
HTTP (MKV/MP4)
    │
    ▼
FFmpegDemuxer.readPacket()
    │
    ├─ Video packet → VideoToolbox decode → CMSampleBuffer
    │   └─ [DV P7?] → HEVCNALParser → DoviProfileConverter → inject RPU → decode
    │
    ├─ Audio packet
    │   ├─ [AAC/AC3] → wrap as CMSampleBuffer (passthrough)
    │   └─ [TrueHD/DTS/PCM] → FFmpegAudioDecoder → PCM CMSampleBuffer
    │
    └─ Subtitle packet → FFmpegSubtitleDecoder → SubtitleManager
                                                      │
    ┌─────────────────────────────────────────────────┘
    ▼
SampleBufferRenderer
    ├─ enqueueVideo() → AVSampleBufferDisplayLayer (with pacing)
    ├─ enqueueAudio() → AVSampleBufferAudioRenderer (with backpressure)
    └─ AVSampleBufferRenderSynchronizer (A/V sync clock)
```

## Preroll & Seeking

- **Preroll**: Before starting the clock, DirectPlayPipeline buffers video (~450ms lead for DV, ~200ms otherwise) and audio frames. This prevents initial stuttering.
- **Seeking**: Seek requests are deduplicated (ignoring seeks within 0.5s of current position). After seeking while paused, only 1 preview frame is decoded. On `resume()`, the dead read loop is detected and restarted with fresh preroll.
