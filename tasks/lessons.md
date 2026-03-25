# Lessons Learned

## 2026-03-19 - Stable Parallax Needs Split Ownership

**Mistake**: Fixed the lateral card motion, but first kept too much on the moving card, then over-corrected by moving the full hero content to the stage layer, which broke metadata positioning.
**Pattern**: Reference-style carousel parallax needs the backdrop and the overlay content to have different ownership; if they share one layer, parallax breaks, and if both move to the stage, metadata placement breaks.
**Rule**: Split ownership cleanly: keep the selected backdrop on a stable stage layer so it can drift independently, but keep the metadata/logo/action layout attached to the moving selected card overlay so positioning and reveal timing stay correct.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-19 - Motion Tuning Fails If The View Type Changes Mid-Flight

**Mistake**: Kept adjusting the carousel duration/curve while the outgoing and incoming centered items were still swapping between different view implementations during the lateral move.
**Pattern**: If a moving surface changes its underlying view structure mid-animation, the visible handoff can collapse into a few harsh frames no matter how much the outer animation duration is increased.
**Rule**: For reference-driven carousel motion, keep the moving card on one consistent base surface for the entire lateral handoff, then reveal any heavier centered-only chrome after settle instead of swapping view types during motion.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-19 - Count The Slow Bookends Of Motion

**Mistake**: Timed the carousel handoff mostly by the obvious high-velocity middle frames and undercounted the gentle lead-in and settle that make the reference feel slower.
**Pattern**: Motion references with strong ease-in/out can look deceptively short if you only count the frames where distance changes are obvious; the slower bookend frames are still part of the move and materially affect feel.
**Rule**: When tuning against a motion clip, count from the first subtle drift to the final full stop, and if the reference has long eased bookends, prefer an explicit ease curve over a short spring.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-18 - Time Motion Against Frames, Not Just Feel

**Mistake**: Kept nudging the carousel paging spring by feel even after the user called out that the transition was still reading too fast.
**Pattern**: Reference-driven motion tuning needs at least one concrete frame-count pass from the source clip, because a spring that "looks close" in code can still feel materially quicker on device.
**Rule**: When a user says a transition is too quick, measure the start-to-settle frame span from the reference clip, write the observed range down, and retune both the primary motion and any linked settle gates from that measured band instead of guessing.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-18 - Parallax Lag Must Land With The Card

**Mistake**: Let the card-owned backdrop keep settling after the carousel frame had effectively stopped, which made the motion feel late rather than layered.
**Pattern**: Reference-style parallax often comes from delayed onset and different travel distance, not from a later stop time.
**Rule**: For this carousel, the internal backdrop drift can start later than the card, but it should still finish with the card settle rather than continuing to coast after it.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-18 - Disable Live Backdrop Upgrades If They Break Motion

**Mistake**: Kept the shared backdrop-upgrade path active even though it was swapping art on nearly every preview entry and undercutting the motion work.
**Pattern**: Visual asset quality upgrades are not worth it when they fire often enough to read as animation bugs instead of rare fidelity improvements.
**Rule**: If live hero-art upgrades are causing repeated visible swaps, disable them and stick to Plex-provided default art until the upgrade path can be reintroduced without motion regressions.
**Applied**: `Rivulet/Views/Plex/HeroBackdropSupport.swift`, `RivuletTests/Unit/Models/HeroBackdropSessionTests.swift`.

## 2026-03-18 - Card-Owned Parallax Must Seed On The Trailing Side

**Mistake**: Seeded the card-owned backdrop lag on the wrong side of the page change and with too little travel, so the internal image drift moved against the expected parallax and barely read at all.
**Pattern**: Once layer ownership is correct, the next failure mode in motion tuning is often the sign and magnitude of the starting offset rather than the easing curve itself.
**Rule**: For a card-owned backdrop lag, seed the internal image on the trailing side of the incoming card's travel and use enough overscan/travel for the drift to be visibly readable on device.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-18 - Carousel Backdrop Parallax Must Stay Card-Owned

