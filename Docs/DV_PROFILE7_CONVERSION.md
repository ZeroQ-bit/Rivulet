# Dolby Vision Profile 7 → Profile 8.1 Real-Time Conversion

## Overview

Rivulet performs real-time conversion of DV Profile 7 content to Profile 8.1 for playback on Apple TV. No other tvOS player does this — Infuse requires pre-processing with dovi_tool, falling back to HDR10 for unconverted P7 content.

## What DV Profile 7 Is

DV P7 is a **dual-layer format**: Base Layer (BL) + Enhancement Layer (EL) + RPU metadata.
- **BL**: Standard HEVC video (HDR10-compatible)
- **EL**: Enhancement data that improves the BL (can be MEL or FEL)
- **RPU**: Dolby Vision metadata (NAL type 62) describing tone mapping

Apple TV only supports **single-layer** DV profiles (P5, P8). P7's dual-layer format causes VideoToolbox to stutter or fail.

## Conversion Pipeline

```
readPacket() → convertRPU(P7→P8.1) → stripEL → createSampleBuffer → enqueueVideo
                    ↑ 0.3-1.0ms            ↑ 0.1ms
```

### Step 1: RPU Conversion (DoviProfileConverter)
- Parse RPU NAL (type 62) with libdovi
- Detect profile on first frame (cached for stream)
- Convert RPU from P7 to P8.1 using libdovi mode 2
- Replace RPU NAL in sample data

### Step 2: Enhancement Layer Stripping (HEVCNALParser)
- Strip all EL NALs from the converted sample
- Two detection modes (both checked):
  - **MEL/interleaved**: NAL type 63 (`unspec63`) with `nuh_layer_id=0`
  - **FEL**: Normal video NAL types (TRAIL_R, IDR, etc.) with `nuh_layer_id=1`
- RPU (type 62) is always preserved regardless of layer_id
- Two-pass: first checks if any EL exists (avoids allocation), then copies non-EL NALs

### Step 3: Auto-Fallback
After 48 frames, checks if conversion can sustain real-time (avg time < frame budget).
If not, disables conversion for remainder of stream (HDR10 passthrough).

## NAL Header Parsing

HEVC NAL header is 2 bytes:
```
byte0: [forbidden(1)] [nal_type(6)] [layer_id_bit5(1)]
byte1: [layer_id_bits4-0(5)] [temporal_id(3)]

nalType = (byte0 >> 1) & 0x3F
layerId = ((byte0 & 0x01) << 5) | ((byte1 >> 3) & 0x1F)
```

## Typical Frame Structure (P7 MEL MKV)

```
Input (1.4MB):
  T35  3B     AUD (Access Unit Delimiter)
  T32  34B    VPS (Video Parameter Set)
  T33  62B    SPS (Sequence Parameter Set)
  T34  7B     PPS (Picture Parameter Set)
  T39  6-30B  SEI messages (×6)
  T20  1.2MB  IDR slice (Base Layer)
  T63  5-63B  EL parameter sets (×10, MEL)
  T63  9-43KB EL slice data (MEL)
  T62  223B   RPU (Dolby Vision metadata)

Output (1.2MB):
  T35  3B     AUD
  T32  34B    VPS
  T33  62B    SPS
  T34  7B     PPS
  T39  6-30B  SEI messages (×6)
  T20  1.2MB  IDR slice (Base Layer)
  T62  188B   RPU (converted P8.1)
```

## Performance

Measured on Apple TV 4K (A15):
- RPU conversion + EL strip: **0.3–1.0ms/frame** (budget: 41.7ms at 23.976fps)
- CPU usage: ~2% of frame budget
- Memory: negligible (in-place data manipulation)

## Current Status & Known Issues

### Working
- RPU conversion (P7 → P8.1) via libdovi ✅
- EL stripping (both MEL type-63 and FEL layer-id based) ✅
- Inline conversion in read loop (no buffered pipeline overhead) ✅
- Auto-fallback to HDR10 if conversion too slow ✅
- First-frame NAL diagnostic logging ✅

