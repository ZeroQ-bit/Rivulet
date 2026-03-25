# Autonomous Playback Testing Harness

## Overview

An automated system for testing Rivulet playback quality on a real Apple TV. Claude can autonomously build, deploy, play content, read diagnostic logs, assess quality, fix issues, and repeat.

## Architecture

### App-Side Components

**PlaybackHealthReport** (`PlaybackJitterStats.swift`)
- Struct that aggregates all playback quality signals into a single-line log
- Computed `verdict`: GOOD / WARN / BAD based on signal thresholds
- Emitted every 5 seconds during playback via `[PlaybackHealth]` log prefix

**Health Report Emission** (`DirectPlayPipeline.swift`)
- Periodic health reports every 5s in the read loop
- Event logs: `preroll_complete`, `pause`, `resume`, `seek`
- Per-period counters: late frames, drops, resyncs, slow frames, display errors
- Audio quality: path (decode/passthrough), route (airplay/hdmi), pull deliveries

**Auto-Play Debug Mode** (`ContentView.swift`, `#if DEBUG` only)
- Environment variable driven: `RIVULET_AUTOPLAY`, `RIVULET_AUTOPLAY_KEY`, etc.
- Bypasses normal UI, fetches metadata, presents player directly
- Optional test lifecycle: play 15s → pause 2s → resume 10s → seek +30s → play 10s
- Exits with `exit(0)` when complete

### Claude-Side Components

**Skill**: `~/.claude/skills/playback-test/SKILL.md`
- Triggered by: "test playback", "fix DV", "/playback-test"
- Two modes: **test** (one cycle) and **fix** (autonomous iteration loop)
- Signal-to-diagnosis map for automated root cause analysis
- Iteration tracking table for fix mode

## How to Use

### One-Shot Test
```
/playback-test 175286
```

### Autonomous Fix Loop
```
Fix the DV playback. Use Warfare (175103) as benchmark, The Rip (175286) as baseline regression check. Iterate until GOOD.
```

Claude will autonomously cycle: diagnose → fix code → build → deploy → test → compare → repeat.

## Build & Deploy Commands

```bash
# Build (3-4 min)
xcodebuild -scheme Rivulet -destination 'platform=tvOS,name=Master Bedroom (2)' build 2>&1 | grep -E "error:|BUILD" | tail -10

# Deploy to Apple TV (~10s)
xcrun devicectl device install app --device "Master Bedroom (2)" \
  "/Users/bain/Library/Developer/Xcode/DerivedData/Rivulet-gtbkhdpuopsukyawhbppvdoinvmv/Build/Products/Debug-appletvos/Rivulet.app" \
  2>&1 | tail -3

# Launch with auto-play
DEVICECTL_CHILD_RIVULET_AUTOPLAY=1 \
DEVICECTL_CHILD_RIVULET_AUTOPLAY_KEY=175286 \
DEVICECTL_CHILD_RIVULET_AUTOPLAY_DURATION=45 \
DEVICECTL_CHILD_RIVULET_AUTOPLAY_SKIP_LIFECYCLE=1 \
xcrun devicectl device process launch --console --device "Master Bedroom (2)" com.gstudios.rivulet \
  2>&1 | grep -E "\[PlaybackHealth\]|\[AutoPlay\]|\[DirectPlay\] Opened|\[ContentRouter\]"
```

The `DEVICECTL_CHILD_` prefix passes env vars to the launched app process.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RIVULET_AUTOPLAY` | Enable auto-play mode | (must be set) |
| `RIVULET_AUTOPLAY_KEY` | Plex ratingKey to play | `161234` |
| `RIVULET_AUTOPLAY_DURATION` | Total test duration (seconds) | `60` |
| `RIVULET_AUTOPLAY_SKIP_LIFECYCLE` | Skip pause/seek phases | (unset) |

## Health Report Format

### Periodic (every 5s)
```
[PlaybackHealth] t=20.7s fps=24.0 wall=1.010x late=0 drops=0 resyncs=0 slowFrames=25
  audioStatus=1 audioPull=true audioPath=decode audioRoute=airplay audioAhead=0.3s
  audioDrops=0 audioPullDel=30 displayErr=0 gapMax=292ms gapσ=82.3ms syncDrift=-0.0%
  verdict=GOOD