**Mistake**: Over-corrected the unreadable backdrop lag by moving the active preview backdrop to a detached stage layer behind the carousel, which broke the reference and felt worse than the card-owned behavior.
**Pattern**: When a motion detail is too subtle, changing ownership layers entirely is often the wrong fix; the issue may be offset amplitude and delayed settle timing rather than the layer hierarchy itself.
**Rule**: Keep the preview backdrop attached to the selected carousel card, but seed the image inside that card with a larger starting offset and a delayed slower settle so the card leads while the backdrop still feels attached.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Rivulet/Views/Plex/PlexDetailView.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-18 - Carousel Backdrop Parallax Needs Its Own Motion Track

**Mistake**: Left the carousel backdrop too tightly coupled to the card transition, which flattened the Apple TV+ paging feel even though the reference clip clearly shows the card leading and the background trailing.
**Pattern**: In reference-driven motion work, "slower background" is not just a longer duration constant; it usually requires its own seeded offset and settle animation so the layers separate perceptually.
**Rule**: When the reference shows parallax between a focused card and its backdrop, drive the backdrop on a distinct motion track with its own offset and timing rather than binding it 1:1 to the card frame animation.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Rivulet/Views/Plex/PlexDetailView.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-17 - TV Shelf Peek Depth Must Match Across Show And Season Detail

**Mistake**: Tuned the real shelf peek depth for show detail but left season detail on the generic resting-height path, so season episode thumbnails sat visibly higher than the other TV items.
**Pattern**: When adjacent content types are normalized onto the same visual pattern, layout constants can still diverge if one type keeps falling through a generic branch.
**Rule**: Any TV detail surface that uses the shared hero-to-shelf transition should share the same resting peek-depth tuning unless the reference explicitly shows otherwise.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-17 - Season Hero Normalization Must Remove Rest-State Season Chrome

**Mistake**: Normalized Plex season items to the parent show's branding but left season-specific hero controls visible at rest, including a redundant `Show` action and the single-season pill header in the upper hero state.
**Pattern**: When a detail surface is repurposed for a new content identity, leftover type-specific chrome can survive outside the main branding path and quietly break consistency with the rest of the flow.
**Rule**: After rebranding a content type onto another surface pattern, audit the remaining controls and headers for that type and keep any below-fold navigation chrome hidden until the user actually scrolls into that section.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-17 - Normalize Plex Season Items To Show Branding

