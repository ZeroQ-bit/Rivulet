//
//  DoviProfileConverter.swift
//  Rivulet
//
//  High-level orchestrator for converting Dolby Vision Profile 7 (MEL) and Profile 8.6
//  content to Profile 8.1 format for Apple TV compatibility.
//
//  The conversion happens on-the-fly as video samples are processed:
//  1. Parse NAL units from fMP4 sample data
//  2. Find and extract RPU NAL (type 62)
//  3. Parse RPU with libdovi and detect profile
//  4. Convert to Profile 8.1 using mode 2
//  5. Replace RPU in sample with converted version
//

import Foundation

// MARK: - Profile Converter

/// Converts Dolby Vision Profile 7/8.6 samples to Profile 8.1 on-the-fly
final class DoviProfileConverter {

    // MARK: - Dependencies

    private let nalParser = HEVCNALParser()
    private let libdovi = LibdoviWrapper()

    // MARK: - State (cached after first frame detection)

    /// Detected DV profile from first RPU (nil until first sample with RPU)
    private(set) var detectedProfile: UInt8?

    /// Whether conversion is needed for this stream
    private(set) var needsConversion = false

    /// Number of frames processed
    private(set) var framesProcessed = 0

    /// Number of frames successfully converted
    private(set) var framesConverted = 0

    /// Number of conversion failures (falls back to original)
    private(set) var conversionFailures = 0

    // MARK: - Timing Instrumentation

    /// Rolling window of recent conversion times (seconds)
    private var recentTimings: [Double] = []
    private let timingWindowSize = 48

    /// Rolling average conversion time in milliseconds
    private(set) var averageConversionTimeMs: Double = 0

    /// Whether conversion can sustain the given framerate based on recent measurements.
    /// Returns true if fewer than `timingWindowSize` frames have been measured (not enough data).
    func canSustainRealTime(fps: Double = 23.976) -> Bool {
        guard recentTimings.count >= timingWindowSize else { return true }
        let budgetMs = 1000.0 / fps
        return averageConversionTimeMs <= budgetMs
    }

    /// Record a conversion timing measurement and update rolling average
    private func recordTiming(_ seconds: Double) {
        recentTimings.append(seconds)
        if recentTimings.count > timingWindowSize {
            recentTimings.removeFirst()
        }
        averageConversionTimeMs = (recentTimings.reduce(0, +) / Double(recentTimings.count)) * 1000.0
    }

    // MARK: - Processing

