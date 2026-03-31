# Bug: Audio-only playback on AirPlay (AVPlayer Direct)

**Date:** 2026-03-31
**Status:** Not investigated

## Symptoms

- Audio plays, no video renders
- AVPlayerItem status stays at 0 (unknown), never reaches readyToPlay
- Exit takes ~10 seconds after pressing back

## Playback Path

AVPlayerDirect (not remux) — `[ContentRouter] mp4 | audio=aac → AVPlayerDirect`

## Environment

- AirPlay active (`airPlay=true`)
- Display criteria: SDR @ 23.976fps (1920x1080)
- Display criteria matching DISABLED in system settings

## File Info

- **File:** Curious George - S01E43-44 - Curious George Takes A Vacation + Curious George and the One That Got Away (WEBRip-1080p).mp4
- **Container:** MP4
- **Video:** HEVC Main, 1080p, 524 kbps, 8-bit, bt709, 23.976fps
  - Codec ID: hvc1
  - Profile: main, Level 4.0
  - Color: bt709/bt709/bt709, tv range
- **Audio:** AAC Stereo, 160 kbps, 48kHz, English
- **Duration:** 23:40
- **Size:** 116.86 MB
- **Web Optimized:** No

## Notes

- HEVC Main 8-bit with AAC stereo should be natively playable by AVPlayer
- Could be an AirPlay-specific issue — may work fine on local display
- The `FigApplicationStateMonitor` error (-19431) appeared but is likely unrelated
- Worth testing: same file without AirPlay, different HEVC file on AirPlay