**Mistake**: Treated Plex `season` items from feeds like recently added as self-branded hero items, which surfaced raw labels like `Season 1` where the rest of the TV preview flow uses show-level branding.
**Pattern**: Plex hub feeds can hand back season containers in places that are visually designed around episodes/shows, so trusting the raw item title/type for hero branding produces inconsistent TV presentation.
**Rule**: For hero/title/logo/backdrop presentation, normalize season items to the parent show's branding path and keep the season identifier as secondary metadata instead of the primary title.
**Applied**: `Rivulet/Models/Plex/PlexMetadata.swift`, `Rivulet/Views/Plex/HeroBackdropSupport.swift`, `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-17 - Tune Forward And Reverse Timing Separately

**Mistake**: Kept the folded-header logo on the same long reverse-scroll timing as the whole fold motion and left carousel paging metadata on the same quick fade timing as other reveal paths.
**Pattern**: In reference-driven UI work, the forward and reverse versions of a transition often need different timing, and paging reveal cadence does not automatically match entry/collapse cadence just because the same elements are involved.
**Rule**: Decouple reverse-fade timing from the structural fold animation when the reference clears an element early, and tune carousel page-settle metadata timing independently from other `showMetadata` reveals.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`, `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-17 - Match Reference Reveals With Geometry Locked

**Mistake**: Left reveal-time motion in the focused title/action block and missed that the remaining single-season `Episodes` label was coming from the season-detail branch, not the show-detail branch.
**Pattern**: Small UI-fidelity mismatches often survive in adjacent surfaces even after the main flow is corrected, especially when reveal animation and header policy are implemented in separate code paths.
**Rule**: When matching a reference interaction, keep reveal-time geometry fixed unless the clip clearly shows translation, and trace repeated labels/header chrome across every related detail surface before considering the behavior corrected.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-17 - Preserve Hidden-Until-Scroll Chrome

**Mistake**: Brought the season-pill bar into view immediately when switching the episode shelf peek to real below-fold content.
**Pattern**: When a lower shelf is intentionally teased into a hero, not every element from that shelf should become visible at once; some chrome still belongs to the scrolled state.
**Rule**: Preserve "hidden until scroll" behavior for below-fold controls even when exposing the real shelf earlier for continuity.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-17 - Shelf Peek Must Come From Real Content

**Mistake**: Started to solve the expanded-view episode teaser with a synthetic noninteractive peek strip instead of exposing the actual below-fold shelf.
**Pattern**: When a reference interaction depends on continuity between surfaces, duplicating the next-state content as a preview-only layer breaks that continuity even if it looks similar in isolation.
**Rule**: If the user calls out a peek from the next state, expose the real next-state content earlier rather than creating a duplicate preview-only strip.
**Applied**: `Rivulet/Views/Plex/PlexDetailView.swift`.

## 2026-03-17 - UI Fidelity Corrections Need Spec Updates

**Mistake**: Assumed the Apple TV+ carousel should be stacked and art-only after settle, then encoded that assumption into both the implementation and the reference doc.
**Pattern**: When a visual interaction is being matched to a product reference, a mistaken read of the source clip can propagate into geometry, timing, and future-agent guidance all at once.
**Rule**: After any user correction on UI fidelity, update the implementation and the canonical reference/lessons docs together so the mistaken interpretation cannot survive as "source of truth."
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Docs/PREVIEW_REFERENCE_VIDEO.md`.

## 2026-03-03 - Performance

**Mistake**: Added a late-video mitigation that only dropped stale packets without any synchronizer recovery path.
**Pattern**: Throughput protection logic that sheds load but never re-anchors the playback clock can enter permanent starvation.
**Rule**: Any late-frame drop policy must include bounded drop bursts plus explicit sync-clock recovery (with cooldown and diagnostics).
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` late-frame handling and future playback catch-up logic.

## 2026-03-04 - Preroll Clocking

**Mistake**: Started playback after preroll by re-anchoring synchronizer time to the current packet PTS.
**Pattern**: Re-anchoring the clock after queueing decode-order/reordered frames can instantly make queued frames late and trigger false recovery/drop behavior.
**Rule**: After preroll, resume rate from the existing clock anchor (`setRate(rate)`), and only re-anchor time when explicitly correcting drift.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` preroll start path.

## 2026-03-04 - Preroll Readiness Signal

