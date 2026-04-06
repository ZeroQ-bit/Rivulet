# Playback Reliability Worklog (2026-03-02)

## Apple Music tvOS Home Reframe (2026-04-06)

## Plan
- [x] Re-evaluate the full home screen against the latest simulator screenshot and the Apple Music library reference.
  - Treat the issue as a page-level mismatch instead of a pure focus bug.
- [x] Rebuild the music-library landing composition.
  - Constrain the page frame, restyle the sidebar to Apple Music's language, and bring the Recently Added shelf up into the correct landing position.
- [x] Correct entry behavior and verify.
  - Open the library on the intended sidebar/category state, reset content position, and run a tvOS build.

## Review
- The problem was not just focus. The home screen was still using the wrong page geometry: too edge-to-edge, the sidebar language was wrong, and the Recently Added shelf started too low to resemble Apple Music.
- Reframed `MusicHomeView` into a fixed leading-stage layout with a distinct sidebar panel, tighter content width, and a shallower top offset so the opening screen reads like Apple Music's library instead of a generic full-bleed grid.
- Reworked sidebar rows to match the reference more closely: no SF Symbol category icons, small dot markers, softer translucent selection, and a darker rail treatment.
- Added an explicit landing-state reset so entering the music library returns to `Recently Added`, restores the sidebar as the entry surface, and rebuilds the content scroll position from the top.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded with pre-existing warnings outside the music UI files.

## Apple Music tvOS Home Fidelity Correction (2026-04-01)

## Plan
- [x] Re-evaluate the home screen against the simulator screenshots and the Apple Music reference images.
  - Identify shell-level mismatches instead of doing another spacing-only pass.
- [x] Correct the music home frame and poster treatment.
  - Hide the outer music tab chrome, tighten the sidebar rail, soften the selected-row treatment, and move the grid back to an artwork-first layout.
- [x] Add the missing background hierarchy and verify.
  - Let focused/leading artwork tint the home backdrop and confirm the tvOS target still builds.

## Review
- The remaining mismatch was structural, not just cosmetic: the music library was still inheriting outer tvOS tab chrome and the poster buttons were still reading like generic rounded tiles.
- Hid the outer tab-bar chrome for music library tabs in `TVSidebarView`, so the extra top-left `Music` pill no longer competes with the actual library UI.
- Retuned `MusicHomeView` into a narrower left rail with softer selection, reduced horizontal offsets, a higher content start, and a dynamic artwork-derived backdrop closer to Apple Music's library framing.
- Reworked `MusicPosterCard` so focus only lifts the artwork instead of wrapping the entire poster/text block in a heavy card surface.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded with pre-existing warnings outside the music UI files.

## Apple Music tvOS Music UI Pass (2026-04-01)

## Plan
- [x] Rebuild the library sidebar and content chrome around native tvOS controls.
  - Replace the bespoke music sidebar/button treatments with a sidebar-style `List`, native bordered action buttons, and denser Apple Music-like spacing.
- [x] Retune detail pages to the Apple Music tvOS hierarchy.
  - Simplify artist and album detail typography, keep native action/context menus, and flatten track rows to text plus dividers.
- [x] Rework Now Playing to the Apple Music tvOS composition.
  - Use the reference-aligned centered metadata, bottom progress bar, queue carousel layout, and built-in buttons/context menus instead of custom control chrome.
- [x] Verify with a tvOS build and record any environment blockers.

## Review
- Rebuilt the music library around native controls: the sidebar now uses `List`, playback actions use built-in bordered buttons, and the album/artist grids were tightened to Apple Music-like sizing and spacing.
- Retuned the album, artist, and playlist detail pages to a simpler tvOS hierarchy with smaller type, native capsule/circle action buttons, and flattened track rows with only text and dividers.
- Reworked Now Playing to match the references more closely: centered art and metadata by default, a same-size horizontal queue carousel when expanded, native control buttons, and a stronger art-derived backdrop treatment.
- Kept the native `.contextMenu` flow throughout music actions, and normalized queue wording to `Play Next` / `Play After`.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded.

## Direct Play -> FFmpeg -> AVPlayer Robustness Pass (2026-03-27)

