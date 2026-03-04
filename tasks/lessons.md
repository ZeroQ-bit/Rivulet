# Lessons Learned

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