**Mistake**: Gated preroll completion on transient async audio queue depth (`audioQ > 0`), which can remain zero even when audio is already rendering.
**Pattern**: Using queue occupancy as the sole readiness signal can deadlock startup when producer/consumer cadence keeps the queue near empty.
**Rule**: Use renderer priming state (enqueued/rendering) for readiness, and keep a bounded timeout fallback to guarantee forward progress.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` + `SampleBufferRenderer.swift`.

## 2026-03-04 - Preroll Cushion by Workload

**Mistake**: Used a single startup/lookahead policy for both conversion and non-conversion DV sessions.
**Pattern**: Heavier startup workloads (e.g., conversion + larger samples) need more preroll headroom; otherwise the sync clock can outrun video before steady-state is reached.
**Rule**: Tune preroll lead and lookahead by workload class (conversion vs non-conversion), while preserving bounded timeout escape hatches.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-04 - Late Frame Recovery Balance

**Mistake**: Recovered late bursts mostly by resyncing while still rendering many stale non-keyframes.
**Pattern**: Rendering sustained stale frames can look worse than bounded frame shedding, even if it avoids full starvation.
**Rule**: Use limited soft drops for late non-keyframes, then escalate to keyframe/forced resync and emergency drops when needed.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-04 - Startup Queue Pressure

**Mistake**: Kept non-conversion DV startup with too much lookahead, feeding the display layer faster than it could drain in the first seconds.
**Pattern**: Excess initial lookahead can create enqueue-dominated stalls even when sync drift metrics look nominal.
**Rule**: For non-conversion startup, prefer tighter lookahead and slightly larger preroll lead to trade tiny startup latency for smoother first seconds.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - HomePod Residual Crackle Follow-up

**Mistake**: Assumed the remaining HomePod crackle after route-policy fixes was still primarily a route-classification problem.
**Pattern**: Once route selection is corrected and logs show stable pull/encoder behavior, the next bottleneck is often the transformed output shape itself (PCM batch size, cadence, sample format), not another capability heuristic.
**Rule**: After a route-policy fix improves but does not eliminate audio artifacts, inspect the renderer-bound PCM cadence before adding more route exceptions.
**Applied**: `Rivulet/Services/Plex/Playback/FFmpeg/FFmpegAudioDecoder.swift` stereo-AirPlay PCM batching.

## 2026-03-06 - Reuse Known-Good Route Paths

**Mistake**: Moved decoded PCM for all routes onto the sample-buffer renderer even though the earlier `AVAudioEngine` path had already improved HomePod behavior.
**Pattern**: When a route-specific audio path has prior positive evidence, preserve it behind explicit policy instead of replacing it wholesale with a unified path.
**Rule**: For AirPlay/HomePod regressions, prefer restoring the previously stable PCM output path first, then tune packet/buffer cadence within that path.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Engine Path Needs Latency Compensation

**Mistake**: Restored `AVAudioEngine` for HomePod PCM without restoring any equivalent of the synchronizer's route-latency compensation.
**Pattern**: A custom audio clock can sound clean but still desync badly on AirPlay routes if video is timed against the host clock instead of the delayed audio output path.
**Rule**: Any non-synchronizer audio path for AirPlay/HomePod must explicitly measure and apply output-latency compensation to the video clock.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Clean Audio Can Still Fail Transport UX

**Mistake**: Treated clean, compensated `AVAudioEngine` playback as sufficient for HomePod without validating start/pause responsiveness.
**Pattern**: AirPlay/HomePod can expose multi-second output latency on engine-backed PCM paths; even if A/V sync is correct, transport controls feel broken because audio starts and pauses late.
**Rule**: For HomePod routes, evaluate transport responsiveness separately from steady-state sync. If the engine path reports ~2s output latency, decide explicitly between clean audio with delayed controls or a lower-latency renderer path.
**Applied**: HomePod stereo-AirPlay engine evaluation in `SampleBufferRenderer.swift`.

## 2026-03-06 - Respect Sample-Buffer Reliable Start

**Mistake**: Disabled `AVSampleBufferRenderSynchronizer.delaysRateChangeUntilHasSufficientMediaData` and treated "some audio enqueued" as good enough for sample-buffer startup.
**Pattern**: Overriding the renderer's reliable-start gate defeats Apple’s preroll logic, which is especially risky on buffered routes like AirPlay/HomePod where immediate start can trade startup speed for audible instability.
**Rule**: For `AVSampleBufferAudioRenderer`, keep the synchronizer's reliable-start behavior enabled and use `hasSufficientMediaDataForReliablePlaybackStart` as the primary audio-start readiness signal.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Pull Diagnostics Need Session-Level Throttling

**Mistake**: Logged pull-mode "first few deliveries" using a per-request counter even though AirPlay/HomePod was often issuing one-sample requests.
**Pattern**: Diagnostics tied to per-request counters can become effectively per-sample spam when the renderer drains tiny batches, hiding the useful state changes.
**Rule**: For pull-mode renderer logs, throttle by playback session or state transition, not by per-request drain count.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Renderer Status Is Not Reliable-Start

**Mistake**: Allowed preroll to treat `AVSampleBufferAudioRenderer.status == .rendering` as sufficient audio readiness even while `hasSufficientMediaDataForReliablePlaybackStart` was still false.
**Pattern**: Renderer status can flip to rendering before the internal preroll target is met, which makes startup look "ready" while AirPlay still lacks enough buffered audio for stable playback.
**Rule**: When the reliable-start API is available, gate startup on that signal rather than renderer status.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Startup Buffer Is Not Enough for Steady State

**Mistake**: Added a large initial pull-mode startup cushion but still restarted pull delivery immediately after the queue drained once.
**Pattern**: Buffered routes can pass startup and then fall into a sawtooth pattern of tiny refill bursts if steady-state restarts do not preserve a smaller rolling cushion.
**Rule**: Treat startup and steady-state pull thresholds separately: large enough to start cleanly, small enough to keep audio fed without oscillating between empty and one-buffer requests.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/PlaybackAudioSessionConfigurator.swift`.