## Plan
- [x] Remove startup URL-preparation races in `UniversalPlayerViewModel`.
  - Ensure a single in-flight stream preparation task is awaited by `startPlayback()`, retries, and episode handoff paths.
- [x] Harden remux session packet/memory handling in `FFmpegRemuxSession`.
  - Eliminate unsafe/duplicate packet ownership patterns and enforce bounded segment generation with explicit error surfaces.
- [x] Strengthen local remux startup preflight before AVPlayer load.
  - Validate init segment + first media segment shape and fail fast to HLS fallback if remux output is invalid.
- [x] Tighten route/fallback behavior and coverage.
  - Keep direct-play/local-remux/HLS plan behavior deterministic and add focused unit coverage for local-remux routing toggles.
- [x] Verify with focused tests/build and record outcomes.

## Review
- Added a single-flight stream URL preparation path in `UniversalPlayerViewModel` (`ensureStreamURLPrepared`) so startup, retry, and episode handoff no longer race concurrent `prepareStreamURL()` calls.
- Wired startup and runtime fallback behavior to actually execute: direct-play/local-remux startup load failures now route once to Plex HLS when a fallback exists, and `AVPlayerItem` failure can trigger the same one-shot fallback path.
- Hardened local remux startup by preflighting both init and first media segment generation before creating the localhost `AVPlayerItem`.
- Tightened `FFmpegRemuxSession` robustness: seek now flushes demux state, segment generation has bounded packet scanning, segment/init fragments are shape-validated (`ftyp+moov` for init, `moof+mdat` for media), and audio-stream switching now resets/rebuilds transcode state safely.
- Added focused routing coverage for user-enabled local remux in `ContentRouterPlaybackPlanTests` (MKV remux-on and MP4 direct-play-unchanged paths).
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded.
  - `xcodebuild test ... -only-testing:RivuletTests/ContentRouterPlaybackPlanTests`
  - Result: blocked by existing test target deployment mismatch in this environment (`RivuletTests` compiling for tvOS 26.2 while `Rivulet` module target is tvOS 26.4), so focused tests did not execute.

## AVPlayer Remux Rework Review (2026-03-19)

## Plan
- [x] Review the current AVPlayer-first playback path.
  - Confirm whether startup, routing, and remux handoff are actually aligned around `AVPlayer`, or whether legacy custom-player assumptions still leak into the flow.
- [x] Inspect the local remux pipeline for immediate playback blockers.
  - Review `ContentRouter`, `UniversalPlayerViewModel`, `LocalRemuxServer`, and `FFmpegRemuxSession` for correctness and runtime hazards.
- [ ] Fix startup determinism before touching codec edge cases.
  - Remove the race between async URL preparation and playback start so the player never enters `No stream URL available` during normal startup.
- [ ] Make the remux output path valid and boring.
  - Correct packet lifetime handling in `FFmpegRemuxSession`, remove unsafe packet ownership patterns, and add a local preflight that validates init + first media segment before constructing the `AVPlayerItem`.
- [ ] Collapse legacy playback branches that no longer execute.
  - Remove or quarantine dead `RivuletPlayer`/DV-proxy assumptions from the AVPlayer view model so audio/subtitle selection and error handling only reflect the active architecture.
- [ ] Add focused coverage around the new route model.
  - Replace stale route tests with cases that assert `avPlayerDirect` / `localRemux` / `hls`, and add at least one startup test for the remux handoff path.

## Review
- The view model is already AVPlayer-first, but startup still depends on a detached async `prepareStreamURL()` task launched from `init`, while `UniversalPlayerView` immediately calls `startPlayback()`. That leaves a real race where playback can fail before `streamURL` exists.
- The remux session contains packet-lifetime bugs that can independently prevent playback: packets are `av_packet_unref`'d via `defer` inside long-running loops instead of per iteration, and the audio-transcode path still calls `av_packet_from_data` on Swift-managed memory before discarding that packet and allocating another one.
- The AVPlayer migration is incomplete in the view model: the active player is `AVPlayer`, but track enumeration and media selection are still TODOs, and the old `RivuletPlayer` path remains as dead/stubbed branching logic.
- The routing/tests/docs are out of sync. Production routing uses `avPlayerDirect` / `localRemux` / `hls`, but the route tests still expect the older `.directPlay` shape, which means the current rework is under-verified.
- The Dolby Vision constraint should be treated as architectural, not as a local bug: the repo already documents that AVPlayer rejects `dvh1` in HLS manifests, so the robust AVPlayer target should be "plays reliably as AVPlayer-compatible HEVC/H.264 + AAC/AC3/EAC3/fMP4", not "preserve every DV signaling path through HLS".

