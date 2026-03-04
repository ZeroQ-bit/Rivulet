//
//  HEVCNALParser.swift
//  Rivulet
//
//  Parses length-prefixed HEVC NAL units from fMP4 sample data.
//  Used to extract and replace Dolby Vision RPU NAL units (type 62).
//

import Foundation

// MARK: - NAL Unit Types

/// HEVC NAL unit types relevant to Dolby Vision
enum HEVCNALType: UInt8 {
    case trailN = 0
    case trailR = 1
    case idrWRadl = 19
    case idrNLP = 20
    case cra = 21
    case unspec62 = 62  // Dolby Vision RPU
    case unspec63 = 63  // Dolby Vision EL

    /// Whether this NAL type is a video slice
    var isVideoSlice: Bool {
        switch self {
        case .trailN, .trailR, .idrWRadl, .idrNLP, .cra:
            return true
        default:
            return false
        }
    }
}

// MARK: - NAL Unit

/// Represents a parsed NAL unit from HEVC sample data
struct NALUnit {
    /// NAL unit type (0-63)
    let type: UInt8

    /// Full NAL unit data including header (without length prefix)
    let data: Data

    /// Range in the original sample data (includes 4-byte length prefix)
    let range: Range<Int>

    /// Whether this is a Dolby Vision RPU NAL
    var isRPU: Bool {
        type == HEVCNALType.unspec62.rawValue
    }

    /// Whether this is a Dolby Vision Enhancement Layer NAL (type 63 only).
    /// Note: DV P7 FEL uses normal video NAL types with nuh_layer_id=1,
    /// so this property alone is insufficient for FEL detection — use layer_id check instead.
    var isEL: Bool {
        type == HEVCNALType.unspec63.rawValue
    }
}

// MARK: - HEVC NAL Parser

/// Parses HEVC NAL units from fMP4 sample data.
/// fMP4 uses 4-byte length prefixes (not Annex B start codes).
final class HEVCNALParser {

    /// Length prefix size in bytes (fMP4 always uses 4-byte length)
    private let lengthPrefixSize = 4

    // MARK: - Parsing

    /// Parse all NAL units from an fMP4 sample
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: Array of parsed NAL units
    func parseNALUnits(from sampleData: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        var offset = 0

        while offset + lengthPrefixSize < sampleData.count {
            // Read 4-byte big-endian length prefix
            let length = Int(sampleData.readUInt32BE(at: offset))

            guard length > 0, offset + lengthPrefixSize + length <= sampleData.count else {
                break
            }

            let nalStart = offset + lengthPrefixSize
            let nalEnd = nalStart + length
            let nalData = sampleData.subdata(in: nalStart..<nalEnd)

            // Parse NAL unit type from first byte
            // HEVC NAL header: forbidden_zero_bit(1) + nal_unit_type(6) + nuh_layer_id(6) + nuh_temporal_id_plus1(3)
            // nal_unit_type is bits 1-6 of first byte (0 is forbidden bit)
            guard !nalData.isEmpty else {
                offset = nalEnd
                continue
            }

            let nalType = (nalData[0] >> 1) & 0x3F

            units.append(NALUnit(
                type: nalType,
                data: nalData,
                range: offset..<(nalEnd)
            ))

            offset = nalEnd
        }

        return units
    }

    /// Find the RPU NAL unit (type 62) in sample data
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: The RPU NAL unit if found, nil otherwise
    func findRPU(in sampleData: Data) -> NALUnit? {
        guard let rpuRange = findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) else {
            return nil
        }

        let nalStart = rpuRange.lowerBound + lengthPrefixSize
        let nalData = sampleData.subdata(in: nalStart..<rpuRange.upperBound)

