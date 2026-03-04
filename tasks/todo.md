# Playback Reliability Worklog (2026-03-02)

## Plan
- [x] Implement subtitle pipeline improvements
  - Added ASS/SSA parser support for Plex sidecar subtitles.
  - Added clock-synchronized subtitle updater for DVSampleBuffer/Rivulet using render synchronizer time.
  - Added subtitle cue diagnostics logs (PTS + cue timing/IDs).
- [x] Implement audio route diagnostics and HomePod-focused telemetry
  - Added shared AVAudioSession route-change diagnostics service.
  - Integrated diagnostics with PlaybackAudioSessionConfigurator.
  - Improved first-audio-sample logging (format + session route context).
- [x] Improve routing heuristics for Apple built-in decode support
  - Made Opus direct-play conditional on tvOS/iOS version support.
  - Added fallback-to-HLS behavior for audio codecs not verified as native.
- [x] Integrate and verify
  - Wired subtitle clock lifecycle into UniversalPlayerViewModel (start/stop/seek/retry/fallback/deinit).
  - Build-check passed: `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet`.

## Review
- Added a focused parser test file: `RivuletTests/Unit/Playback/SubtitleParserTests.swift`.
- Test execution on simulator did not complete due environment issue (`Invalid device state` / simulator IPC server died), not compiler/test assertion failures.

## ARC/AVR Audio Follow-Up (2026-03-02)
- [x] Root-cause hypothesis from live logs
  - HDMI route/session activation looked healthy; direct-play audio sample enqueue started.
  - Found likely regression: renderer could permanently disable audio after brief startup backpressure.
- [x] Harden direct-play audio enqueue behavior
  - Replaced permanent audio-disable policy with bounded wait + per-sample drop strategy.
  - Added failed-status recovery (flush) and richer renderer status/error logging.
- [x] Harden AAC magic-cookie handling
  - Added AAC cookie normalization path when FFmpeg extradata is wrapped/non-ASC.
  - Keeps existing ADTS stripping and synthesized ASC fallback.
- [x] Verify build
  - Build-check passed again: `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet`.
- [x] Deepen AAC direct-play diagnostics/fix attempt
  - Parse AAC AudioSpecificConfig from FFmpeg cookie and align ASBD (`mFormatFlags`, sample rate, channels, frames/packet) for decoder init consistency.
  - Set audio decode timestamp to `.invalid` in CMSampleTimingInfo for compressed audio buffers.
  - Added richer first-audio-packet timing log (PTS/DTS/duration/timebase) in DirectPlay read loop.
- [x] Reduce session/log churn and seek thrash
  - Added duplicate-log suppression in `AudioRouteDiagnostics`.
  - Added short re-activation suppression window in `PlaybackAudioSessionConfigurator` for repeated same-mode calls.
  - Deduped repeated `NowPlaying` playback-state handling.
  - Added seek coalescing + tiny-seek ignore in `DirectPlayPipeline` to reduce read-loop churn from duplicate seek requests.

## DV Profile 7 In-App Conversion Stutter (2026-03-02)
- [x] Confirm root cause in HLS sample-buffer path
  - Found segment-wide conversion in `FMP4Demuxer.parseMediaSegment`, which blocks enqueue until every frame in a segment is converted.
- [x] Remove segment-wide conversion stall
  - Moved conversion to `FMP4Demuxer.createSampleBuffer(from:)` so conversion happens per sample during normal enqueue flow.
- [x] Reduce RPU parsing overhead
  - Reworked `HEVCNALParser.findRPU`/`hasRPU` to scan length-prefixed NAL headers directly and avoid full NAL array allocation.
- [x] Verify build
  - Attempted build twice:
  - First failed due Xcode build DB lock in shared DerivedData.
  - Second failed in FFmpeg module import setup (`Libavutil` header `AMF/core/Factory.h` missing), not in modified DV files.
- [x] Record review
  - This patch removes the largest scheduling bottleneck for profile conversion on HLS/sample-buffer playback and reduces per-frame parsing overhead.
  - Remaining risk: if libdovi conversion itself exceeds frame budget on device, playback can still under-run and may need dynamic conversion fallback.