## 2026-03-06 - Do Not Exit Startup Mode Before Reliable Start

**Mistake**: Switched from the large startup cushion to the smaller resume cushion as soon as the first pull request completed, even though the renderer had never reported reliable-start.
**Pattern**: A renderer can accept and drain a startup batch without ever reaching its internal reliable-start target; dropping into steady-state buffering too early keeps playback permanently under-buffered.
**Rule**: Keep the pull path in startup-threshold mode until `hasSufficientMediaDataForReliablePlaybackStart` becomes true at least once.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Audio Preroll Cannot Imply Unlimited Video Preroll

**Mistake**: Let video enqueue bypass lookahead for the entire audio-preroll window, which allowed video lead to grow to multiple seconds while audio was still buffering.
**Pattern**: Fixing audio startup can create visible jumpiness if video preroll remains unbounded; the clock starts in sync, but the display layer already has too much queued video to drain smoothly.
**Rule**: During startup, bound video lead separately from audio readiness. Use bypassed lookahead only until a modest preroll lead is reached, then resume normal pacing while audio catches up.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Treat Reliable-Start As Advisory On HomePod

**Mistake**: Promoted `hasSufficientMediaDataForReliablePlaybackStart` from diagnostics to a hard startup gate on AirPlay/HomePod.
**Pattern**: Some routes can continue reporting `false` even after a large buffered startup burst, so using that property as a mandatory gate causes long preroll timeouts rather than cleaner playback.
**Rule**: On HomePod/AirPlay, use explicit pipeline buffering thresholds for startup gating and keep `hasSufficientMediaDataForReliablePlaybackStart` as diagnostic context unless device behavior proves it reliable.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Rolling Buffer Must Match Route Jitter

**Mistake**: Assumed a `0.25s` steady-state audio resume cushion was enough once startup was stable.
**Pattern**: A route can tolerate startup with a large preroll but still skip during steady state if the rolling refill threshold is too thin relative to transport jitter.
**Rule**: Separate startup and steady-state thresholds, and size the steady-state threshold from observed route behavior rather than from generic low-latency assumptions.
**Applied**: `Rivulet/Services/Plex/Playback/PlaybackAudioSessionConfigurator.swift`.

## 2026-03-06 - Thresholds Alone Cannot Fix Tiny PCM Bursts

**Mistake**: Tuned pull thresholds repeatedly while the decoder was still emitting only ~85ms PCM batches for the AirPlay path.
**Pattern**: If the renderer is being refed in very small chunks, even a larger resume threshold can take too many deliveries to rebuild and the route still behaves as if it is under-buffered.
**Rule**: When HomePod/AirPlay logs show repeated small pull restarts, increase the upstream PCM batch duration as well as the renderer thresholds.
**Applied**: `Rivulet/Services/Plex/Playback/FFmpeg/FFmpegAudioDecoder.swift`.

## 2026-03-06 - Rebalance Startup Threshold After Batch Changes

**Mistake**: Kept a 1.0s startup cushion after increasing AirPlay PCM batches to ~170ms, which made initial playback wait too long before the first start.
**Pattern**: Larger batches reduce renderer churn, but they also mean a large startup threshold can require too few packets to justify the extra startup delay.
**Rule**: Re-tune startup thresholds after changing upstream batch duration; do not keep old startup constants once the PCM batch shape changes materially.
**Applied**: `Rivulet/Services/Plex/Playback/PlaybackAudioSessionConfigurator.swift`.

