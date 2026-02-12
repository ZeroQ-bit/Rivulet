//
//  FMP4Demuxer.swift
//  Rivulet
//
//  Manual ISO BMFF (fMP4) parser for extracting video/audio samples.
//  Creates dvh1-tagged CMFormatDescriptions for Dolby Vision decode via AVSampleBufferDisplayLayer.
//

import Foundation
import CoreMedia
import VideoToolbox
import Sentry

// MARK: - Demuxed Sample

/// A single demuxed sample (video frame or audio frame) ready for CMSampleBuffer creation
struct DemuxedSample {
    let trackID: UInt32
    let data: Data
    let pts: CMTime
    let dts: CMTime
    let duration: CMTime
    let isKeyframe: Bool
    let isVideo: Bool
}

// MARK: - Track Info

/// Metadata about a track parsed from the init segment
struct DemuxedTrackInfo {
    let trackID: UInt32
    let isVideo: Bool
    let timescale: UInt32
    let width: UInt32
    let height: UInt32
    let formatDescription: CMFormatDescription
}

// MARK: - FMP4 Demuxer

/// Parses ISO BMFF (fMP4) segments to extract individual samples.
/// Handles init segments (moov) for codec config and media segments (moof+mdat) for sample data.
final class FMP4Demuxer {

    // MARK: - Parsed State

    private(set) var tracks: [UInt32: DemuxedTrackInfo] = [:]
    private(set) var videoTrackID: UInt32?
    private(set) var audioTrackID: UInt32?

    /// Whether we successfully created a dvh1 format description
    private(set) var hasDVFormatDescription = false

    /// Codec and resolution info for Sentry diagnostics
    private(set) var videoCodecType: String?
    private(set) var audioCodecType: String?
    private(set) var videoResolution: String?

    /// Optional profile converter for P7/P8.6 → P8.1 conversion
    /// Set this before parsing media segments to enable on-the-fly conversion
    var profileConverter: DoviProfileConverter?

    // MARK: - Init Segment Parsing

