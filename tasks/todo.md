# Playback Reliability Worklog (2026-03-02)

## Rivulet-Only Playback Consolidation (2026-03-16)

## Plan
- [ ] Remove all MPV / AVPlayer / DVSampleBuffer player selection and fallback logic from the main playback flow
  - Make `UniversalPlayerViewModel` initialize and drive only `RivuletPlayer`.
  - Remove player-type branches from the main player UI and Now Playing integration.
- [ ] Move Live TV playback off MPV
  - Replace multistream slot wrappers/views with `RivuletPlayer` + sample-buffer rendering.
  - Add any small Rivulet API surface needed for multistream parity (for example mute control).
- [ ] Remove stale playback code and package dependencies
  - Delete no-longer-used wrappers/views/services for MPV, AVPlayer, and DVSampleBuffer playback.
  - Remove the MPVKit package link from the Xcode project if no longer required.
- [ ] Verify
  - Run focused build/test verification and record any residual cleanup risk.

## HomePod + DV + Startup Follow-up (2026-03-16)

## Plan
- [x] Investigate remaining HomePod mini instability path
  - Confirm where the current AirPlay/HomePod policy still escalates to unstable playback instead of degrading gracefully.
  - Add a stricter recovery path for repeated AirPlay instability events.
- [x] Harden routing for DV files that are poor direct-play candidates
  - Identify a metadata-only heuristic for DV conversion sessions that still force expensive client audio decode.
  - Route those cases to the shared HLS pipeline up front instead of waiting for a bad DirectPlay session.
- [x] Reduce Rivulet startup latency
  - Reuse the existing prewarmed direct-play URL cache for Rivulet, not just MPV.
  - Keep the change limited to direct-play-safe startup paths.
- [x] Verify
  - Add/update focused unit tests for the new routing/policy logic.
  - Run build/test verification and record results.

## Review
- Added an AirPlay/HomePod stability fallback that reloads unstable direct-play sessions with a stricter stereo PCM route policy before escalating to a hard failure.
- Added a DV routing heuristic so profile-conversion sessions with only client-decoded/transcode-required audio prefer HLS immediately instead of starting on a poor direct-play path.
- Reused the prewarmed direct-play URL cache for Rivulet's direct-play startup path, matching the existing MPV fast path and removing redundant URL rebuild work.
- Added focused tests in `RivuletTests/Unit/Playback/RouteAudioPolicyTests.swift` and `RivuletTests/Unit/Playback/ContentRouterPlaybackPlanTests.swift`.
- Verification passed:
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/RouteAudioPolicyTests -only-testing:RivuletTests/ContentRouterPlaybackPlanTests -derivedDataPath /tmp/rivulet-verify-tests CODE_SIGNING_ALLOWED=NO`
  - Result: `** TEST SUCCEEDED **`
- Residual environment caveat:
  - Xcode still emitted repeated `com.apple.mobile.notification_proxy` warnings for a passcode-protected physical device during the simulator run, but the targeted simulator tests completed successfully.

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

## HomePod / AirPlay Audio Policy Hardening (2026-03-06)
- [x] Inspect custom player audio path and route policy.
  - Confirmed HomePod-capable AirPlay was still allowing native compressed passthrough for codecs beyond AAC.
  - Found force-decode matching only handled exact strings, so codec variants could bypass the intended AirPlay workaround.
- [x] Implement a stricter AirPlay/HomePod policy in the custom pipeline.
  - Added a shared route-policy helper and switched AirPlay routes to conservative client decode instead of trusting native passthrough.
  - Multichannel AirPlay now keeps surround via client decode + EAC3 re-encode rather than direct compressed passthrough.
  - Normalized codec matching so forced AirPlay decode applies to codec variants, not just exact string matches.
- [x] Verify build and summarize residual risk.
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet` succeeded (warnings only).
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS Simulator' build-for-testing -quiet` succeeded (warnings only).