### Video: Plays but Quality Unclear
- Jitter stats show ~23fps, 0 drops, 0 stalls, 100% sync
- The high jitter σ (~112ms) is a **measurement artifact** from B-frame PTS reordering in decode order, not actual stutter
- User perceives "skipping" — unclear if this is real frame-level issues or perception due to missing audio
- **Possible issue**: VPS (T32) still describes dual-layer P7; may confuse VideoToolbox
- **Possible issue**: No `dvcC` box in format description (tells VT which DV profile)
  - Adding dvcC caused blank screen — likely conflicts with P7 hvcC parameter sets
  - May need to also modify hvcC or VPS for dvcC to work

### Audio: Not Working for DV Content
- AC3 passthrough via AVSampleBufferAudioRenderer produces silence during DV playback
- Same AC3 passthrough works fine for non-DV DirectPlay content
- Root cause likely: **HDMI renegotiation** when Apple TV switches to DV display mode
  - DisplayCriteria change triggers HDMI mode switch
  - Audio capabilities may not re-establish properly for compressed passthrough
  - HDMI output reports 2ch even when connected to 5.1 AVR
- TrueHD auto-promotion initially exposed a demuxer limitation:
  - `selectAudioStream()` still cannot build a CoreAudio format description for TrueHD (`AV_CODEC_ID_TRUEHD`)
  - This is now handled with `selectAudioStreamForClientDecode()`, which switches the demuxer without requiring a CoreAudio format description
- **Remaining work**: Validate that the client-decode path is reliable enough to be the default answer for DV + lossless audio

### What dovi_tool Does Differently
Our conversion replicates most of `dovi_tool convert --discard`, but not all:
1. ✅ Convert RPU P7 → P8.1
2. ✅ Strip Enhancement Layer NALs
3. ❌ Modify VPS to remove multi-layer configuration
4. ❌ Create proper dvcC/dvvC configuration box
5. ❌ Strip EL parameter sets from hvcC extradata

Items 3-5 may be needed for fully correct playback.

## Architecture Decisions

### Why Inline (Not Buffered Pipeline)
The initial implementation used a buffered pipeline (AsyncStream + converter task + backpressure gate) designed for 90-155ms conversion times. Actual conversion is 0.3-1.0ms, making the pipeline unnecessary. The pipeline's multiple `await MainActor.run` hops across two tasks caused MainActor contention, throttling the converter to ~9fps. Inline conversion (single task, single set of MainActor hops) matches the non-DV code path exactly.

### Why Auto-Promote Audio for DV
When DV conversion is active, the HDMI display criteria change can disrupt audio passthrough. Client-side decoded audio (PCM output) is immune to HDMI negotiation issues. Since DV conversion uses <2% of the frame budget, there's ample CPU headroom for audio decode.

## Files

| File | Purpose |
|------|---------|
| `Services/Plex/Playback/Dovi/HEVCNALParser.swift` | NAL parsing, RPU find/replace, EL stripping |
| `Services/Plex/Playback/Dovi/DoviProfileConverter.swift` | RPU conversion orchestrator, timing instrumentation |
| `Services/Plex/Playback/Dovi/LibdoviWrapper.swift` | C bridge to libdovi |
| `Services/Plex/Playback/Pipeline/DirectPlayPipeline.swift` | Integration point (inline conversion in read loop) |
| `Services/Plex/Playback/FFmpeg/FFmpegDemuxer.swift` | Format description creation, dvcC rebuild method |

## Next Steps (Priority Order)

1. **Fix audio**: Make TrueHD client-side decode work for DV content
   - Fix `selectAudioStream()` atomicity (revert on failure)
   - For client-side decode path, set stream index without requiring CoreAudio format description
   - Or: add TrueHD to `createAudioFormatDescription` (may not have a CoreAudio equivalent)
2. **Verify video quality**: Once audio works, re-evaluate if video "skipping" was real or perception
3. **Investigate VPS modification**: If video still stutters with audio working, the VPS dual-layer signaling may need to be fixed
4. **Investigate dvcC approach**: May need to strip EL-related data from hvcC before adding dvcC

## References

- [dovi_tool](https://github.com/quietvoid/dovi_tool) — Reference implementation for P7→P8 conversion
- [DV7toDV8](https://github.com/nekno/DV7toDV8) — Wrapper script for dovi_tool conversion
- [Infuse DV P7 thread](https://community.firecore.com/t/dolby-vision-profile-7/48022) — Infuse requires pre-processing, falls back to HDR
- HEVC NAL unit header: ITU-T H.265 §7.3.1.2
- DOVIDecoderConfigurationRecord: Dolby Vision Streams Within the ISO BMFF spec