## Split Backdrop Ownership Behind Carousel Overlay (2026-03-19)

## Plan
- [x] Re-evaluate the current capture after the slower card retune.
  - Check whether the background parallax, text placement, and scale behavior still read wrong even if the lateral card motion improved.
- [x] Split selected backdrop and metadata ownership.
  - Keep the selected backdrop on the stage so it can lag independently, while keeping metadata/logo/action chrome attached to the moving selected card overlay.
- [x] Verify
  - Run a tvOS build check after the layering change and record remaining test blockers accurately.

## Review
- After comparing the latest behavior, the lateral card motion was improved but the selected backdrop and metadata were still sharing the wrong ownership, which caused scale/clipping artifacts when the backdrop tried to live inside the moving card.
- Split the selected hero into a stage-owned backdrop layer plus a selected-card metadata overlay: the backdrop now drifts behind the carousel, while the selected card uses `PlexDetailView` without its own backdrop so the text/logo/buttons stay attached to the card frame.
- Kept the slower eased card timing from the prior pass, with the stage backdrop still driven by its own lagging offset/settle track behind the overlay.
- Updated `Docs/PREVIEW_REFERENCE_VIDEO.md` and `tasks/lessons.md` with the split-ownership rule so future passes do not regress back to either fully card-owned or fully stage-owned hero content during carousel motion.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: tvOS build succeeded. Focused simulator tests remain blocked in this environment because the bundled `Libavformat`/`Libavcodec`/`Libavutil`/`Libswresample` xcframeworks do not include tvOS Simulator libraries.

## Carousel Surface Continuity + Slower Handoff (2026-03-19)

## Plan
- [x] Compare the latest Rivulet capture against the reference.
  - Measure how many obvious frames the current handoff occupies and check whether the card surface itself changes during the move.
- [x] Keep one consistent carousel surface during paging and slow the move further.
  - Prevent the centered item from swapping between side-card and hero implementations mid-motion, and extend the lateral easing to better match the reference.
- [x] Verify
  - Run a tvOS build check after the preview host retune and record simulator test blockers accurately if they persist.

## Review
- Compared `IMG_4951.MOV` against `IMG_4941.MOV`; the current Rivulet handoff was still collapsing into roughly `5-6` obvious frames, while the reference reads closer to `12-14` frames from first drift to full stop.
- Root cause was not just duration: the centered card was still changing surface implementation during the lateral move, which made the transition feel harsher and shorter than the timing constant alone suggested.
- Kept the moving card on the same carousel-card surface during paging, then reveal the centered hero surface after settle, and slowed the paging curve to a longer eased `0.58s` move with a `0.48s` attached-backdrop settle after the existing short lag.
- Updated `Docs/PREVIEW_REFERENCE_VIDEO.md` and `tasks/lessons.md` with the measured comparison and the continuity rule so future tuning does not regress back to mid-motion view swaps.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: tvOS build succeeded. Focused simulator tests remain blocked in this environment because the bundled `Libavformat`/`Libavcodec`/`Libavutil`/`Libswresample` xcframeworks do not include tvOS Simulator libraries.

## Carousel Ease Timing Retune (2026-03-19)

## Plan
- [x] Re-measure the carousel item movement from the reference clip.
  - Count the subtle drift frames at the start and end of the move instead of only the obvious high-speed middle.
- [x] Retune the carousel page animation to match the slower eased handoff.
  - Replace the short spring with a longer ease-in/out card motion and extend the linked backdrop settle gate so both still stop together.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the retune.