## Progress Notes
2026-03-06 13:27 - Root cause narrowed to optimistic AirPlay policy plus exact-match codec forcing in `DirectPlayPipeline`.
2026-03-06 13:47 - Verified app build and test-target compile after adding route-policy coverage in `RouteAudioPolicyTests`.
2026-03-06 14:05 - Added targeted HomePod diagnostics for route-policy decision reason, EAC3 packet cadence/size, and audio pull-mode delivery behavior.
2026-03-06 15:02 - Stereo-AirPlay policy now forces all direct-play audio through FFmpeg decode; remaining crackle appears isolated to the client-decoded PCM path for AAC/EAC3 rather than route selection.
2026-03-06 15:18 - Increased stereo-AirPlay PCM batch duration to ~80ms and added batch-shape diagnostics to reduce `AVSampleBufferAudioRenderer` pull churn on HomePod routes.
2026-03-06 15:34 - User confirmed earlier `AVAudioEngine` playback improved the same HomePod route; restoring that path selectively for decoded stereo-AirPlay PCM instead of using sample-buffer PCM everywhere.
2026-03-06 16:02 - HomePod PCM via `AVAudioEngine` is clean but video ran early; added video-timebase latency compensation based on session/output-node latency so video follows AirPlay audio output instead of the host clock.
2026-03-06 16:39 - Pivoted back to `AVSampleBufferAudioRenderer` for stereo AirPlay/HomePod after confirming `AVAudioEngine` route latency breaks start/pause UX. Aligned renderer startup with Apple reliable-start semantics (`hasSufficientMediaDataForReliablePlaybackStart` and synchronizer delayed rate changes) instead of forcing immediate start.
2026-03-06 17:06 - EAC3 HomePod logs showed preroll was still starting while `reliableStart=false` because playback readiness was implicitly satisfied by renderer status. Tightened preroll to require Apple’s reliable-start signal and increased stereo-AirPlay startup cushion to 1.0s.
2026-03-06 17:19 - AAC/HomePod logs showed pull mode still collapsing into one-buffer restart cycles after startup. Added a separate steady-state pull resume threshold so stereo AirPlay keeps a small rolling cushion instead of draining to empty every request.
2026-03-06 17:31 - Further HomePod logs showed the renderer never actually reached stable reliable-start before falling back to resume behavior. Kept pull-mode in startup-threshold mode until `hasSufficientMediaDataForReliablePlaybackStart` becomes true at least once.
2026-03-06 17:42 - New AAC logs showed startup video lead growing past 2s while audio finished buffering, causing visible jumping after sync recovery. Capped preroll lookahead bypass so startup video lead stays bounded while waiting for audio.
2026-03-06 17:55 - HomePod AAC logs confirmed `hasSufficientMediaDataForReliablePlaybackStart` never flips true on this route even after a 1s startup cushion. Downgraded that signal to diagnostics-only and returned preroll gating to explicit pull-start priming.
2026-03-06 18:07 - New first-start logs with ~160-190ms PCM batches showed stereo AirPlay could still miss the startup gate on first play. Lowered only the startup threshold to a single shaped batch (`0.16s`) so playback can begin from the first preroll PCM batch, while keeping the `0.50s` steady-state refill cushion.
2026-03-06 18:21 - Compared “good” and “bad” EAC3 HomePod runs and found preroll was still using pull-request start as the audio-ready signal. Tightened pull-mode priming so startup waits for at least one delivered audio sample, not just an active request.
2026-03-06 18:33 - Follow-up comparison still showed a bad file starting playback before the first logged pull delivery because pull-mode priming still accepted renderer `.rendering` status. Tightened pull-mode startup again so only actual delivered samples count as audio-ready.
2026-03-06 18:47 - Bad-vs-good EAC3 comparison showed the unstable file's first audio packet started ~190ms before the first video keyframe at the seek point. Preroll now shifts the paused clock and preroll anchor back to materially earlier first-audio PTS so startup uses the earliest real media time.
2026-03-06 19:06 - Reworked sample-buffer startup to follow Apple guidance more closely: preroll now starts from the first enqueued media sample (audio or video), keeps the earliest preroll anchor, and starts playback with `setRate(... time: anchor atHostTime: futureHostTime)` instead of an immediate rate flip.
2026-03-06 18:03 - Follow-up HomePod run showed bounded video preroll but steady-state audio restarts still happened at only ~0.25s buffered. Increased stereo-AirPlay resume cushion to 0.5s to test whether the remaining skip is just a too-thin rolling buffer.
2026-03-06 18:11 - Latest user logs were still from the pre-0.5 resume build, but they confirmed the PCM batch shape itself was still only ~85ms. Increased AirPlay-shaped PCM batching to ~160ms so pull-mode restarts can rebuild the rolling cushion with fewer deliveries.
2026-03-06 18:20 - With ~170ms PCM batches active, a 1.0s startup cushion made first-play feel stuck until manual pause/resume. Reduced stereo-AirPlay startup cushion to 0.5s while keeping the 0.5s steady-state resume cushion.
2026-03-06 18:31 - Current logs suggest the remaining skip comes from repeatedly stopping and restarting `requestMediaDataWhenReady`. Switched pull mode to keep the renderer request active across playback and only re-drain when buffered audio crosses the current threshold.
2026-03-06 19:28 - Bad-file EAC3 logs showed early-audio anchor correction alone was insufficient because preroll completion still only ran from the video path. During preroll, audio now enqueues directly into the renderer and shares a common preroll-completion helper so first play can start as soon as audio is actually accepted.
2026-03-06 19:41 - Follow-up bad-file log showed preroll conditions were satisfied (`audioReady=true`, `videoLead>needLead`) but startup still did not flip. Relaxed the final clock-start gate to accept pipeline `.running` state as intent to play, instead of depending only on the transient `isPlaying` flag.
2026-03-06 19:57 - Another bad-file run showed the second PCM batch could start pull mode and deliver the first audio sample without any later video packet arriving to re-check startup. Added a renderer callback for the first delivered audio sample so preroll completion is re-evaluated at the actual moment audio becomes primed.
2026-03-06 20:18 - Latest first-load logs showed some files were still stalled before the second PCM batch arrived, and the first-delivery callback still depended on unsynchronized pull-state reads. Stereo AirPlay now starts from a single shaped PCM batch and the delivery callback passes the first delivered PTS directly into preroll completion.

