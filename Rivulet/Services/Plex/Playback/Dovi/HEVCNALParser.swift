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

    /// Whether this is a Dolby Vision Enhancement Layer NAL
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
        let units = parseNALUnits(from: sampleData)
        return units.first(where: { $0.isRPU })
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
        findRPU(in: sampleData) != nil
    }

    /// Get summary of NAL units in sample (for debugging)
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: String describing the NAL units present
    func describeSample(_ sampleData: Data) -> String {
        let units = parseNALUnits(from: sampleData)
        let types = units.map { "NAL\($0.type)" }
        return "[\(types.joined(separator: ", "))]"
    }
}

// Note: Uses Data.readUInt32BE extension from FMP4Demuxer.swift