## Review
- Re-reviewed `IMG_4941.MOV` and counted the actual card motion from first subtle drift through full stop; the first clean handoff reads closer to `12-14` frames at `30 fps`, or about `~0.40s - 0.47s`, not the shorter `~0.30s` feel we had been biasing toward.
- Switched the carousel item movement to a longer `easeInOut` path and extended the backdrop settle so the slower card motion still lands with the attached background rather than unlocking metadata too early.
- Updated `Docs/PREVIEW_REFERENCE_VIDEO.md` to call out the longer eased bookends explicitly so future tuning does not regress back to a short spring interpretation.
- Verification:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-ease-timing-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: tvOS build succeeded. Focused simulator tests are currently blocked in this environment because the bundled `Libavformat`/`Libavcodec`/`Libavutil`/`Libswresample` xcframeworks do not include tvOS Simulator libraries.

## Carousel Paging Timing Retune (2026-03-18)

## Plan
- [x] Measure the carousel handoff timing from the reference clip.
  - Count the first visible card-motion frame through visual settle instead of tuning the spring by feel alone.
- [x] Slow the carousel page animation slightly.
  - Retune the card spring and linked backdrop settle so both still land together while reading closer to the measured clip on device.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the timing change.

## Review
- Timed two clean lateral handoffs in `IMG_4941.MOV`; both read at roughly `8-10` frames at `30 fps` from first visible movement to settle, which puts the observed motion in the `~0.27s - 0.33s` band.
- Slowed the carousel paging spring slightly and extended the delayed backdrop settle gate so the card and attached backdrop still land together instead of the card reading too quick relative to the reference.
- Updated `Docs/PREVIEW_REFERENCE_VIDEO.md` with the measured frame-count range and the note that the SwiftUI implementation target can bias a little slower on device.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-paging-timing-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Carousel Settle Alignment + Plex Art Lock (2026-03-18)

## Plan
- [x] Re-check the reference stop timing.
  - Confirm whether the card and internal backdrop should finish together instead of letting the backdrop coast past the card settle.
- [x] Align the backdrop settle with the card.
  - Keep the delayed-start card-owned drift, but shorten the settle so it lands with the carousel frame.
- [x] Disable live backdrop upgrades.
  - Stop generating/scheduling pending "better art" swaps and keep Plex default hero art in place for now.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the timing and backdrop-lock changes.

## Review
- Rechecked the clip and aligned the card-owned backdrop lag so it starts late but now lands with the card instead of drifting after the page motion has already settled.
- Disabled the shared live backdrop-upgrade path, so preview/detail surfaces now keep Plex-provided default art instead of swapping to a "better" image on repeated entries.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-stop-and-plex-art-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Carousel Backdrop Parallax Direction Fix (2026-03-18)

## Plan
- [x] Correct the seeded lag direction.
  - Flip the internal backdrop offset so the image starts on the trailing side of the incoming card's motion instead of the leading side.
- [x] Increase the visible drift.
  - Raise the card-owned backdrop travel and preview overscan so the parallax reads more clearly on device.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the sign/amplitude correction.

## Review
- Flipped the card-owned backdrop lag so the internal image now starts on the trailing side of the page motion instead of drifting the wrong way.
- Increased the preview-only backdrop travel and overscan so the lag should read more clearly without detaching the backdrop from the selected card.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-card-parallax-direction-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Carousel Backdrop Parallax Retry (2026-03-18)

## Plan
- [x] Undo the detached stage-backdrop experiment.
  - Restore the selected hero card as the owner of the active backdrop instead of keeping a shared stage-level background behind the carousel.
- [x] Retune the card-owned lag so it actually reads.
  - Increase the internal backdrop offset, add a short delay before it settles, and give the preview card more backdrop overscan so the slower drift is visible while still moving with the carousel.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the retry.

## Review
- Reverted the stage-owned backdrop experiment and restored the active backdrop to the selected carousel card, matching the reference ownership model again.
- Retuned the card-owned backdrop lag with a larger starting offset, a short delayed settle, and extra preview overscan so the image should drift more visibly while still traveling with the card.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-card-owned-parallax-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Preview Stage Backdrop Decoupling (2026-03-18)

## Plan
- [x] Re-check why the prior parallax patch still read as card-attached.
  - Confirm whether the active backdrop was still visually confined to the selected card surface.