## 2026-03-06 - Startup Threshold Must Clear Real Two-Batch Minima

**Mistake**: Set the revised stereo-AirPlay startup threshold close to the nominal two-batch total instead of below the smallest observed two-batch accumulation.
**Pattern**: On jittery HomePod/AirPlay routes, a threshold that sits on the edge of the second buffered batch can still behave like a three-batch startup gate in practice.
**Rule**: When using batch-based startup cushions, set the threshold below the lowest observed two-batch buffered duration for the target route, not at the theoretical average.
**Applied**: `Rivulet/Services/Plex/Playback/PlaybackAudioSessionConfigurator.swift`.

## 2026-03-06 - Stop/Start Churn Can Be The Bug

**Mistake**: Continued treating `requestMediaDataWhenReady` as a short-lived pull burst that should be stopped whenever the internal queue ran empty.
**Pattern**: On buffered routes like HomePod/AirPlay, repeated stop/start cycles can themselves create the audible instability even after buffer sizing is improved.
**Rule**: Once pull-mode playback has started, keep the renderer request active across steady-state playback and re-drain when the buffered queue crosses the chosen threshold instead of tearing the request down on every empty queue.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Pull Request Start Is Not Audio Priming

**Mistake**: Treated `requestMediaDataWhenReady` starting as equivalent to audio being primed for playback.
**Pattern**: On HomePod/AirPlay, the pull callback can be active while the first actual enqueue is still delayed, so starting the clock from request-start creates file-dependent sync and stutter races.
**Rule**: In pull-mode preroll, require at least one delivered sample (or renderer rendering state), not merely an active pull request, before declaring audio ready.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Renderer Status Can Also Be A False Pull-Ready Signal

**Mistake**: Kept `AVSampleBufferAudioRenderer.status == .rendering` as an alternate pull-mode priming signal after removing request-start priming.
**Pattern**: On AirPlay/HomePod, renderer status can advance ahead of the first delivered-sample accounting, so startup can still race ahead of real audio output on some files.
**Rule**: For pull-mode HomePod startup, only actual delivered samples should satisfy audio priming; renderer status is too optimistic.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - First Video Keyframe Is Not Always The Earliest Media Anchor

**Mistake**: Assumed the first decoded video packet at a seek point was always the correct preroll anchor for A/V startup.
**Pattern**: Some files expose audio frames that begin materially earlier than the first video keyframe after seek; keeping the later video anchor makes the first audio buffers instantly late and creates file-specific startup instability.
**Rule**: During preroll, if the first audio packet begins meaningfully earlier than the current anchor, move the paused clock and preroll anchor back to that audio PTS before starting playback.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Startup Timeline Should Be Defined By The First Enqueued Sample