    /// Parse an init segment (ftyp + moov) to extract track info and codec configuration.
    /// Must be called before parsing any media segments.
    func parseInitSegment(_ data: Data, forceDVH1: Bool = true) throws {
        let boxes = parseBoxes(data: data, offset: 0, length: data.count)

        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            let error = DemuxerError.missingBox("moov")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_demuxer", key: "component")
                scope.setTag(value: "init_segment", key: "error_type")
                scope.setExtra(value: data.count, key: "init_segment_size")
                scope.setExtra(value: boxes.map { $0.type }.joined(separator: ", "), key: "top_level_boxes")
            }
            throw error
        }

        let moovChildren = parseBoxes(data: data, offset: moov.contentOffset, length: moov.contentLength)

        for trak in moovChildren where trak.type == "trak" {
            if let trackInfo = try parseTrak(data: data, box: trak, forceDVH1: forceDVH1) {
                tracks[trackInfo.trackID] = trackInfo
                if trackInfo.isVideo {
                    videoTrackID = trackInfo.trackID
                } else {
                    audioTrackID = trackInfo.trackID
                }
            }
        }

        if tracks.isEmpty {
            let error = DemuxerError.noTracksFound
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_demuxer", key: "component")
                scope.setTag(value: "init_segment", key: "error_type")
                scope.setExtra(value: data.count, key: "init_segment_size")
            }
            throw error
        }
    }

    // MARK: - Media Segment Parsing

    /// Parse a media segment (moof + mdat) and return individual samples.
    private var segmentParseCount = 0

    func parseMediaSegment(_ data: Data) throws -> [DemuxedSample] {
        let boxes = parseBoxes(data: data, offset: 0, length: data.count)

        segmentParseCount += 1
        if segmentParseCount == 1 {
        }

        var samples: [DemuxedSample] = []

        // Process moof+mdat pairs
        var i = 0
        while i < boxes.count {
            if boxes[i].type == "moof" {
                let moofBox = boxes[i]
                // mdat should follow moof
                let mdatBox: BoxInfo?
                if i + 1 < boxes.count && boxes[i + 1].type == "mdat" {
                    mdatBox = boxes[i + 1]
                    i += 2
                } else {
                    // mdat might not immediately follow; search for it
                    mdatBox = boxes.first(where: { $0.type == "mdat" && $0.offset > moofBox.offset })
                    i += 1
                }

                if let mdatBox = mdatBox {
                    let fragmentSamples = try parseFragment(data: data, moof: moofBox, mdat: mdatBox)
                    samples.append(contentsOf: fragmentSamples)
                }
            } else {
                i += 1
            }
        }

        // Convert DV profiles if converter is enabled
        if let converter = profileConverter {
            samples = samples.map { sample in
                guard sample.isVideo else { return sample }
                let convertedData = converter.processVideoSample(sample.data)
                // Always use converted data for video samples when converter is active
                // (converted RPU may have same byte length as original)
                return DemuxedSample(
                    trackID: sample.trackID,
                    data: convertedData,
                    pts: sample.pts,
                    dts: sample.dts,
                    duration: sample.duration,
                    isKeyframe: sample.isKeyframe,
                    isVideo: sample.isVideo
                )
            }
        }

        // Sort samples by DTS to interleave video and audio.
        // Without this, all video samples are enqueued before any audio,
        // starving the audio renderer and causing A/V desync.
        samples.sort { CMTimeCompare($0.dts, $1.dts) < 0 }

        return samples
    }

    // MARK: - CMSampleBuffer Creation

    /// Create a CMSampleBuffer from a demuxed sample, suitable for AVSampleBufferDisplayLayer/AudioRenderer
    func createSampleBuffer(from sample: DemuxedSample) throws -> CMSampleBuffer {
        guard let trackInfo = tracks[sample.trackID] else {
            throw DemuxerError.unknownTrack(sample.trackID)
        }

        // Create block buffer from sample data
        var blockBuffer: CMBlockBuffer?
        let dataCount = sample.data.count

        var status = sample.data.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -12700 }
            var localBlockBuffer: CMBlockBuffer?
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &localBlockBuffer
            )
            guard status == noErr, let buffer = localBlockBuffer else { return status }

            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataCount
            )
            blockBuffer = buffer
            return replaceStatus
        }

        guard status == noErr, let block = blockBuffer else {
            throw DemuxerError.sampleBufferCreationFailed(status)
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: sample.duration,
            presentationTimeStamp: sample.pts,
            decodeTimeStamp: sample.dts
        )
        var sampleSize = dataCount

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: trackInfo.formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw DemuxerError.sampleBufferCreationFailed(status)
        }

        // Mark keyframes for video
        if sample.isVideo {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
            if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                if !sample.isKeyframe {
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                }
            }
        }

        return buffer
    }

    // MARK: - Private: Box Parsing

    private struct BoxInfo {
        let type: String
        let offset: Int        // Start of the box (including header)
        let size: Int          // Total box size
        let headerSize: Int    // 8 or 16 bytes
        var contentOffset: Int { offset + headerSize }
        var contentLength: Int { size - headerSize }
    }

    private func parseBoxes(data: Data, offset: Int, length: Int) -> [BoxInfo] {
        var boxes: [BoxInfo] = []
        var pos = offset
        let end = offset + length

        while pos + 8 <= end {
            let boxSize = Int(data.readUInt32BE(at: pos))
            let boxType = data.readFourCC(at: pos + 4)

            guard boxSize >= 8 else { break }

            let headerSize: Int
            let actualSize: Int

            if boxSize == 1 {
                // 64-bit extended size
                guard pos + 16 <= end else { break }
                actualSize = Int(data.readUInt64BE(at: pos + 8))
                headerSize = 16
            } else {
                actualSize = boxSize
                headerSize = 8
            }

            guard actualSize > 0, pos + actualSize <= end else { break }

            boxes.append(BoxInfo(type: boxType, offset: pos, size: actualSize, headerSize: headerSize))
            pos += actualSize
        }

        return boxes
    }

    // MARK: - Private: Track Parsing

    private func parseTrak(data: Data, box: BoxInfo, forceDVH1: Bool) throws -> DemuxedTrackInfo? {
        let children = parseBoxes(data: data, offset: box.contentOffset, length: box.contentLength)

        // Parse tkhd for track ID and dimensions
        guard let tkhd = children.first(where: { $0.type == "tkhd" }) else { return nil }
        let tkhdData = parseTkhd(data: data, box: tkhd)

        // Find mdia
        guard let mdia = children.first(where: { $0.type == "mdia" }) else { return nil }
        let mdiaChildren = parseBoxes(data: data, offset: mdia.contentOffset, length: mdia.contentLength)

        // Parse mdhd for timescale
        guard let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) else { return nil }
        let timescale = parseMdhd(data: data, box: mdhd)

        // Parse hdlr for handler type
        guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else { return nil }
        let handlerType = parseHdlr(data: data, box: hdlr)

        let isVideo = handlerType == "vide"
        let isAudio = handlerType == "soun"
        guard isVideo || isAudio else { return nil }

        // Find minf -> stbl -> stsd
        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }) else { return nil }
        let minfChildren = parseBoxes(data: data, offset: minf.contentOffset, length: minf.contentLength)

        guard let stbl = minfChildren.first(where: { $0.type == "stbl" }) else { return nil }
        let stblChildren = parseBoxes(data: data, offset: stbl.contentOffset, length: stbl.contentLength)

        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }) else { return nil }

        // Parse stsd to get format description
        let formatDescription: CMFormatDescription

        if isVideo {
            formatDescription = try parseVideoSampleEntry(
                data: data, stsd: stsd,
                width: tkhdData.width, height: tkhdData.height,
                forceDVH1: forceDVH1
            )
            if forceDVH1 {
                hasDVFormatDescription = true
            }
            videoResolution = "\(tkhdData.width)x\(tkhdData.height)"
        } else {
            formatDescription = try parseAudioSampleEntry(data: data, stsd: stsd, timescale: timescale)
        }

        return DemuxedTrackInfo(
            trackID: tkhdData.trackID,
            isVideo: isVideo,
            timescale: timescale,
            width: tkhdData.width,
            height: tkhdData.height,
            formatDescription: formatDescription
        )
    }

    private struct TkhdData {
        let trackID: UInt32
        let width: UInt32
        let height: UInt32
    }

    private func parseTkhd(data: Data, box: BoxInfo) -> TkhdData {
        let offset = box.contentOffset
        let version = data[offset]

        let trackID: UInt32
        let width: UInt32
        let height: UInt32

        if version == 0 {
            // Version 0: 4-byte fields
            trackID = data.readUInt32BE(at: offset + 4 + 8) // skip version+flags(4) + creation_time(4) + modification_time(4) -> track_id at +12
            // width/height are at offset + 76 (fixed-point 16.16)
            width = data.readUInt32BE(at: offset + 4 + 72) >> 16
            height = data.readUInt32BE(at: offset + 4 + 76) >> 16
        } else {
            // Version 1: 8-byte time fields
            trackID = data.readUInt32BE(at: offset + 4 + 16) // skip version+flags(4) + creation_time(8) + modification_time(8) -> track_id at +20
            width = data.readUInt32BE(at: offset + 4 + 84) >> 16
            height = data.readUInt32BE(at: offset + 4 + 88) >> 16
        }

        return TkhdData(trackID: trackID, width: width, height: height)
    }

    private func parseMdhd(data: Data, box: BoxInfo) -> UInt32 {
        let offset = box.contentOffset
        let version = data[offset]

        if version == 0 {
            return data.readUInt32BE(at: offset + 4 + 8) // skip version+flags(4) + creation_time(4) + modification_time(4)
        } else {
            return data.readUInt32BE(at: offset + 4 + 16) // skip version+flags(4) + creation_time(8) + modification_time(8)
        }
    }

    private func parseHdlr(data: Data, box: BoxInfo) -> String {
        let offset = box.contentOffset
        // version+flags(4) + pre_defined(4) + handler_type(4)
        return data.readFourCC(at: offset + 8)
    }

    // MARK: - Private: Video Sample Entry

    private func parseVideoSampleEntry(data: Data, stsd: BoxInfo, width: UInt32, height: UInt32, forceDVH1: Bool) throws -> CMFormatDescription {
        // stsd: version+flags(4) + entry_count(4) + entries
        let entryOffset = stsd.contentOffset + 8
        let entryEnd = stsd.offset + stsd.size

        guard entryOffset + 8 <= entryEnd else {
            throw DemuxerError.invalidBox("stsd too short for entry")
        }

        // Parse the sample entry box
        let entrySize = Int(data.readUInt32BE(at: entryOffset))
        let entryType = data.readFourCC(at: entryOffset + 4)
        videoCodecType = entryType

        // Video sample entry fixed header = 86 bytes from entry start
        let configOffset = entryOffset + 86
        let innerLength = entryOffset + entrySize - configOffset

        // Find hvcC box within sample entry
        let innerBoxes = parseBoxes(data: data, offset: configOffset, length: innerLength)
        print("🎬 [Demuxer] Video codec: \(entryType), config boxes: \(innerBoxes.map { $0.type }.joined(separator: ", "))")
        guard let hvcC = innerBoxes.first(where: { $0.type == "hvcC" }) else {
            let error = DemuxerError.missingBox("hvcC in video sample entry (\(entryType))")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_demuxer", key: "component")
                scope.setTag(value: "missing_hvcc", key: "error_type")
                scope.setTag(value: entryType, key: "video_codec")
                scope.setExtra(value: "\(width)x\(height)", key: "video_resolution")
                scope.setExtra(value: innerBoxes.map { $0.type }.joined(separator: ", "), key: "inner_boxes")
            }
            throw error
        }

        let hvcCData = data.subdata(in: hvcC.contentOffset ..< (hvcC.offset + hvcC.size))

        if forceDVH1 {
            return try createDVFormatDescription(from: hvcCData, width: width, height: height)
        } else {
            return try createHEVCFormatDescription(from: hvcCData, width: width, height: height)
        }
    }

    /// Create a CMFormatDescription with dvh1 codec type for Dolby Vision decode.
    /// This is the core bet: if VideoToolbox accepts dvh1 via the sample buffer path,
    /// the hardware DV decoder activates.
    private func createDVFormatDescription(from hvcCData: Data, width: UInt32, height: UInt32) throws -> CMFormatDescription {
        // dvh1 FourCC as UInt32: 0x64766831
        let dvh1CodecType: CMVideoCodecType = 0x64766831

        let extensions: [CFString: Any] = [
            // Include hvcC as the decoder configuration record
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "hvcC": hvcCData as CFData
            ],
            // BT.2020 color primaries (required for DV/HDR)
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            // PQ transfer function (required for DV/HDR)
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            // BT.2020 non-constant luminance
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]

        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: dvh1CodecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            let error = DemuxerError.formatDescriptionCreationFailed(status)
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_demuxer", key: "component")
                scope.setTag(value: "dvh1_format_creation", key: "error_type")
                scope.setExtra(value: "\(width)x\(height)", key: "video_resolution")
                scope.setExtra(value: Int(status), key: "os_status")
                scope.setExtra(value: hvcCData.count, key: "hvcc_size")
            }
            throw error
        }

        print("🎬 [FMP4Demuxer] Created dvh1 format description: \(width)x\(height)")
        return desc
    }

    /// Fallback: create standard HEVC format description
    private func createHEVCFormatDescription(from hvcCData: Data, width: UInt32, height: UInt32) throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "hvcC": hvcCData as CFData
            ]
        ]

        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw DemuxerError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    // MARK: - Private: Audio Sample Entry

    private func parseAudioSampleEntry(data: Data, stsd: BoxInfo, timescale: UInt32) throws -> CMFormatDescription {
        let entryOffset = stsd.contentOffset + 8
        let entryEnd = stsd.offset + stsd.size

        guard entryOffset + 8 <= entryEnd else {
            throw DemuxerError.invalidBox("stsd too short for audio entry")
        }

        let entrySize = Int(data.readUInt32BE(at: entryOffset))
        let entryType = data.readFourCC(at: entryOffset + 4)
        audioCodecType = entryType

        // Audio sample entry header = 28 bytes after box header
        let audioHeaderOffset = entryOffset + 8
        let channelCount = data.readUInt16BE(at: audioHeaderOffset + 16)
        let sampleRate = data.readUInt32BE(at: audioHeaderOffset + 24) >> 16
        print("🎬 [Demuxer] Audio codec: \(entryType), channels=\(channelCount), sampleRate=\(sampleRate)")

        let configOffset = entryOffset + 36
        let innerBoxes = parseBoxes(data: data, offset: configOffset, length: entryOffset + entrySize - configOffset)

        // Create format description based on codec type
        switch entryType {
        case "mp4a":
            // AAC - look for esds box
            if let esds = innerBoxes.first(where: { $0.type == "esds" }) {
                return try createAACFormatDescription(data: data, esds: esds, channelCount: channelCount, sampleRate: sampleRate)
            }
            // Fallback: create basic AAC format description
            return try createBasicAudioFormatDescription(
                codecType: kAudioFormatMPEG4AAC,
                channelCount: UInt32(channelCount),
                sampleRate: Float64(sampleRate > 0 ? sampleRate : timescale)
            )

        case "ac-3":
            // AC3 - look for dac3 box
            let configData = innerBoxes.first(where: { $0.type == "dac3" })
            return try createAC3FormatDescription(
                data: configData != nil ? data : nil,
                configBox: configData,
                channelCount: channelCount,
                sampleRate: sampleRate > 0 ? sampleRate : timescale
            )

        case "ec-3":
            // EAC3 - look for dec3 box
            let configData = innerBoxes.first(where: { $0.type == "dec3" })
            return try createEAC3FormatDescription(
                data: configData != nil ? data : nil,
                configBox: configData,
                channelCount: channelCount,
                sampleRate: sampleRate > 0 ? sampleRate : timescale
            )

        default:
            // Try generic approach
            return try createBasicAudioFormatDescription(
                codecType: kAudioFormatMPEG4AAC,
                channelCount: UInt32(channelCount),
                sampleRate: Float64(sampleRate > 0 ? sampleRate : timescale)
            )
        }
    }

    private func createAACFormatDescription(data: Data, esds: BoxInfo, channelCount: UInt16, sampleRate: UInt32) throws -> CMFormatDescription {
        // Parse esds to extract AudioSpecificConfig
        // esds: version+flags(4) + ES_Descriptor
        let esdsContent = esds.contentOffset + 4 // skip version+flags
        let esdsEnd = esds.offset + esds.size

        // Find the AudioSpecificConfig (DecoderSpecificInfo) within esds
        // Walk the descriptor tags to find tag 0x05 (DecoderSpecificInfo)
        var audioSpecificConfig: Data?
        var pos = esdsContent

        while pos < esdsEnd {
            guard pos < esdsEnd else { break }
            let tag = data[pos]
            pos += 1

            // Parse variable-length size
            var size = 0
            for _ in 0..<4 {
                guard pos < esdsEnd else { break }
                let b = Int(data[pos])
                pos += 1
                size = (size << 7) | (b & 0x7F)
                if b & 0x80 == 0 { break }
            }

            if tag == 0x05 {
                // DecoderSpecificInfo - this is AudioSpecificConfig
                let configEnd = min(pos + size, esdsEnd)
                audioSpecificConfig = data.subdata(in: pos ..< configEnd)
                break
            } else if tag == 0x03 || tag == 0x04 {
                // ES_Descriptor (0x03) or DecoderConfigDescriptor (0x04)
                // Skip some fixed fields and continue parsing sub-descriptors
                if tag == 0x03 {
                    pos += 3 // ES_ID(2) + flags(1)
                } else if tag == 0x04 {
                    pos += 13 // objectTypeIndication(1) + streamType(1) + bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4)
                }
                continue
            } else {
                pos += size
            }
        }

        // Parse the real channel count and sample rate from AudioSpecificConfig.
        // The mp4a box header often lies (reports 2 channels for 7.1 AAC).
        // AudioSpecificConfig layout (bit-level):
        //   5 bits: audioObjectType (if 31, then 6 more bits)
        //   4 bits: samplingFrequencyIndex (if 15, then 24 bits explicit frequency)
        //   4 bits: channelConfiguration
        //   If channelConfig==0, a Program Config Element (PCE) follows with the real layout.
        var effectiveChannels = UInt32(channelCount)
        var effectiveSampleRate = sampleRate

        if let asc = audioSpecificConfig, asc.count >= 2 {
            let reader = BitReader(data: asc)

            // audioObjectType: 5 bits (if 31, then 5 + 6 more bits)
            var aot = reader.readBits(5)
            if aot == 31 {
                aot = 32 + reader.readBits(6)
            }

            // samplingFrequencyIndex: 4 bits
            let freqIdx = reader.readBits(4)
            let aacSampleRates: [UInt32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
            if freqIdx < aacSampleRates.count {
                effectiveSampleRate = aacSampleRates[Int(freqIdx)]
            } else if freqIdx == 0xF {
                // 24-bit explicit sampling frequency
                let explicitFreq = reader.readBits(24)
                effectiveSampleRate = explicitFreq
            }

            // channelConfiguration: 4 bits
            let channelConfig = reader.readBits(4)

            // Map channelConfiguration to channel count
            // 0=defined by PCE, 1=mono, 2=stereo, 3=3ch, 4=4ch, 5=5ch, 6=5.1(6ch), 7=7.1(8ch)
            let channelMap: [UInt32: UInt32] = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8]

            if channelConfig == 0 {
                // channelConfig=0: Parse Program Config Element (PCE) to get real channel count.
                // PCE follows the GASpecificConfig in the ASC.
                // GASpecificConfig: frameLengthFlag(1 bit) + dependsOnCoreCoder(1 bit) + extensionFlag(1 bit)
                _ = reader.readBits(1) // frameLengthFlag
                let dependsOnCoreCoder = reader.readBits(1)
                if dependsOnCoreCoder == 1 {
                    _ = reader.readBits(14) // coreCoderDelay
                }
                _ = reader.readBits(1) // extensionFlag

                // Now parse the PCE itself
                // PCE: element_instance_tag(4) + object_type(2) + sampling_frequency_index(4)
                //      + num_front_channel_elements(4) + num_side_channel_elements(4)
                //      + num_back_channel_elements(4) + num_lfe_channel_elements(2)
                //      + num_assoc_data_elements(3) + num_valid_cc_elements(4)
                //      + mono_mixdown_present(1) [+ mono_mixdown_element_number(4)]
                //      + stereo_mixdown_present(1) [+ stereo_mixdown_element_number(4)]
                //      + matrix_mixdown_idx_present(1) [+ matrix_mixdown_idx(2) + pseudo_surround_enable(1)]
                //      + front_element[]: element_is_cpe(1) + element_tag_select(4)
                //      + side_element[]: element_is_cpe(1) + element_tag_select(4)
                //      + back_element[]: element_is_cpe(1) + element_tag_select(4)
                //      + lfe_element[]: element_tag_select(4)
                _ = reader.readBits(4) // element_instance_tag
                _ = reader.readBits(2) // object_type
                _ = reader.readBits(4) // sampling_frequency_index
                let numFront = reader.readBits(4)
                let numSide = reader.readBits(4)
                let numBack = reader.readBits(4)
                let numLFE = reader.readBits(2)
                _ = reader.readBits(3) // num_assoc_data_elements
                _ = reader.readBits(4) // num_valid_cc_elements

                let monoMixdown = reader.readBits(1)
                if monoMixdown == 1 { _ = reader.readBits(4) }
                let stereoMixdown = reader.readBits(1)
                if stereoMixdown == 1 { _ = reader.readBits(4) }
                let matrixMixdown = reader.readBits(1)
                if matrixMixdown == 1 { _ = reader.readBits(3) }

                // Count channels: each element is either SCE (1ch) or CPE (2ch)
                var totalChannels: UInt32 = 0
                for _ in 0..<numFront {
                    let isCPE = reader.readBits(1) // element_is_cpe
                    _ = reader.readBits(4) // element_tag_select
                    totalChannels += (isCPE == 1) ? 2 : 1
                }
                for _ in 0..<numSide {
                    let isCPE = reader.readBits(1)
                    _ = reader.readBits(4)
                    totalChannels += (isCPE == 1) ? 2 : 1
                }
                for _ in 0..<numBack {
                    let isCPE = reader.readBits(1)
                    _ = reader.readBits(4)
                    totalChannels += (isCPE == 1) ? 2 : 1
                }
                for _ in 0..<numLFE {
                    _ = reader.readBits(4) // lfe_element_tag_select
                    totalChannels += 1
                }

                if totalChannels > 0 {
                    effectiveChannels = totalChannels
                }
            } else if let mapped = channelMap[channelConfig] {
                effectiveChannels = mapped
            }

            if effectiveChannels != UInt32(channelCount) {
                print("🎬 [Demuxer] ⚠️ mp4a header said \(channelCount) channels, ASC says \(effectiveChannels) — using ASC value")
            }
        }

        // Create ASBD (AudioStreamBasicDescription)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(effectiveSampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: effectiveChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?

        if let asc = audioSpecificConfig {
            let status = asc.withUnsafeBytes { ascBuffer -> OSStatus in
                guard let ascPtr = ascBuffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                return CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: ascBuffer.count,
                    magicCookie: ascPtr,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }

            if status == noErr, let desc = formatDescription {
                return desc
            }
            print("🎬 [Demuxer] ⚠️ AAC format description with ASC failed: \(status)")
        }

        // Fallback without magic cookie
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw DemuxerError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    private func createAC3FormatDescription(data: Data?, configBox: BoxInfo?, channelCount: UInt16, sampleRate: UInt32) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1536,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?

        // Include dac3 box content as magic cookie if available
        if let data = data, let configBox = configBox {
            let cookieData = data.subdata(in: configBox.contentOffset ..< (configBox.offset + configBox.size))
            let status = cookieData.withUnsafeBytes { cookieBuffer -> OSStatus in
                guard let cookiePtr = cookieBuffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                return CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: cookieBuffer.count,
                    magicCookie: cookiePtr,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }

            if status == noErr, let desc = formatDescription {
                return desc
            }
        }

        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw DemuxerError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    private func createEAC3FormatDescription(data: Data?, configBox: BoxInfo?, channelCount: UInt16, sampleRate: UInt32) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatEnhancedAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1536,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?

        if let data = data, let configBox = configBox {
            let cookieData = data.subdata(in: configBox.contentOffset ..< (configBox.offset + configBox.size))
            let status = cookieData.withUnsafeBytes { cookieBuffer -> OSStatus in
                guard let cookiePtr = cookieBuffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                return CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: cookieBuffer.count,
                    magicCookie: cookiePtr,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }

            if status == noErr, let desc = formatDescription {
                return desc
            }
        }

        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw DemuxerError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    private func createBasicAudioFormatDescription(codecType: AudioFormatID, channelCount: UInt32, sampleRate: Float64) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: codecType,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw DemuxerError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    // MARK: - Private: Fragment Parsing (moof + mdat)

    private func parseFragment(data: Data, moof: BoxInfo, mdat: BoxInfo) throws -> [DemuxedSample] {
        let moofChildren = parseBoxes(data: data, offset: moof.contentOffset, length: moof.contentLength)

        var samples: [DemuxedSample] = []

        for traf in moofChildren where traf.type == "traf" {
            let trafChildren = parseBoxes(data: data, offset: traf.contentOffset, length: traf.contentLength)

            // Parse tfhd for track ID and defaults
            guard let tfhd = trafChildren.first(where: { $0.type == "tfhd" }) else { continue }
            let tfhdInfo = parseTfhd(data: data, box: tfhd)

            // Parse tfdt for base decode time
            let tfdt = trafChildren.first(where: { $0.type == "tfdt" })
            let baseDecodeTime = tfdt.map { parseTfdt(data: data, box: $0) } ?? 0

            // Get track info
            guard let trackInfo = tracks[tfhdInfo.trackID] else { continue }
            let timescale = trackInfo.timescale

            // Determine base data offset per ISO 14496-12:
            // - If base_data_offset is present in tfhd, use it (file-level offset, but segment-relative here)
            // - Otherwise, default is start of moof box
            let baseDataOffset: Int
            if let bdo = tfhdInfo.baseDataOffset {
                baseDataOffset = Int(bdo)
            } else {
                baseDataOffset = moof.offset
            }

            // Parse trun entries
            for trun in trafChildren where trun.type == "trun" {
                let trunSamples = parseTrun(
                    data: data, box: trun,
                    trackInfo: tfhdInfo,
                    baseDecodeTime: baseDecodeTime,
                    baseDataOffset: baseDataOffset,
                    timescale: timescale,
                    isVideo: trackInfo.isVideo
                )
                samples.append(contentsOf: trunSamples)
            }
        }

        return samples
    }

    private struct TfhdInfo {
        let trackID: UInt32
        let defaultSampleDuration: UInt32
        let defaultSampleSize: UInt32
        let defaultSampleFlags: UInt32
        let baseDataOffset: UInt64?
    }

    private func parseTfhd(data: Data, box: BoxInfo) -> TfhdInfo {
        let offset = box.contentOffset
        let flags = (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        let trackID = data.readUInt32BE(at: offset + 4)

        var pos = offset + 8

        var baseDataOffset: UInt64?
        if flags & 0x000001 != 0 {
            baseDataOffset = data.readUInt64BE(at: pos)
            pos += 8
        }

        // sample_description_index
        if flags & 0x000002 != 0 { pos += 4 }

        var defaultDuration: UInt32 = 0
        if flags & 0x000008 != 0 {
            defaultDuration = data.readUInt32BE(at: pos)
            pos += 4
        }

        var defaultSize: UInt32 = 0
        if flags & 0x000010 != 0 {
            defaultSize = data.readUInt32BE(at: pos)
            pos += 4
        }

        var defaultFlags: UInt32 = 0
        if flags & 0x000020 != 0 {
            defaultFlags = data.readUInt32BE(at: pos)
            pos += 4
        }

        return TfhdInfo(
            trackID: trackID,
            defaultSampleDuration: defaultDuration,
            defaultSampleSize: defaultSize,
            defaultSampleFlags: defaultFlags,
            baseDataOffset: baseDataOffset
        )
    }

    private func parseTfdt(data: Data, box: BoxInfo) -> UInt64 {
        let offset = box.contentOffset
        let version = data[offset]

        if version == 0 {
            return UInt64(data.readUInt32BE(at: offset + 4))
        } else {
            return data.readUInt64BE(at: offset + 4)
        }
    }

    private func parseTrun(data: Data, box: BoxInfo, trackInfo: TfhdInfo, baseDecodeTime: UInt64,
                           baseDataOffset: Int, timescale: UInt32, isVideo: Bool) -> [DemuxedSample] {
        let offset = box.contentOffset
        let flags = (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        let sampleCount = data.readUInt32BE(at: offset + 4)

        var pos = offset + 8

        // Data offset (relative to moof start or base data offset)
        var dataOffset: Int32 = 0
        if flags & 0x000001 != 0 {
            dataOffset = Int32(bitPattern: data.readUInt32BE(at: pos))
            pos += 4
        }

        // First sample flags
        var firstSampleFlags: UInt32?
        if flags & 0x000004 != 0 {
            firstSampleFlags = data.readUInt32BE(at: pos)
            pos += 4
        }

        let hasDuration = flags & 0x000100 != 0
        let hasSize = flags & 0x000200 != 0
        let hasFlags = flags & 0x000400 != 0
        let hasCTSOffset = flags & 0x000800 != 0

        var samples: [DemuxedSample] = []
        var currentTime = baseDecodeTime
        var currentOffset = baseDataOffset + Int(dataOffset)

        for i in 0 ..< Int(sampleCount) {
            let duration: UInt32
            if hasDuration {
                duration = data.readUInt32BE(at: pos)
                pos += 4
            } else {
                duration = trackInfo.defaultSampleDuration
            }

            let size: UInt32
            if hasSize {
                size = data.readUInt32BE(at: pos)
                pos += 4
            } else {
                size = trackInfo.defaultSampleSize
            }

            let sampleFlags: UInt32
            if hasFlags {
                sampleFlags = data.readUInt32BE(at: pos)
                pos += 4
            } else if i == 0, let firstFlags = firstSampleFlags {
                sampleFlags = firstFlags
            } else {
                sampleFlags = trackInfo.defaultSampleFlags
            }

            let ctsOffset: Int32
            if hasCTSOffset {
                ctsOffset = Int32(bitPattern: data.readUInt32BE(at: pos))
                pos += 4
            } else {
                ctsOffset = 0
            }

            // Extract sample data
            let sampleEnd = currentOffset + Int(size)
            guard sampleEnd <= data.count else {
                print("🎬 [FMP4Demuxer] Warning: sample extends beyond data bounds (\(sampleEnd) > \(data.count))")
                break
            }
            let sampleData = data.subdata(in: currentOffset ..< sampleEnd)

            // Calculate timestamps
            let dts = CMTime(value: CMTimeValue(currentTime), timescale: CMTimeScale(timescale))
            let pts = CMTime(value: CMTimeValue(Int64(currentTime) + Int64(ctsOffset)), timescale: CMTimeScale(timescale))
            let sampleDuration = CMTime(value: CMTimeValue(duration), timescale: CMTimeScale(timescale))

            // Determine if keyframe: bit 24 (0x02000000) of sample_flags indicates "sample_is_non_sync_sample"
            let isNonSync = (sampleFlags & 0x00010000) != 0
            let isKeyframe = !isNonSync

            samples.append(DemuxedSample(
                trackID: trackInfo.trackID,
                data: sampleData,
                pts: pts,
                dts: dts,
                duration: sampleDuration,
                isKeyframe: isKeyframe,
                isVideo: isVideo
            ))

            currentTime += UInt64(duration)
            currentOffset += Int(size)
        }

        return samples
    }
}

// MARK: - Errors

enum DemuxerError: Error, CustomStringConvertible {
    case missingBox(String)
    case invalidBox(String)
    case noTracksFound
    case unknownTrack(UInt32)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case invalidData(String)

    var description: String {
        switch self {
        case .missingBox(let name): return "Missing required box: \(name)"
        case .invalidBox(let msg): return "Invalid box: \(msg)"
        case .noTracksFound: return "No tracks found in init segment"
        case .unknownTrack(let id): return "Unknown track ID: \(id)"
        case .formatDescriptionCreationFailed(let status): return "Format description creation failed: \(status)"
        case .sampleBufferCreationFailed(let status): return "Sample buffer creation failed: \(status)"
        case .invalidData(let msg): return "Invalid data: \(msg)"
        }
    }
}

// MARK: - Bit Reader for AAC AudioSpecificConfig parsing

/// Reads individual bits from a Data buffer, MSB first.
private class BitReader {
    private let data: Data
    private var byteOffset = 0
    private var bitOffset = 0  // 0-7, within current byte

    init(data: Data) {
        self.data = data
    }

    /// Read `count` bits (1-32) and return as UInt32. MSB first.
    func readBits(_ count: Int) -> UInt32 {
        var result: UInt32 = 0
        var remaining = count
        while remaining > 0 {
            guard byteOffset < data.count else { return result }
            let byte = UInt32(data[byteOffset])
            let bitsAvailable = 8 - bitOffset
            let bitsToRead = min(remaining, bitsAvailable)

            // Extract bits from current byte
            let shift = bitsAvailable - bitsToRead
            let mask: UInt32 = ((1 << bitsToRead) - 1)
            let bits = (byte >> shift) & mask

            result = (result << bitsToRead) | bits
            remaining -= bitsToRead
            bitOffset += bitsToRead
            if bitOffset >= 8 {
                bitOffset = 0
                byteOffset += 1
            }
        }
        return result
    }
}

// MARK: - Data Extensions for Binary Reading

extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt16.self).bigEndian
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.advanced(by: offset)
            return ptr.loadUnaligned(as: UInt64.self).bigEndian
        }
    }

    func readFourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "????" }
        let bytes = self[offset ..< offset + 4]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}