- [x] Move carousel backdrop ownership to the stage.
  - Render the active hero backdrop as a stage-level layer behind the cards and keep the selected hero card on top of it.
  - Increase the lag distance now that the backdrop is no longer clipped to the moving card.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the stage-backdrop change.

## Review
- Moved the active preview backdrop out of the selected hero card and onto a shared stage layer behind the carousel, so the card can travel independently while the background trails on its own track.
- Kept the selected hero card over the shared stage backdrop with its own overlay chrome, which makes the backdrop lag visibly readable instead of feeling like texture drift inside the card.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-stage-backdrop-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Carousel Backdrop Parallax Follow-up (2026-03-18)

## Plan
- [x] Re-check the reference clip for the card/backdrop motion relationship during carousel paging.
  - Confirm whether the backdrop is simply slower or actually runs on a visibly separate lagging track.
- [x] Patch the preview carousel backdrop motion.
  - Give the incoming hero backdrop its own seeded offset and slower settle animation so the card leads and the background trails during page changes.
  - Slow the preview backdrop crossfade slightly so the art handoff matches the lagging motion.
- [x] Verify
  - Run build-check and focused preview/backdrop verification after the paging-motion adjustment.

## Review
- Updated the preview carousel so the incoming hero backdrop starts from a small opposite-direction offset and eases home on a slower curve, instead of reading as locked to the card frame.
- Slowed the preview hero backdrop crossfade slightly so the image handoff keeps drifting after the card is already close to settled, matching the Apple TV+ reference more closely.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -derivedDataPath /tmp/rivulet-preview-parallax-tests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Pause/Resume Audio Re-Prime Fix (2026-03-18)

## Plan
- [x] Trace the pause/resume path against seek/FF/RW behavior.
  - Confirm whether pause/play was bypassing the preroll-aware audio recovery path that seek-based transport already uses.
- [x] Preserve paused audio buffers instead of draining pull-mode delivery.
  - Stop pull-mode requests during transport pause while keeping queued audio available for resume.
- [x] Re-arm audio delivery on resume in both playback pipelines.
  - Restart paused pull-mode audio before advancing the shared playback clock on direct-play and HLS resumes.
- [x] Verify
  - Run a focused tvOS build check after the playback pipeline patch.

## Review
- Fixed the pause/play-only regression by making `SampleBufferRenderer.pauseAudio()` actually preserve pull-mode buffered audio instead of routing through the destructive `stopAudioPullMode()` path.
- Added an explicit `resumeAudio()` transport hook so both `DirectPlayPipeline` and `HLSPipeline` restart paused audio delivery before `setRate(...)` advances playback again.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded. Existing project warnings remain in unrelated files; no focused automated playback test currently covers this pause/resume path.

## Season Shelf Peek Alignment (2026-03-17)

## Plan
- [x] Compare the season resting-height path with the show resting-height path.
  - Confirm whether the season detail hero is exposing more of the below-fold shelf than the tuned show path.
- [x] Align the resting peek depth.
  - Put season detail on the same shallow shelf-peek constant as the other TV detail surfaces so the episode row sits at the same height.
- [x] Verify
  - Run build-check and focused preview/season-branding tests after the tweak.

## Review
- Moved season detail onto the same shallow resting shelf-peek constant as the show/episode TV detail surfaces, which lowers the visible episode-thumb slice to match the other TV items.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Season Hero Chrome Cleanup (2026-03-17)

## Plan
- [x] Remove the redundant season hero action.
  - Drop the season-only `Show` button so normalized season items use the same hero action set as the other TV items.
- [x] Restore hidden-until-scroll behavior for the single-season pill header.
  - Keep the season pill out of the carousel/upper hero view and only reveal it as the user scrolls into the episode section.
- [x] Verify
  - Run build-check and focused preview/season-branding tests after the cleanup.

## Review
- Removed the redundant `Show` button from the season hero action row so Plex season containers no longer expose an extra hero-only control after being normalized to show branding.
- Restored the single-season pill header to the same hidden-until-scroll behavior as the other below-fold chrome, keeping it out of the at-rest carousel and upper hero states.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Apple TV+ Season Item Branding Normalization (2026-03-17)

## Plan
- [x] Inspect the current season-item hero path.
  - Confirm where `season` items still use raw Plex season titles instead of the parent show's branding and logo/backdrop identity.