**Mistake**: Continued approximating startup by pausing on the first video frame and later flipping the synchronizer rate immediately, instead of using the first enqueued sample time and a future host-time start.
**Pattern**: When audio can arrive before video or begin earlier than the first keyframe after seek, immediate-rate startup makes some preroll samples belong to the past of the chosen timeline, producing file-dependent instability.
**Rule**: For `AVSampleBufferRenderSynchronizer` startup, anchor the paused timeline to the first enqueued media sample that starts preroll and start playback with `setRate(_:time:atHostTime:)` against a short future host time.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`, `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`.

## 2026-03-06 - Preroll Completion Must Be Triggered By Audio Acceptance Too

**Mistake**: Left preroll completion tied to the video packet loop even after moving startup anchoring to the earliest enqueued sample.
**Pattern**: On some AirPlay/HomePod files, enough audio can be buffered and even accepted by the renderer between video packets; if only the video path checks readiness, first play can sit indefinitely until another video packet happens to advance the state.
**Rule**: When audio can independently satisfy startup conditions, let the audio enqueue path run the same preroll-completion check as the video path so playback starts from real media acceptance, not from whichever stream happens to tick next.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Startup Intent Should Follow Pipeline State, Not Just A Transient Flag

**Mistake**: Used only `isPlaying` as the final permission check before starting the synchronizer clock after preroll.
**Pattern**: During startup, buffering and actor hops can briefly leave `isPlaying` out of sync with the actual pipeline state; if preroll uses only that flag, playback can remain stuck even though audio is primed and video lead is sufficient.
**Rule**: When completing preroll, treat pipeline `.running` state as authoritative intent to start playback and use `isPlaying` only as a secondary signal.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Pull-Mode Priming Needs A Delivery Callback, Not Just An Enqueue Check

**Mistake**: Re-checked preroll readiness when the second PCM batch was queued, but not when pull-mode actually delivered the first audio sample.
**Pattern**: On some AirPlay/HomePod files, the decisive event is the first delivered sample, and that can happen after the last startup-relevant video packet. If nothing re-checks startup at delivery time, playback appears stuck even though audio is finally primed.
**Rule**: In pull-mode startup, fire a callback when the first sample is actually delivered to `AVSampleBufferAudioRenderer` and re-run preroll completion from that event.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-06 - Pull-Mode Startup Must Not Depend On Unsynchronized Priming Counters

**Mistake**: Treated the pull-mode delivered-sample counter as a reliable cross-thread startup signal even though it was written on the audio pull queue and read on the MainActor without synchronization.
**Pattern**: On AirPlay/HomePod, the first delivered sample can appear in logs while preroll still reads `audioReady=false` and remains stuck, especially if no later video packet arrives to mask the race.
**Rule**: When the first pull-mode sample matters for startup, pass its delivered PTS directly into the preroll-completion path and do not rely on unsynchronized queue-local counters to advertise priming.
**Applied**: `Rivulet/Services/Plex/Playback/Pipeline/SampleBufferRenderer.swift`, `Rivulet/Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift`.

## 2026-03-07 - Communication

**Mistake**: Implemented the first Apple TV-style preview pass from the written plan without validating the reference clip closely enough against tvOS system chrome and the sampled card geometry.
**Pattern**: UI mimic work drifts when layout and focus ownership are inferred from memory instead of checked frame-by-frame against the provided reference, especially when platform-owned chrome like the sidebar participates in focus.
**Rule**: For animation-matching tasks, inspect the reference clip early, account for system-owned UI chrome/focus before locking geometry, and verify hero/card proportions against captured frames before calling the motion pass done.
**Applied**: `Rivulet/Views/Plex/PreviewOverlayHost.swift`, `Rivulet/Views/Plex/PlexDetailView.swift`, `Rivulet/Views/TVNavigation/TVSidebarView.swift`, tvOS preview/focus mimic work.

## 2026-03-07 - Communication

**Mistake**: Started iterating on the second preview pass from live feedback without first freezing the sample clip into a written reference spec inside the repo.
**Pattern**: Motion-matching work keeps drifting when the target clip stays implicit and every correction depends on memory of the last comparison.
**Rule**: After the first correction on a visual mimic task, create a short repo-local reference document from the sample clip with observed states, inferred interactions, and fidelity constraints before making more motion changes.
**Applied**: `Docs/PREVIEW_REFERENCE_VIDEO.md`, Apple TV-style hub preview follow-up work.

## 2026-03-07 - Communication

**Mistake**: Treated the sample clip's expanded preview state as a continuous passive reveal instead of preserving the user-clarified interaction boundaries between carousel, expanded card, and details.
**Pattern**: Video-only analysis captures visible motion, but it can miss which state changes are user-triggered; if those boundaries are not recorded explicitly, future agents implement the wrong state machine.
**Rule**: When the user clarifies interaction phases that the clip does not fully prove, add them explicitly to the reference spec with a separate confidence label instead of blending them into the observed timeline.
**Applied**: `Docs/PREVIEW_REFERENCE_VIDEO.md`, hub preview state-model documentation.