## DV P7 DirectPlay Throughput Follow-up (2026-03-02)
- [x] Analyze latest stutter logs
  - Conversion is fast (~0.7ms/frame), but media PTS lags far behind synchronizer time; throughput bottleneck is outside libdovi.
- [x] Reduce DirectPlay CPU pressure from audio path
  - Updated DirectPlay stream selection to keep currently selected native audio (e.g. AC3) and stop auto-promoting to software-decoded TrueHD/DTS.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DV Profile 7 Conversion Follow-up (2026-03-03)
- [x] Review `Docs/DV_PROFILE7_CONVERSION.md` and compare with active `DirectPlayPipeline` behavior.
- [x] Remove DV-time audio auto-promotion to client-decoded TrueHD/DTS when native tracks exist.
  - Added native-track preference for DV conversion sessions to preserve read-loop throughput.
- [x] Use client-decode stream selection API when software decode is required.
  - Switched to `selectAudioStreamForClientDecode` before creating `FFmpegAudioDecoder`.
- [x] Harden manual audio track switching for client decode codecs.
  - `selectAudioTrack` now configures decoder path for TrueHD/DTS and passthrough path for native codecs.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).
- [x] Decouple audio renderer waits from video packet flow in DirectPlay.
  - Added dedicated async audio enqueue task + bounded queue so audio backpressure can’t stall video enqueue cadence.
  - Added startup log: `[DirectPlay] Audio enqueue queue enabled (limit=120)`.

## DV Late-Frame Recovery Fix (2026-03-03)
- [x] Reproduce regression from late-drop diagnostics.
  - Confirmed drop-only policy can enter a runaway state where synchronizer time keeps advancing and video never recovers.
- [x] Replace drop-only behavior with bounded catch-up + sync re-anchor.
  - Added consecutive late-drop tracking and forced recovery thresholds.
  - Added synchronizer re-anchor (`setRate(..., time: packet.cmPTS)`) on sustained lateness, preferring keyframe recovery and applying cooldown.
- [x] Expand diagnostics for recovery visibility.
  - Added `Late-video resync` logs and periodic metrics (`lateBurst`, `lateResyncs`).
  - Added `lateResyncs` to loop summary log.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DV Late-Frame Tuning (2026-03-03)
- [x] Analyze runtime logs after initial late-drop fix.
  - Confirmed repeated drop/resync cycles (`dropsInBurst=24`) still starved playback.
- [x] Shift from drop-first to resync-first late handling.
  - Late frames are now generally enqueued, with clock resync when sustained late bursts are detected.
  - Added emergency-only drop path for very stale frames (>4s).
- [x] Add stage timing diagnostics for slow video frames.
  - Added breakdown log (`conv`, `sample`, `sync`, `enqueue`) when per-frame video pipeline exceeds 120ms.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DV Audio Queue Lead Guard (2026-03-03)
- [x] Analyze logs after resync-first tuning.
  - Observed sustained clock lead growth up to ~4s and emergency drops despite resyncs.
- [x] Guard against multi-second audio lead in async queue.
  - Reduced queued audio limit from 120 to 24 (~0.8s at 32ms AC3 packets).
  - Changed overflow behavior from waiting to dropping queued audio samples to avoid video-loop stalls and large audio lead.
  - Added queue diagnostics (`maxAudioQ`, `audioQDrops`) to periodic and summary logs.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DirectPlay Audio Decode Throughput (2026-03-03)
- [x] Analyze multi-file logs with DV conversion disabled.
  - Confirmed severe drift persists on `conversion=false` sessions, ruling out libdovi conversion cost as primary cause.
  - Observed high audio packet volume in client decode paths (TrueHD/DTS) with low video throughput and growing `sync-pts` lead.
- [x] Decouple compressed audio decode from packet read loop.
  - Added dedicated compressed-audio decode queue/task for client-decoded codecs.
  - Read loop now enqueues compressed audio packets instead of decoding inline.
  - Added decode-queue diagnostics (`audioDecQ`, `maxAudioDecQ`, `audioDecDrops`) to heartbeat/summary.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DirectPlay Clock Preroll Guard (2026-03-03)