- [x] Normalize season hero branding.
  - Make season items use the parent show's title/logo/backdrop identity for hero surfaces while keeping season-specific context in secondary metadata.
- [x] Add focused verification coverage.
  - Add a unit test for season backdrop-request normalization and any extracted season-branding helpers.
- [x] Verify
  - Run build-check and focused preview/backdrop tests after the normalization patch.

## Review
- Normalized Plex `season` items onto the same TV hero-branding path as episodes by deriving show title and TMDB/TVDB identity from the parent show instead of the raw season container.
- Updated `PlexDetailView` so season heroes now use show branding for the title/logo while moving `Season 1` into the secondary metadata row, which keeps the preview visually aligned with the rest of the TV items.
- Added focused unit coverage for season title normalization and season hero-backdrop request identity resolution.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PlexMetadataHeroBrandingTests -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; all three focused test classes passed.

## Apple TV+ Reverse-Fade + Paging Timing Tune (2026-03-17)

## Plan
- [x] Isolate the two timing paths that still feel off.
  - Separate the reverse-fold title/logo fade from the main fold scroll animation.
  - Confirm where carousel page-to-page metadata reveal timing is currently being enforced.
- [x] Patch the timing behavior.
  - Make the centered top logo/header disappear faster when returning from details to the top.
  - Slow the page-settle metadata fade slightly without changing the broader card motion timing.
- [x] Update reference notes.
  - Record the early reverse-fold logo clear and the slower page-to-page metadata fade in the canonical preview spec and lessons log.
- [x] Verify
  - Run build-check and focused preview/backdrop tests after the timing patch.

## Review
- Decoupled the centered folded-header logo opacity from `scrollProgress`, so it now clears quickly on the way back to the hero while the larger reverse-fold motion continues.
- Removed the detail view's hardcoded metadata fade duration so carousel paging can own that timing, then slowed the page-settle reveal slightly without changing the card travel timing.
- Updated the preview spec and lessons log to keep the early reverse-fold clear and slower page-to-page text fade as explicit fidelity rules.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

## Apple TV+ Fade + Season Header Fidelity (2026-03-17)

## Plan
- [x] Re-check the reference clip for focused-info reveal behavior and left-column spacing.
  - Confirm whether the title/action block translates or only fades, and re-read the hero margins against the frame grids.
- [x] Correct the hero overlay layout.
  - Remove reveal-time translation from the focused title/action block.
  - Increase the logo/title slot slightly and tighten the hero inset/baseline spacing toward the reference layout.
- [x] Remove the remaining single-season `Episodes` header path.
  - Load season siblings in season detail so single-season shows can stay on the one-pill season header pattern.
- [x] Verify
  - Run build-check and focused preview/backdrop tests after the patch.

## Review
- Re-checked `IMG_4941.MOV` and aligned the focused-info reveal to an opacity-only fade, with the hero title/logo slot and action row held in fixed geometry.
- Nudged the hero metadata block inward and lowered the action row slightly so the left-column spacing reads closer to the Apple TV+ reference layout.
- Increased the hero and below-fold title/logo sizing so the focused title treatment better matches the clip.
- Loaded sibling seasons for season detail and replaced the single-season `Episodes` heading with the one-pill season header pattern.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

## Apple TV+ Shelf Depth Correction (2026-03-17)

## Plan
- [x] Restore below-fold visibility rules for show chrome.
  - Keep season pills visually hidden until scroll while preserving the real shelf continuity.
- [x] Reduce the at-rest show shelf tease depth.
  - Lower the visible episode-thumb slice so only a shallow portion peeks into the expanded hero.
- [x] Verify
  - Run build-check and focused preview tests after the correction.

## Review
- Restored the season-pill bar to hidden-until-scroll behavior without breaking the real-shelf peek.
- Reduced the show hero shelf tease so the episode thumbnails now sit lower and only a shallow top portion is visible at rest.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

## Apple TV+ Motion + Shelf Peek Follow-up (2026-03-17)

## Plan
- [x] Match the paged-card motion more closely.
  - Tighten the page timing and give the hero background a separate, slightly slower motion/fade cadence than the card frame.