    /// Process a video sample, converting DV profile if needed
    /// - Parameter data: Raw video sample data from fMP4
    /// - Returns: Processed sample data (converted if needed, original otherwise)
    func processVideoSample(_ data: Data) -> Data {
        framesProcessed += 1

        // Find RPU NAL unit in the sample
        guard let rpu = nalParser.findRPU(in: data) else {
            // No RPU in this sample - pass through unchanged
            // This is normal for non-DV content or some frame types
            return data
        }

        // First RPU - detect profile and decide if conversion needed
        if detectedProfile == nil {
            detectProfile(from: rpu.data)
        }

        // If no conversion needed, pass through unchanged
        guard needsConversion else {
            return data
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Convert the RPU
        guard let convertedRPU = convertRPU(rpu.data) else {
            conversionFailures += 1
            // Fallback: return original sample (will still work, just wrong profile)
            return data
        }

        // Replace RPU in sample with converted version (using pre-found NAL to avoid re-parsing)
        var convertedSample = nalParser.replaceRPU(in: data, existingRPU: rpu, with: convertedRPU)

        // Strip Enhancement Layer NALs (type 63) for Profile 7.
        // P7 is dual-layer (BL + EL + RPU). After converting RPU to P8.1, the EL NALs
        // are orphaned — Apple TV only supports single-layer DV (P5/P8) and the EL causes
        // VideoToolbox to stutter. This is equivalent to dovi_tool's `convert --discard`.
        if detectedProfile == 7 {
            convertedSample = nalParser.stripEnhancementLayer(from: convertedSample)
        }

        framesConverted += 1

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        recordTiming(elapsed)

        // Log timing periodically
        if framesConverted == 1 {
            let strippedNote = detectedProfile == 7 ? " (with EL strip)" : ""
            print("[DoviConverter] First frame conversion\(strippedNote): \(String(format: "%.1f", elapsed * 1000))ms (in=\(data.count)B out=\(convertedSample.count)B)")
            // Dump NAL structure of first frame for diagnostics
            let nalDump = nalParser.describeDetailed(data)
            print("[DoviConverter] Input NALs: \(nalDump)")
            if convertedSample.count != data.count {
                let outDump = nalParser.describeDetailed(convertedSample)
                print("[DoviConverter] Output NALs: \(outDump)")
            }
        } else if framesConverted == timingWindowSize {
            print("[DoviConverter] Conversion avg after \(timingWindowSize) frames: \(String(format: "%.1f", averageConversionTimeMs))ms/frame (budget=41.7ms at 23.976fps)")
        } else if framesConverted % 240 == 0 {
            print("[DoviConverter] Conversion avg: \(String(format: "%.1f", averageConversionTimeMs))ms/frame (\(framesConverted) frames)")
        }

        return convertedSample
    }

    /// Reset converter state (call when starting new stream)
    func reset() {
        detectedProfile = nil
        needsConversion = false
        framesProcessed = 0
        framesConverted = 0
        conversionFailures = 0
        recentTimings.removeAll()
        averageConversionTimeMs = 0
    }

    // MARK: - Private

    /// Detect profile from RPU data and determine if conversion is needed
    private func detectProfile(from rpuData: Data) {
        do {
            let rpu = try libdovi.parseRPU(nalData: rpuData)
            defer { libdovi.free(rpu: rpu) }

            let info = libdovi.getInfo(rpu: rpu)
            detectedProfile = info.profile
            let elTypeLog = info.elType ?? "unknown"
            print(
                "[DoviConverter] Detected RPU profile=\(info.profile) " +
                "elType=\(elTypeLog) fel=\(info.isFEL)"
            )

            // Determine if we need to convert
            switch info.profile {
            case 7:
                // Profile 7 needs conversion to Profile 8.1
                needsConversion = true

                // Warn about FEL quality limitation
                if info.isFEL {
                    print("🎬 [DoviConverter] ⚠️ FEL content detected - enhancement layer data will be discarded, some quality loss expected")
                }

            case 8:
                // Profile 8 conversion is enabled at a higher level based on BL CompatID
                // If we reach here, conversion was requested for this P8 stream
                needsConversion = true

            case 5:
                // Profile 5 is natively compatible, no conversion needed
                needsConversion = false

            default:
                needsConversion = false
            }

        } catch {
            print("🎬 [DoviConverter] Failed to detect profile: \(error.localizedDescription)")
            // Assume conversion needed if detection fails but converter was enabled
            needsConversion = true
        }
    }

    /// Convert RPU data to Profile 8.1
    private func convertRPU(_ rpuData: Data) -> Data? {
        do {
            let rpu = try libdovi.parseRPU(nalData: rpuData)
            defer { libdovi.free(rpu: rpu) }

            // Convert to Profile 8.1 (mode 2)
            try libdovi.convert(rpu: rpu, mode: .toProfile81)

            // Write back as NAL unit
            return try libdovi.writeNAL(rpu: rpu)

        } catch {
            // Log but don't spam - only log occasionally
            if conversionFailures < 5 || conversionFailures % 100 == 0 {
                print("🎬 [DoviConverter] Conversion failed (failure #\(conversionFailures + 1)): \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Get conversion statistics summary
    func getStatsSummary() -> String {
        let successRate = framesProcessed > 0
            ? Double(framesConverted) / Double(framesProcessed) * 100
            : 0

        return "Profile \(detectedProfile ?? 0): \(framesConverted)/\(framesProcessed) converted (\(String(format: "%.1f", successRate))%), \(conversionFailures) failures"
    }
}