- [x] Analyze startup drift from latest logs.
  - Confirmed synchronizer could run ~10s ahead before first audio sample enqueue on client-decode sessions.
- [x] Gate clock start on preroll readiness.
  - Initial and post-seek sync now anchors at rate `0`.
  - Playback clock starts only after preroll criteria are met (audio queue has data or no audio path).
  - Added diagnostic logs for preroll wait/start transitions.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DirectPlay Preroll + Backpressure Tuning (2026-03-04)
- [x] Analyze three-file DV comparison logs.
  - Confirmed laggy files correlate with startup clock jumps and repeated video late observations, while converter cost stays low.
  - Confirmed smooth file still shows enqueue-dominant slow frames, indicating display-layer pacing/backpressure as the residual bottleneck.
- [x] Keep preroll anchor when starting playback clock.
  - Changed preroll completion from `setRate(rate, time: packetPTS)` to `setRate(rate)` so already-enqueued reordered frames are not made instantly late by clock re-anchor.
  - Added anchor-vs-packet diagnostic in preroll start log.
- [x] Tighten renderer lookahead during DirectPlay sessions.
  - Set `renderer.maxVideoLookahead` to `0.6s` on load and restore previous value on stop to reduce enqueue backpressure spikes.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DirectPlay Preroll Deadlock Hotfix (2026-03-04)
- [x] Reproduce regression from latest user logs.
  - Confirmed no-playback state with repeated `Waiting for preroll start ... audioQ=0` despite audio renderer reaching `rendering`.
- [x] Fix preroll readiness condition.
  - Replaced queue-depth-only readiness with renderer-level readiness (`isAudioPrimedForPlayback`).
  - Added a bounded preroll timeout fallback (1s) to prevent permanent `rate=0` deadlock.
  - Expanded preroll logs with `audioPrimed`, `reason`, and `wait` to verify startup path deterministically.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DV Profile Telemetry + Conversion Startup Cushion (2026-03-04)
- [x] Improve DV profile observability.
  - Added FFmpeg DOVI config parsing from coded side data and packet side data fallback.
  - Added demuxer logs for detected `profile`, `level`, and `bl_compat`.
  - Expanded DirectPlay open log to include `DV profile/level/blCompat`.
  - Added converter-side profile detection log from first parsed RPU.
- [x] Analyze split behavior from latest two-file run.
  - Non-conversion DV file is now mostly stable (minor startup roughness).
  - Conversion-enabled file still shows early clock lead and late-frame resync storms.
- [x] Add conversion-specific startup cushion.
  - Use larger video lookahead for conversion sessions (`1.2s`) and keep lower lookahead for non-conversion (`0.6s`).
  - Require both audio priming and minimum video preroll lead before starting clock (`~450ms` conversion, `~200ms` non-conversion), with timeout fallback.
  - Added preroll lead diagnostics (`videoLead`, `needLead`, completion `lead`).
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## DV Late-Burst Catch-up Tuning (2026-03-04)
- [x] Analyze latest comparison logs from user.
  - Confirmed conversion file still has periodic late-frame bursts despite low conversion cost and improved preroll.
  - Confirmed non-conversion file mostly stabilizes after startup.
- [x] Add bounded soft-drop policy for late non-keyframes.
  - For late bursts, allow limited soft drops before full resync/emergency logic to reduce visible judder from rendering stale frames.
  - Keep existing keyframe/forced resync and emergency stale-drop safety paths intact.
  - Added `lateSoftDrops` diagnostics to heartbeat and summary logs.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).

## Non-Conversion Startup Backpressure Tuning (2026-03-04)
- [x] Analyze latest two-file validation logs.
  - Profile 7/FEL conversion file is now broadly stable and watchable.
  - Remaining startup roughness is concentrated in non-conversion sessions with enqueue-dominated slow frames.
- [x] Tighten non-conversion startup buffering policy.
  - Reduced non-conversion renderer lookahead from `0.6s` to `0.35s` to avoid overfilling display-layer queue.
  - Increased non-conversion preroll lead requirement from `200ms` to `300ms` to start clock with a slightly safer video cushion.
- [x] Verify build
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).