- [x] Move focused action chrome into the info-loaded state.
  - Show the action row with the focused metadata state while keeping actual button interaction gated to the expanded phase.
- [x] Make the real below-fold show shelf peek into expanded hero.
  - Remove the at-rest centered-header reserve so the first shelf can peek naturally.
  - Keep single-season shows on the season-pill pattern with one pill.
- [x] Verify
  - Run build-check and focused preview tests after the follow-up patch.

## Review
- Tightened the carousel handoff timing and separated the hero backdrop motion from the card frame so the art now lags/crossfades more like the reference clip.
- Moved the action row into the focused-info state, lowered it slightly, and kept actual interaction gated until the expanded phase.
- Reworked the below-fold layout so the real show shelf can peek into the expanded hero, and single-season shows now keep the season-pill pattern instead of dropping to an `Episodes` title.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

## Apple TV+ Preview Carousel Follow-up (2026-03-17)

## Plan
- [x] Correct carousel geometry to match the user-verified Apple TV+ behavior.
  - Remove neighbor overlap so cards read as side-by-side surfaces with a gap.
- [x] Restore focused-card metadata in the settled carousel state.
  - Fade the centered item's title/meta back in after entry and paging settle.
  - Keep explicit expand for the extra chrome/details affordance.
- [x] Update reference material.
  - Record the corrected carousel behavior in the canonical preview reference and lessons log.
- [x] Verify
  - Run build-check and focused preview tests after the follow-up patch.

## Review
- Corrected the preview carousel so neighboring cards no longer stack behind the centered card; they now sit beside it with a small gap while preserving the dominant center stage.
- Restored centered-card metadata as part of the stable carousel state, with a settle-then-fade pattern on initial entry, lateral paging, and collapse back from the expanded hero.
- Updated the canonical Apple TV+ reference doc so future work does not regress back to the old "stacked, art-only carousel" assumption.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

## Apple TV+ Preview Flow Cleanup (2026-03-17)

## Plan
- [x] Add shared hero backdrop resolution and deferred-upgrade coordination.
  - Introduced a shared backdrop request/session/coordinator path for preview, detail, home hero, and player-loading art.
  - Added focused unit tests for selection, motion-lock gating, and stale-generation invalidation.
- [x] Refactor preview composition and timing.
  - Switched preview to an art-only carousel by default, with metadata only on the explicit expand action.
  - Removed the duplicate selected-card side-art/hero-art composition and updated phase/timing handling.
- [x] Standardize shared hero surfaces.
  - Wired the shared backdrop coordinator into `PlexDetailView`, the home hero, and player-loading helpers.
  - Kept backdrop upgrades deferred until post-settle crossfade.
- [x] Update canonical reference documentation.
  - Replaced the old preview reference clip notes with the new `IMG_4941.MOV`-based spec and upgrade policy.
- [x] Verify
  - Build-check passed.
  - Focused simulator tests for preview-state and backdrop-session logic passed.

## Review
- Added `HeroBackdropSupport.swift` to centralize hero backdrop selection, deferred upgrades, and full-size crossfade rendering.
- Refactored the preview overlay into an image-led carousel with explicit expand timing, motion locking, tucked side peeks, and no overlapping selected-card artwork layers.
- Moved `PlexDetailView` off direct TMDB/backdrop replacement state and onto the shared backdrop coordinator, then reused the same resolver for home hero and player-loading art.
- Updated `Docs/PREVIEW_REFERENCE_VIDEO.md` to make `IMG_4941.MOV` the canonical preview reference and to document the deferred crossfade rule.
- Verification passed:
  - `xcodebuild -project Rivulet.xcodeproj -scheme Rivulet -destination 'generic/platform=tvOS' build -quiet CODE_SIGNING_ALLOWED=NO`
  - `xcodebuild test -project Rivulet.xcodeproj -scheme Rivulet -destination 'platform=tvOS Simulator,id=F34B8F67-7F13-468F-9526-6A38C6B2181B' -only-testing:RivuletTests/PreviewFlowStateTests -only-testing:RivuletTests/HeroBackdropSessionTests -quiet CODE_SIGNING_ALLOWED=NO`
  - Result: build succeeded; both focused test classes passed.

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