## Review
HomePod/AirPlay handling is now reliability-first in the custom pipeline: AirPlay routes no longer rely on native compressed passthrough for common codecs, and multichannel routes preserve surround by re-encoding after decode. Residual risk is whether HomePod still destabilizes on the EAC3 surround path itself; if device logs still show renderer auto-flushes there, the next fallback should be route-driven stereo PCM on repeated instability.

## Apple TV-Style Hub Preview Flow (2026-03-07)
- [x] Replace modal hub preview presentation with an in-tree overlay flow.
  - Added `PreviewRequest`, preview phase/focus state, source-anchor preferences, and restore-target handling for exact poster focus restoration.
  - Rewired home and library hub rows to open overlay previews for non-Continue Watching rows while keeping Continue Watching on direct play/detail behavior.
  - Dims and input-fences the underlying browse surface while the overlay owns back behavior.
- [x] Refactor the preview/detail surface into carousel and expanded states.
  - Added `PreviewOverlayHost` to own carousel paging, enter/expand/collapse transitions, adjacent asset prefetching, and menu/back stepping.
  - Updated `PlexDetailView` to support `.previewCarousel` and `.expandedDetail` presentation modes on one continuous scroll surface.
  - Kept the expanded hero and below-fold sections in the same scroll view so `Down` expands first, then moves into detail content.
- [x] Correct the first-pass fidelity gaps called out during review.
  - Hid the tvOS sidebar tab chrome while nested preview flow is active and reset focus back into content so carousel input cannot leak into the sidebar.
  - Tightened carousel geometry so the centered card stays on-screen, side cards read as peeks instead of full siblings, and the overlay uses a full-screen backdrop behind the cards.
  - Kept the expanded preview hero on the same full-screen art so the lower half no longer swaps to a different background before the user moves into detail rows.
- [x] Capture the sample clip as a written reference spec before the next motion pass.
  - Added `Docs/PREVIEW_REFERENCE_VIDEO.md` with observed vs inferred notes for stage ownership, card geometry, hero layout, details layout, and transition timing from `IMG_4815.MOV`.
  - Re-reviewed the clip after user clarification and corrected the phase model to `home -> poster selected -> carousel -> user-triggered expanded card -> user-triggered details`, including the top-only visible corner radius and side-peek geometry.
- [x] Verify build and add focused preview-flow tests.
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build` succeeded.
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded.
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' CODE_SIGNING_ALLOWED=NO test -only-testing:RivuletTests/PreviewFlowStateTests` succeeded.