```

### Events
```
[PlaybackHealth] EVENT=preroll_complete elapsed=54ms
[PlaybackHealth] EVENT=pause
[PlaybackHealth] EVENT=resume
[PlaybackHealth] EVENT=seek from=22.9s to=52.8s
```

## Signal Reference

| Signal | GOOD | WARN | BAD | What it means |
|--------|------|------|-----|---------------|
| `wall` | ≥0.95 | 0.90-0.95 | <0.90 | Media time / wall time ratio |
| `late` | 0 | >0 | - | Frames arriving past their PTS |
| `drops` | 0 | 1 | >1 | Frames skipped entirely |
| `resyncs` | 0 | - | >0 | Emergency timeline resets |
| `audioStatus` | 1 | - | ≠1 | 0=unknown, 1=rendering, 2=failed |
| `audioPath` | decode | - | passthrough+airplay | Decode path (passthrough is silent on AirPlay) |
| `audioAhead` | >0 | <0 | - | Buffer health (video enqueue ahead of sync clock) |
| `audioPullDel` | >0 | 0+status≠1 | - | Pull-mode deliveries this period |
| `displayErr` | 0 | - | >0 | Video layer failures |
| `gapMax` | <500ms | >500ms | - | Worst PTS gap (B-frame reordering causes ~290ms normally) |
| `syncDrift` | <5% | >5% | - | Sustained clock drift |

**Special rule**: `audioRoute=airplay` + `audioPath=passthrough` → BAD (silent audio)

## Known Test Content

| ratingKey | Title | Profile | Audio | Expected |
|-----------|-------|---------|-------|----------|
| 175286 | The Rip | 1080p HEVC SDR | AAC 5.1 | GOOD (baseline) |
| 143855 | Interstellar | 4K DV Profile 8 | TrueHD 7.1 | BAD (DV + heavy audio) |
| 175103 | Warfare | 4K DV Profile 7 | TrueHD+AC3 | BAD (DV conversion) |

## Baseline Results (2026-03-18)

### The Rip (1080p HEVC) — GOOD
```
wall=1.005x fps=24.0 late=0 drops=0 resyncs=0
audioStatus=1 audioPath=decode audioRoute=airplay audioPullDel=30/period
preroll=54ms
```

### Interstellar (4K DV P8 + TrueHD) — BAD
```
wall=0.43-0.57x fps=12-20 late=40-74 drops=3-33 resyncs=2-7
syncDrift=-23% to -59%
Root cause: TrueHD decode + 4K DV overwhelms pipeline
```

### Warfare (4K DV P7 + conversion) — BAD
```
wall=0.44-0.60x fps=7.5-9.9 late=55-87 drops=34-50 resyncs=3-6
gapMax=917ms
Root cause: DV P7→P8.1 conversion is the primary bottleneck
```

## Target Device

- **Name**: Master Bedroom (2)
- **Model**: Apple TV 4K 3rd gen (AppleTV14,1)
- **Bundle ID**: com.gstudios.rivulet

## Key Source Files

| File | Role |
|------|------|
| `Pipeline/PlaybackJitterStats.swift` | `PlaybackHealthReport`, `JitterSnapshot`, verdict logic |
| `Pipeline/DirectPlayPipeline.swift` | Read loop, health emission, late/drop/resync counters |
| `Pipeline/SampleBufferRenderer.swift` | A/V rendering, audio pull-mode, `totalAudioPullDeliveries` |
| `ContentView.swift` | `#if DEBUG` auto-play launcher + test lifecycle |
| `~/.claude/skills/playback-test/SKILL.md` | Claude skill for autonomous testing |

## DV-Specific Tuning Already Applied

The user has already tuned these parameters for DV conversion (visible in the diff):
- `maxVideoLookahead = 2.5` for DV conversion (was 1.2)
- `lateVideoDropThreshold = 3.0` for conversion (was 0.75)
- `forceLateResyncThreshold = 8.0` for conversion (was 2.0)
- `maxConsecutiveLateFramesBeforeResync = 120` for conversion (was 24)
- `softLateDropThreshold = 3.0` for conversion (was 0.90)
- 60s startup grace period for late video detection during conversion
- `requiredPrerollLeadSeconds = 1.50` for conversion (was 0.20)
- `prerollTimeout = 5000ms` for conversion (was 1000)
- `rebuildFormatDescriptionWithDVCC()` called for conversion to signal P8.1 to VideoToolbox