        return NALUnit(
            type: HEVCNALType.unspec62.rawValue,
            data: nalData,
            range: rpuRange
        )
    }

    /// Replace the RPU NAL unit in sample data with new RPU data
    /// - Parameters:
    ///   - sampleData: Original sample data
    ///   - newRPU: New RPU NAL unit data (without length prefix)
    /// - Returns: Modified sample data with replaced RPU, or original if no RPU found
    func replaceRPU(in sampleData: Data, with newRPU: Data) -> Data {
        guard let existingRPU = findRPU(in: sampleData) else {
            return sampleData
        }
        return replaceRPU(in: sampleData, existingRPU: existingRPU, with: newRPU)
    }

    /// Replace an already-found RPU NAL unit with new data (avoids re-parsing)
    /// - Parameters:
    ///   - sampleData: Original sample data
    ///   - existingRPU: The RPU NAL unit previously found via findRPU
    ///   - newRPU: New RPU NAL unit data (without length prefix)
    /// - Returns: Modified sample data with replaced RPU
    func replaceRPU(in sampleData: Data, existingRPU: NALUnit, with newRPU: Data) -> Data {
        var result = Data()
        result.reserveCapacity(sampleData.count + newRPU.count - existingRPU.data.count)

        // Copy data before the RPU
        if existingRPU.range.lowerBound > 0 {
            result.append(sampleData.subdata(in: 0..<existingRPU.range.lowerBound))
        }

        // Write new RPU with length prefix
        var length = UInt32(newRPU.count).bigEndian
        result.append(Data(bytes: &length, count: 4))
        result.append(newRPU)

        // Copy data after the RPU
        if existingRPU.range.upperBound < sampleData.count {
            result.append(sampleData.subdata(in: existingRPU.range.upperBound..<sampleData.count))
        }

        return result
    }

    /// Check if the sample contains a Dolby Vision RPU
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: true if an RPU NAL unit is present
    func hasRPU(in sampleData: Data) -> Bool {
        findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) != nil
    }

    /// Fast scan for RPU NAL (type 62) without allocating NALUnit structs.
    /// Only reads length prefixes and the first byte of each NAL header.
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: true if a NAL type 62 is present
    func hasRPUFast(in sampleData: Data) -> Bool {
        findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) != nil
    }

    private func findNALRange(in sampleData: Data, type targetType: UInt8) -> Range<Int>? {
        sampleData.withUnsafeBytes { buffer -> Range<Int>? in
            guard let base = buffer.baseAddress else { return nil }
            let count = buffer.count
            var offset = 0

            while offset + lengthPrefixSize < count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length > 0, offset + lengthPrefixSize + length <= count else { break }

                // Read NAL type from first byte: bits 1-6
                let nalType = (base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self) >> 1) & 0x3F
                if nalType == targetType {
                    return offset..<(offset + lengthPrefixSize + length)
                }

                offset += lengthPrefixSize + length
            }
            return nil
        }
    }

    /// Strip all Enhancement Layer NAL units from sample data.
    /// DV Profile 7 is dual-layer (BL + EL + RPU). After converting RPU from P7→P8.1,
    /// the EL NALs are orphaned and cause VideoToolbox to stutter on Apple TV (which
    /// only supports single-layer DV profiles 5/8).
    ///
    /// EL NALs come in two flavors depending on the muxing:
    /// - **MEL/interleaved**: NAL type 63 (unspec63) with layer_id=0
    /// - **FEL**: Normal video NAL types (TRAIL_R, IDR, etc.) with nuh_layer_id=1
    /// Both must be detected and stripped. RPU (type 62) is always kept.
    ///
    /// - Parameter sampleData: Sample data with RPU already converted to P8.1
    /// - Returns: Sample data with EL NALs removed, or original data if no EL found
    func stripEnhancementLayer(from sampleData: Data) -> Data {
        sampleData.withUnsafeBytes { buffer -> Data in
            guard let base = buffer.baseAddress else { return sampleData }
            let count = buffer.count

            // Need at least 2 bytes of NAL header to read layer_id
            guard count > lengthPrefixSize + 2 else { return sampleData }

            // First pass: check if any EL NALs exist (avoid allocation if not needed)
            var hasEL = false
            var offset = 0
            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)

                // EL NAL: type 63 (MEL) OR non-zero layer_id (FEL), but never RPU
                if nalType != HEVCNALType.unspec62.rawValue &&
                   (nalType == HEVCNALType.unspec63.rawValue || layerId != 0) {
                    hasEL = true
                    break
                }
                offset += lengthPrefixSize + length
            }

            guard hasEL else { return sampleData }

            // Second pass: copy only BL + RPU NALs to output
            var result = Data()
            result.reserveCapacity(count) // Upper bound; actual will be smaller
            offset = 0

            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)
                let nalTotalSize = lengthPrefixSize + length

                // Keep: RPU (type 62), or BL NALs (layer_id=0 and not type 63)
                let isRPU = nalType == HEVCNALType.unspec62.rawValue
                let isEL = nalType == HEVCNALType.unspec63.rawValue || layerId != 0
                if isRPU || !isEL {
                    result.append(
                        UnsafeBufferPointer(
                            start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                            count: nalTotalSize
                        )
                    )
                }

                offset += nalTotalSize
            }

            return result
        }
    }

    /// Get summary of NAL units in sample (for debugging)
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: String describing the NAL units present
    func describeSample(_ sampleData: Data) -> String {
        let units = parseNALUnits(from: sampleData)
        let types = units.map { "NAL\($0.type)" }
        return "[\(types.joined(separator: ", "))]"
    }

    /// Detailed NAL dump showing type, layer_id, and size for each NAL unit.
    /// Used to diagnose DV P7 FEL content where EL NALs share BL types but differ by layer_id.
    func describeDetailed(_ sampleData: Data) -> String {
        sampleData.withUnsafeBytes { buffer -> String in
            guard let base = buffer.baseAddress else { return "empty" }
            let count = buffer.count
            var descriptions: [String] = []
            var offset = 0

            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)

                let layerStr = layerId > 0 ? " L\(layerId)" : ""
                descriptions.append("T\(nalType)\(layerStr) \(length)B")

                offset += lengthPrefixSize + length
            }

            return "[\(descriptions.joined(separator: ", "))]"
        }
    }
}

// Note: Uses Data.readUInt32BE extension from FMP4Demuxer.swift
