//
//  FFmpegDemuxer.swift
//  Rivulet
//
//  Swift wrapper around libavformat for demuxing MKV, MP4, and other container formats.
//  Extracts compressed video/audio packets and creates CMFormatDescriptions from codec
//  extradata (VPS/SPS/PPS for HEVC, SPS/PPS for H.264, AudioSpecificConfig for AAC, etc.).
//
//  This is a demuxer only — no decoding. VideoToolbox handles decoding via CMSampleBuffers.
//
//  When FFmpeg libraries are not available, provides a stub that throws .notAvailable,
//  causing ContentRouter to always route through HLS instead.
//

import Foundation
import AVFoundation
import CoreMedia
import Sentry

// MARK: - Track Info

/// Metadata about a media track discovered by the demuxer.
struct FFmpegTrackInfo: Sendable {
    let streamIndex: Int32
    let trackType: TrackType
    let codecId: UInt32
    let codecName: String
    let language: String?
    let title: String?
    let isDefault: Bool

    // Video-specific
    let width: Int32
    let height: Int32
    let bitDepth: Int32

    // Audio-specific
    let sampleRate: Int32
    let channels: Int32
    let channelLayout: String?

    enum TrackType: Sendable {
        case video
        case audio
        case subtitle
    }
}

// MARK: - Demuxed Packet

/// A compressed packet extracted from the container, ready for CMSampleBuffer creation.
struct DemuxedPacket: Sendable {
    let streamIndex: Int32
    let trackType: FFmpegTrackInfo.TrackType
    let data: Data
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let timebase: CMTime
    let isKeyframe: Bool

    /// PTS as CMTime
    var cmPTS: CMTime {
        if pts == Int64.min { return .invalid }
        guard let scaledValue = scaledTimeValue(for: pts) else { return .invalid }
        return CMTime(value: scaledValue, timescale: timebase.timescale)
    }

    /// DTS as CMTime
    var cmDTS: CMTime {
        if dts == Int64.min { return .invalid }
        guard let scaledValue = scaledTimeValue(for: dts) else { return .invalid }
        return CMTime(value: scaledValue, timescale: timebase.timescale)
    }

    /// Duration as CMTime
    var cmDuration: CMTime {
        if duration <= 0 { return .invalid }
        guard let scaledValue = scaledTimeValue(for: duration) else { return .invalid }
        return CMTime(value: scaledValue, timescale: timebase.timescale)
    }

    /// PTS in seconds
    var ptsSeconds: TimeInterval {
        if pts == Int64.min { return 0 }
        return Double(pts) * Double(timebase.value) / Double(timebase.timescale)
    }

    private func scaledTimeValue(for rawValue: Int64) -> Int64? {
        guard timebase.timescale != 0 else { return nil }
        let numerator = timebase.value
        if numerator == 0 { return nil }
        if numerator == 1 { return rawValue }
        let (scaled, overflow) = rawValue.multipliedReportingOverflow(by: numerator)
        return overflow ? nil : scaled
    }
}

// MARK: - FFmpegError

enum FFmpegError: Error, Sendable {
    case alreadyOpen
    case allocationFailed
    case openFailed(averror: Int32)
    case streamInfoFailed(averror: Int32)
    case notOpen
    case readFailed(averror: Int32)
    case seekFailed(averror: Int32)
    case noCodecParameters
    case noExtradata
    case unsupportedCodec(String)
    case formatDescriptionFailed(status: OSStatus)
    case sampleBufferCreationFailed(status: OSStatus)
    case invalidStream
    case notAvailable  // FFmpeg libraries not linked

    var localizedDescription: String {
        switch self {
        case .alreadyOpen: return "Demuxer is already open"
        case .allocationFailed: return "Failed to allocate FFmpeg context"
        case .openFailed(let err): return "Failed to open input (averror: \(err))"
        case .streamInfoFailed(let err): return "Failed to find stream info (averror: \(err))"
        case .notOpen: return "Demuxer is not open"
        case .readFailed(let err): return "Failed to read packet (averror: \(err))"
        case .seekFailed(let err): return "Seek failed (averror: \(err))"
        case .noCodecParameters: return "No codec parameters available"
        case .noExtradata: return "No extradata (parameter sets) available"
        case .unsupportedCodec(let codec): return "Unsupported codec: \(codec)"
        case .formatDescriptionFailed(let status): return "CMFormatDescription creation failed (status: \(status))"
        case .sampleBufferCreationFailed(let status): return "CMSampleBuffer creation failed (status: \(status))"
        case .invalidStream: return "Invalid stream index"
        case .notAvailable: return "FFmpeg libraries not available — direct play disabled"
        }
    }
}

// MARK: - Codec Type Constants

private let kCMVideoCodecType_DolbyVisionHEVC: CMVideoCodecType = 0x64766831

// =============================================================================
// MARK: - FFmpeg Implementation (when libraries are available)
// =============================================================================

// Define RIVULET_FFMPEG in Build Settings > Swift Compiler > Active Compilation Conditions
// when FFmpeg static libraries are properly linked.
#if RIVULET_FFMPEG
import Libavformat
import Libavcodec
import Libavutil

/// Demuxes media containers using libavformat.
final class FFmpegDemuxer: @unchecked Sendable {

    // MARK: - Public State

    private(set) var videoFormatDescription: CMFormatDescription?
    private(set) var audioFormatDescription: CMFormatDescription?

    private(set) var videoTracks: [FFmpegTrackInfo] = []
    private(set) var audioTracks: [FFmpegTrackInfo] = []
    private(set) var subtitleTracks: [FFmpegTrackInfo] = []

    private(set) var duration: TimeInterval = 0

    private(set) var selectedVideoStream: Int32 = -1
    private(set) var selectedAudioStream: Int32 = -1
    private(set) var selectedSubtitleStream: Int32 = -1

    private(set) var hasDolbyVision = false
    private(set) var dvProfile: UInt8?
    private(set) var dvLevel: UInt8?
    private(set) var dvBLCompatID: UInt8?

    /// Whether FFmpeg libraries are linked and available
    static let isAvailable = true

    // MARK: - Private State

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var isOpen = false
    private let lock = NSLock()
    private var hasLoggedADTSStripping = false
    private var hasLoggedAACConfig = false
    private var synthesizedAudioDurationCount = 0
    private var invalidAudioTimestampCount = 0
    private var nonMonotonicAudioTimestampCount = 0
    private var lastAudioPacketPTSSeconds: Double?

    deinit { close() }

    // MARK: - Open

    func open(url: URL, headers: [String: String]? = nil, forceDolbyVision: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isOpen else { throw FFmpegError.alreadyOpen }

        guard let ctx = avformat_alloc_context() else {
            throw FFmpegError.allocationFailed
        }

        var options: OpaquePointer? = nil
        if let headers = headers, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            av_dict_set(&options, "headers", headerString, 0)
            av_dict_set(&options, "reconnect", "1", 0)
            av_dict_set(&options, "reconnect_streamed", "1", 0)
            av_dict_set(&options, "reconnect_delay_max", "5", 0)
        }

        var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
        let ret = avformat_open_input(&mutableCtx, url.absoluteString, nil, &options)
        av_dict_free(&options)

        guard ret >= 0, let openCtx = mutableCtx else {
            throw FFmpegError.openFailed(averror: ret)
        }

        let findRet = avformat_find_stream_info(openCtx, nil)
        guard findRet >= 0 else {
            avformat_close_input(&mutableCtx)
            throw FFmpegError.streamInfoFailed(averror: findRet)
        }

        self.formatContext = openCtx
        self.isOpen = true
        self.hasDolbyVision = false
        self.dvProfile = nil
        self.dvLevel = nil
        self.dvBLCompatID = nil
        self.synthesizedAudioDurationCount = 0
        self.invalidAudioTimestampCount = 0
        self.nonMonotonicAudioTimestampCount = 0
        self.lastAudioPacketPTSSeconds = nil

        if openCtx.pointee.duration > 0 {
            self.duration = Double(openCtx.pointee.duration) / Double(AV_TIME_BASE)
        }

        discoverTracks(in: openCtx)
        selectBestStreams(in: openCtx)

        // Force DV from Plex metadata if FFmpeg didn't detect it
        if forceDolbyVision && !hasDolbyVision {
            hasDolbyVision = true
        }

        if selectedVideoStream >= 0 {
            videoFormatDescription = try? createVideoFormatDescription(
                from: openCtx.pointee.streams[Int(selectedVideoStream)]!.pointee
            )
        }
        if selectedAudioStream >= 0 {
            audioFormatDescription = try? createAudioFormatDescription(
                from: openCtx.pointee.streams[Int(selectedAudioStream)]!.pointee
            )
        }
    }

    // MARK: - Read Packets

    func readPacket() throws -> DemuxedPacket? {
        guard let ctx = formatContext, isOpen else { throw FFmpegError.notOpen }

        var pkt = av_packet_alloc()
        guard let packet = pkt else { throw FFmpegError.allocationFailed }
        defer { av_packet_free(&pkt) }

        while true {
            let ret = av_read_frame(ctx, packet)

            if ret == AVERROR_EOF_VALUE {
                return nil
            }
            guard ret >= 0 else {
                throw FFmpegError.readFailed(averror: ret)
            }

            let streamIndex = packet.pointee.stream_index

            let trackType: FFmpegTrackInfo.TrackType
            if streamIndex == selectedVideoStream {
                trackType = .video
            } else if streamIndex == selectedAudioStream {
                trackType = .audio
            } else if streamIndex == selectedSubtitleStream {
                trackType = .subtitle
            } else {
                av_packet_unref(packet)
                continue
            }

            // Some files expose DV config on packet side data instead of stream side data.
            // Capture it once so load-time logs can report profile/level/BL compatibility.
            if trackType == .video && (dvProfile == nil || dvLevel == nil || dvBLCompatID == nil) {
                if let sideData = av_packet_side_data_get(
                    packet.pointee.side_data,
                    packet.pointee.side_data_elems,
                    AV_PKT_DATA_DOVI_CONF
                ), sideData.pointee.size >= 4 {
                    let configData = Data(bytes: sideData.pointee.data, count: Int(sideData.pointee.size))
                    _ = parseDolbyVisionConfig(configData, source: "packet_side_data")
                }
            }

            guard let packetData = packet.pointee.data else {
                av_packet_unref(packet)
                continue
            }

            let data = Data(bytes: packetData, count: Int(packet.pointee.size))
            let stream = ctx.pointee.streams[Int(streamIndex)]!
            let tb = stream.pointee.time_base
            let tbNum = Int64(tb.num == 0 ? 1 : tb.num)
            let tbDen = Int32(tb.den == 0 ? 1 : tb.den)
            let timebase = CMTime(value: tbNum, timescale: tbDen)
            let isKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0

            let demuxedPacket = DemuxedPacket(
                streamIndex: streamIndex,
                trackType: trackType,
                data: data,
                pts: packet.pointee.pts,
                dts: packet.pointee.dts,
                duration: packet.pointee.duration,
                timebase: timebase,
                isKeyframe: isKeyframe
            )

            av_packet_unref(packet)
            return demuxedPacket
        }
    }

    // MARK: - Seek

    func seek(to time: TimeInterval) throws {
        guard let ctx = formatContext, isOpen else { throw FFmpegError.notOpen }

        let timestamp = Int64(time * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, timestamp, 0)
        guard ret >= 0 else {
            throw FFmpegError.seekFailed(averror: ret)
        }
    }

    // MARK: - Audio Track Selection

    func selectAudioStream(index: Int32) throws {
        guard let ctx = formatContext, isOpen else { throw FFmpegError.notOpen }

        guard index >= 0, index < ctx.pointee.nb_streams,
              ctx.pointee.streams[Int(index)]!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            throw FFmpegError.invalidStream
        }

        // Create format description first — if it fails, don't change the selected stream
        let newFD = try createAudioFormatDescription(
            from: ctx.pointee.streams[Int(index)]!.pointee
        )
        selectedAudioStream = index
        audioFormatDescription = newFD
    }

    /// Select an audio stream for reading without rebuilding the format description.
    /// Use when the caller will handle audio decoding (client-side decode produces its own
    /// PCM sample buffers and doesn't need a CoreAudio format description from the demuxer).
    func selectAudioStreamForClientDecode(index: Int32) throws {
        guard let ctx = formatContext, isOpen else { throw FFmpegError.notOpen }

        guard index >= 0, index < ctx.pointee.nb_streams,
              ctx.pointee.streams[Int(index)]!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            throw FFmpegError.invalidStream
        }

        selectedAudioStream = index
        // Don't update audioFormatDescription — caller is responsible for audio format
    }

    /// Select a subtitle stream to include in readPacket() results.
    /// Pass -1 to disable subtitle reading.
    func selectSubtitleStream(index: Int32) {
        selectedSubtitleStream = index
    }

    // MARK: - Codec Parameters Access

    /// Get raw codec parameters for a specific stream, for use by client-side decoders.
    func codecParameters(forStream index: Int32) -> UnsafePointer<AVCodecParameters>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else { return nil }
        return UnsafePointer(ctx.pointee.streams[Int(index)]!.pointee.codecpar)
    }

    // MARK: - Close

    func close() {
        lock.lock()
        defer { lock.unlock() }

        guard isOpen else { return }
        isOpen = false

        avformat_close_input(&formatContext)
        formatContext = nil
        videoFormatDescription = nil
        audioFormatDescription = nil
        videoTracks = []
        audioTracks = []
        subtitleTracks = []
        selectedVideoStream = -1
        selectedAudioStream = -1
        selectedSubtitleStream = -1
        synthesizedAudioDurationCount = 0
        invalidAudioTimestampCount = 0
        nonMonotonicAudioTimestampCount = 0
        lastAudioPacketPTSSeconds = nil
    }

    // MARK: - Subtitle Extraction

    /// Extract all subtitle cues from a specific subtitle stream.
    /// Opens a separate demuxer instance to avoid disturbing the playback read position.
    /// Returns cues sorted by start time.
    static func extractSubtitles(
        url: URL,
        headers: [String: String]?,
        streamIndex: Int32
    ) throws -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        let demuxer = FFmpegDemuxer()
        try demuxer.open(url: url, headers: headers)
        defer { demuxer.close() }

        guard let ctx = demuxer.formatContext else { throw FFmpegError.notOpen }
        guard streamIndex >= 0, streamIndex < ctx.pointee.nb_streams else {
            throw FFmpegError.invalidStream
        }

        let stream = ctx.pointee.streams[Int(streamIndex)]!
        let tb = stream.pointee.time_base
        let timebaseFactor = Double(tb.num) / Double(tb.den)
        let codecId = stream.pointee.codecpar.pointee.codec_id

        // Determine if this is ASS/SSA (needs dialogue line parsing)
        let isASS = (codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA)

        var cues: [(start: TimeInterval, end: TimeInterval, text: String)] = []

        // Seek to beginning
        avformat_seek_file(ctx, -1, 0, 0, 0, 0)

        var pkt = av_packet_alloc()
        guard let packet = pkt else { throw FFmpegError.allocationFailed }
        defer { av_packet_free(&pkt) }

        while true {
            let ret = av_read_frame(ctx, packet)
            if ret < 0 { break } // EOF or error

            defer { av_packet_unref(packet) }

            guard packet.pointee.stream_index == streamIndex else { continue }
            guard let data = packet.pointee.data, packet.pointee.size > 0 else { continue }

            let text: String
            let rawText = String(cString: data) // Subtitle packets are null-terminated text

            if isASS {
                // ASS dialogue format: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
                // Split on commas and take everything after the 8th comma
                let parts = rawText.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count >= 9 {
                    text = String(parts[8])
                        .replacingOccurrences(of: "\\N", with: "\n")
                        .replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "{\\[^}]*}", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                // SRT/text: packet data is the raw subtitle text
                text = rawText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            guard !text.isEmpty else { continue }

            let startTime = Double(packet.pointee.pts) * timebaseFactor
            let duration = Double(packet.pointee.duration) * timebaseFactor
            let endTime = startTime + duration

            guard startTime >= 0, duration > 0 else { continue }

            cues.append((start: startTime, end: endTime, text: text))
        }

        cues.sort { $0.start < $1.start }
        print("[FFmpegDemuxer] Extracted \(cues.count) subtitle cues from stream \(streamIndex)")
        return cues
    }

    // MARK: - CMSampleBuffer Creation

    func createVideoSampleBuffer(from packet: DemuxedPacket, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        try createSampleBuffer(from: packet, formatDescription: formatDescription, isVideo: true)
    }

    func createAudioSampleBuffer(from packet: DemuxedPacket, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        try createSampleBuffer(from: packet, formatDescription: formatDescription, isVideo: false)
    }

    private func createSampleBuffer(from packet: DemuxedPacket, formatDescription: CMFormatDescription, isVideo: Bool) throws -> CMSampleBuffer {
        var data = packet.data
        if !isVideo {
            data = stripADTSHeaderIfNeeded(from: data)
        }
        var blockBuffer: CMBlockBuffer?

        var status = data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let baseAddress = rawBuf.baseAddress else { return -1 }
            var buffer: CMBlockBuffer?
            let s1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &buffer
            )
            guard s1 == noErr, let buf = buffer else { return s1 }
            let s2 = CMBlockBufferReplaceDataBytes(
                with: baseAddress, blockBuffer: buf,
                offsetIntoDestination: 0, dataLength: data.count
            )
            blockBuffer = buf
            return s2
        }

        guard status == noErr, let block = blockBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }

        let buffer: CMSampleBuffer
        if isVideo {
            var timingInfo = CMSampleTimingInfo(
                duration: packet.cmDuration,
                presentationTimeStamp: packet.cmPTS,
                decodeTimeStamp: packet.cmDTS
            )
            var sampleSize = data.count
            var sampleBuffer: CMSampleBuffer?

            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )

            guard status == noErr, let createdBuffer = sampleBuffer else {
                throw FFmpegError.sampleBufferCreationFailed(status: status)
            }
            buffer = createdBuffer
        } else {
            buffer = try createCompressedAudioSampleBuffer(
                from: packet,
                blockBuffer: block,
                formatDescription: formatDescription,
                payloadSize: data.count
            )
        }

        // Mark sync/non-sync for video
        if isVideo {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                    unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self),
                    unsafeBitCast(packet.isKeyframe ? kCFBooleanFalse : kCFBooleanTrue, to: UnsafeRawPointer.self))
            }
        }

        return buffer
    }

    private func createCompressedAudioSampleBuffer(
        from packet: DemuxedPacket,
        blockBuffer: CMBlockBuffer,
        formatDescription: CMFormatDescription,
        payloadSize: Int
    ) throws -> CMSampleBuffer {
        guard let audioFD = formatDescription as? CMAudioFormatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFD)?.pointee else {
            throw FFmpegError.noCodecParameters
        }

        var duration = packet.cmDuration
        if !duration.isValid || !duration.isNumeric || duration <= .zero {
            let framesPerPacket = Int(asbd.mFramesPerPacket)
            let sampleRate = asbd.mSampleRate
            if framesPerPacket > 0, sampleRate > 0 {
                duration = CMTime(
                    seconds: Double(framesPerPacket) / sampleRate,
                    preferredTimescale: 90_000
                )
                synthesizedAudioDurationCount += 1
                if synthesizedAudioDurationCount <= 5 || synthesizedAudioDurationCount % 100 == 0 {
                    print(
                        "[FFmpegDemuxer] Synthesized audio packet duration (count=\(synthesizedAudioDurationCount)) " +
                        "codec=\(fourCCString(asbd.mFormatID)) fpp=\(framesPerPacket) rate=\(Int(sampleRate))"
                    )
                }
                if synthesizedAudioDurationCount <= 5 || synthesizedAudioDurationCount % 250 == 0 {
                    let breadcrumb = Breadcrumb(level: .info, category: "audio.timestamps")
                    breadcrumb.message = "Synthesized audio packet duration"
                    breadcrumb.data = [
                        "count": synthesizedAudioDurationCount,
                        "codec": fourCCString(asbd.mFormatID),
                        "frames_per_packet": framesPerPacket,
                        "sample_rate": Int(sampleRate)
                    ]
                    SentrySDK.addBreadcrumb(breadcrumb)
                }
            }
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        let fallbackDurationSeconds = (durationSeconds.isFinite && durationSeconds > 0) ? durationSeconds : 0

        let packetPTS = packet.cmPTS
        let fallbackPTS = packet.cmDTS
        var presentationTimeStamp: CMTime = packetPTS.isValid ? packetPTS : fallbackPTS
        if !presentationTimeStamp.isValid || !presentationTimeStamp.isNumeric {
            let synthesizedPTSSeconds = (lastAudioPacketPTSSeconds ?? 0) + fallbackDurationSeconds
            presentationTimeStamp = CMTime(seconds: synthesizedPTSSeconds, preferredTimescale: 90_000)
            invalidAudioTimestampCount += 1
            if invalidAudioTimestampCount <= 5 || invalidAudioTimestampCount % 100 == 0 {
                print(
                    "[FFmpegDemuxer] Audio packet missing valid PTS/DTS " +
                    "(count=\(invalidAudioTimestampCount), synthesized=\(String(format: "%.3f", synthesizedPTSSeconds)))"
                )
            }
            if invalidAudioTimestampCount <= 5 || invalidAudioTimestampCount % 250 == 0 {
                let breadcrumb = Breadcrumb(level: .warning, category: "audio.timestamps")
                breadcrumb.message = "Audio packet missing timestamp"
                breadcrumb.data = [
                    "count": invalidAudioTimestampCount,
                    "sample_rate": Int(asbd.mSampleRate),
                    "frames_per_packet": Int(asbd.mFramesPerPacket),
                    "payload_size": payloadSize,
                    "synthesized_pts": synthesizedPTSSeconds
                ]
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }

        let ptsSeconds = CMTimeGetSeconds(presentationTimeStamp)
        if ptsSeconds.isFinite, let lastPTS = lastAudioPacketPTSSeconds, ptsSeconds + 0.001 < lastPTS {
            nonMonotonicAudioTimestampCount += 1
            if nonMonotonicAudioTimestampCount <= 5 || nonMonotonicAudioTimestampCount % 100 == 0 {
                print(
                    "[FFmpegDemuxer] Non-monotonic audio PTS (count=\(nonMonotonicAudioTimestampCount)) " +
                    "current=\(String(format: "%.3f", ptsSeconds)) last=\(String(format: "%.3f", lastPTS))"
                )
            }
            if nonMonotonicAudioTimestampCount <= 5 || nonMonotonicAudioTimestampCount % 250 == 0 {
                let breadcrumb = Breadcrumb(level: .warning, category: "audio.timestamps")
                breadcrumb.message = "Non-monotonic audio packet timestamp"
                breadcrumb.data = [
                    "count": nonMonotonicAudioTimestampCount,
                    "current_pts": ptsSeconds,
                    "last_pts": lastPTS,
                    "sample_rate": Int(asbd.mSampleRate),
                    "frames_per_packet": Int(asbd.mFramesPerPacket)
                ]
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }
        if ptsSeconds.isFinite {
            lastAudioPacketPTSSeconds = ptsSeconds
        }

        let framesPerPacket = Int(asbd.mFramesPerPacket)

        // Each DemuxedPacket contains exactly one compressed audio packet.
        // sampleCount = 1 because CMAudioSampleBufferCreateReadyWithPacketDescriptions
        // expects the number of *packets*, not PCM frames. The packetDescriptions array
        // must have exactly sampleCount entries — using framesPerPacket (e.g. 1536 for
        // EAC3) would read past the single description and crash.
        let sampleCount = 1

        // For VBR formats (mFramesPerPacket == 0), report the actual frame count
        // so the renderer knows how many PCM frames this packet decodes to.
        let variableFrames: UInt32 = {
            guard framesPerPacket == 0 else { return 0 }  // CBR: implicit from ASBD
            let sampleRate = asbd.mSampleRate
            guard sampleRate > 0 else { return 0 }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return UInt32(max(1, Int((seconds * sampleRate).rounded())))
        }()

        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: variableFrames,
            mDataByteSize: UInt32(payloadSize)
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: audioFD,
            sampleCount: sampleCount,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }
        return buffer
    }

    private func fourCCString(_ fourCC: UInt32) -> String {
        let n = Int(fourCC.bigEndian)
        let scalars = [
            UnicodeScalar((n >> 24) & 255),
            UnicodeScalar((n >> 16) & 255),
            UnicodeScalar((n >> 8) & 255),
            UnicodeScalar(n & 255)
        ]
        let characters = scalars.compactMap { $0.map(Character.init) }
        return String(characters)
    }

    // MARK: - Private: Track Discovery

    private func discoverTracks(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        videoTracks = []; audioTracks = []; subtitleTracks = []

        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }

            let codecId = codecpar.pointee.codec_id
            let codecDesc = avcodec_descriptor_get(codecId)
            let codecName = codecDesc.flatMap { String(cString: $0.pointee.name) } ?? "unknown"
            let language = extractMetadata(from: stream.pointee.metadata, key: "language")
            let title = extractMetadata(from: stream.pointee.metadata, key: "title")
            let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0

            let trackType: FFmpegTrackInfo.TrackType
            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO: trackType = .video
            case AVMEDIA_TYPE_AUDIO: trackType = .audio
            case AVMEDIA_TYPE_SUBTITLE: trackType = .subtitle
            default: continue
            }

            var channelLayout: String? = nil
            if trackType == .audio {
                channelLayout = channelLayoutString(channels: codecpar.pointee.ch_layout.nb_channels)
            }

            let info = FFmpegTrackInfo(
                streamIndex: Int32(i), trackType: trackType,
                codecId: codecId.rawValue, codecName: codecName,
                language: language, title: title, isDefault: isDefault,
                width: codecpar.pointee.width, height: codecpar.pointee.height,
                bitDepth: Int32(codecpar.pointee.bits_per_raw_sample),
                sampleRate: codecpar.pointee.sample_rate,
                channels: codecpar.pointee.ch_layout.nb_channels,
                channelLayout: channelLayout
            )

            switch trackType {
            case .video: videoTracks.append(info)
            case .audio: audioTracks.append(info)
            case .subtitle: subtitleTracks.append(info)
            }
        }
    }

    private func selectBestStreams(in ctx: UnsafeMutablePointer<AVFormatContext>) {
        let bestVideo = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if bestVideo >= 0 { selectedVideoStream = bestVideo }

        let bestAudio = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if bestAudio >= 0 { selectedAudioStream = bestAudio }
    }

    // MARK: - Private: Format Description Creation

    private func createVideoFormatDescription(from stream: AVStream) throws -> CMFormatDescription {
        guard let codecpar = stream.codecpar else { throw FFmpegError.noCodecParameters }

        guard let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else {
            throw FFmpegError.noExtradata
        }

        let extradataData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        let width = Int32(codecpar.pointee.width)
        let height = Int32(codecpar.pointee.height)

        if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            return try createHEVCFormatDescription(hvcCData: extradataData, width: width, height: height, codecpar: codecpar.pointee)
        } else if codecpar.pointee.codec_id == AV_CODEC_ID_H264 {
            return try createH264FormatDescription(avcCData: extradataData, width: width, height: height)
        } else {
            throw FFmpegError.unsupportedCodec(String(cString: avcodec_get_name(codecpar.pointee.codec_id)))
        }
    }

    private func createHEVCFormatDescription(hvcCData: Data, width: Int32, height: Int32, codecpar: AVCodecParameters) throws -> CMFormatDescription {
        let codecType: CMVideoCodecType

        if hasDolbyVision || detectDolbyVisionFromSideData() {
            codecType = kCMVideoCodecType_DolbyVisionHEVC
            hasDolbyVision = true
        } else {
            codecType = kCMVideoCodecType_HEVC
        }

        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "hvcC" as CFString: hvcCData as CFData
            ]
        ]

        if let cp = mapColorPrimaries(codecpar.color_primaries) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = cp
        }
        if let tf = mapTransferCharacteristics(codecpar.color_trc) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = tf
        }
        if let m = mapColorSpace(codecpar.color_space) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = m
        }

        if hasDolbyVision {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }

        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codecType,
            width: width, height: height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc
        )
        guard status == noErr, let result = desc else {
            throw FFmpegError.formatDescriptionFailed(status: status)
        }
        return result
    }

    /// Rebuild the video format description with a dvcC (Dolby Vision Configuration Record)
    /// extension. Call after DV profile conversion to tell VideoToolbox the output DV profile.
    ///
    /// - Parameters:
    ///   - dvProfile: Target DV profile (e.g., 8 for P8.1)
    ///   - blCompatId: Base layer signal compatibility ID (1 = HDR10, 4 = HLG)
    func rebuildFormatDescriptionWithDVCC(dvProfile: UInt8, blCompatId: UInt8) {
        guard let existingFD = videoFormatDescription else { return }

        let width = Int32(CMVideoFormatDescriptionGetDimensions(existingFD).width)
        let height = Int32(CMVideoFormatDescriptionGetDimensions(existingFD).height)
        let codecType = CMFormatDescriptionGetMediaSubType(existingFD)

        // Extract existing extensions
        guard let existingExts = CMFormatDescriptionGetExtensions(existingFD) as? [CFString: Any] else { return }

        // Build dvcC (DOVIDecoderConfigurationRecord) — 24 bytes
        // Layout:
        //   byte 0: dv_version_major (8 bits)
        //   byte 1: dv_version_minor (8 bits)
        //   byte 2: dv_profile (7 bits) | dv_level bit5 (1 bit)
        //   byte 3: dv_level bits4-0 (5 bits) | rpu_present (1) | el_present (1) | bl_present (1)
        //   byte 4: dv_bl_signal_compatibility_id (4 bits) | reserved (4 bits)
        //   bytes 5-7: reserved (24 bits)
        let dvLevel: UInt8 = 6  // Level 6 = 4K@24fps
        let rpuPresent: UInt8 = 1
        let elPresent: UInt8 = 0  // Single-layer after conversion
        let blPresent: UInt8 = 1

        let byte2 = (dvProfile << 1) | ((dvLevel >> 5) & 0x01)
        let byte3 = ((dvLevel & 0x1F) << 3) | (rpuPresent << 2) | (elPresent << 1) | blPresent
        let byte4 = (blCompatId << 4)

        let dvcCData = Data([0x01, 0x00, byte2, byte3, byte4, 0x00, 0x00, 0x00])

        // Merge dvcC into the existing sample description atoms
        var extensions = existingExts
        if var atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [CFString: Any] {
            atoms["dvcC" as CFString] = dvcCData as CFData
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
        }

        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codecType,
            width: width, height: height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc
        )

        if status == noErr, let newDesc = desc {
            videoFormatDescription = newDesc
            print("[FFmpegDemuxer] Rebuilt format description with dvcC: profile=\(dvProfile) level=\(dvLevel) bl_compat=\(blCompatId)")
        } else {
            print("[FFmpegDemuxer] Failed to rebuild format description with dvcC: status=\(status)")
        }
    }

    private func createH264FormatDescription(avcCData: Data, width: Int32, height: Int32) throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                "avcC" as CFString: avcCData as CFData
            ]
        ]
        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: width, height: height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc
        )
        guard status == noErr, let result = desc else {
            throw FFmpegError.formatDescriptionFailed(status: status)
        }
        return result
    }

    private func createAudioFormatDescription(from stream: AVStream) throws -> CMFormatDescription {
        guard let codecpar = stream.codecpar else { throw FFmpegError.noCodecParameters }

        let formatId: AudioFormatID
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_AAC: formatId = kAudioFormatMPEG4AAC
        case AV_CODEC_ID_AC3: formatId = kAudioFormatAC3
        case AV_CODEC_ID_EAC3: formatId = kAudioFormatEnhancedAC3
        case AV_CODEC_ID_FLAC: formatId = kAudioFormatFLAC
        case AV_CODEC_ID_ALAC: formatId = kAudioFormatAppleLossless
        case AV_CODEC_ID_MP3: formatId = kAudioFormatMPEGLayer3
        case AV_CODEC_ID_OPUS: formatId = kAudioFormatOpus
        default: throw FFmpegError.unsupportedCodec(String(cString: avcodec_get_name(codecpar.pointee.codec_id)))
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(codecpar.pointee.sample_rate),
            mFormatID: formatId, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(codecpar.pointee.ch_layout.nb_channels),
            mBitsPerChannel: 0, mReserved: 0
        )

        switch formatId {
        case kAudioFormatMPEG4AAC: asbd.mFramesPerPacket = 1024
        case kAudioFormatAC3, kAudioFormatEnhancedAC3: asbd.mFramesPerPacket = 1536
        case kAudioFormatFLAC: asbd.mFramesPerPacket = 4096
        case kAudioFormatMPEGLayer3: asbd.mFramesPerPacket = 1152
        default: break
        }

        var desc: CMFormatDescription?
        if let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
            let size = Int(codecpar.pointee.extradata_size)
            var cookie = Data(bytes: extradata, count: size)

            // Some sources provide AAC extradata in non-ASC wrappers (e.g. esds blobs).
            // Normalize to AudioSpecificConfig when possible.
            if formatId == kAudioFormatMPEG4AAC {
                let normalizedCookie = normalizeAACMagicCookie(
                    rawCookie: cookie,
                    sampleRate: Int(codecpar.pointee.sample_rate),
                    channels: Int(codecpar.pointee.ch_layout.nb_channels),
                    ffmpegProfile: Int(codecpar.pointee.profile)
                )
                if normalizedCookie != cookie {
                    print("[FFmpegDemuxer] Normalized AAC magic cookie (raw=\(cookie.count)B normalized=\(normalizedCookie.count)B)")
                }
                cookie = normalizedCookie
            }

            if formatId == kAudioFormatMPEG4AAC,
               let parsedConfig = parseAACAudioSpecificConfig(cookie) {
                // Align ASBD with AAC config to avoid silent decoder init mismatches.
                asbd.mFormatFlags = UInt32(parsedConfig.audioObjectType)
                asbd.mSampleRate = parsedConfig.outputSampleRate
                asbd.mChannelsPerFrame = parsedConfig.channelCount
                asbd.mFramesPerPacket = UInt32(parsedConfig.framesPerPacket)
                if !hasLoggedAACConfig {
                    hasLoggedAACConfig = true
                    print(
                        "[FFmpegDemuxer] AAC config: aot=\(parsedConfig.audioObjectType) coreRate=\(Int(parsedConfig.coreSampleRate)) " +
                        "outputRate=\(Int(parsedConfig.outputSampleRate)) channels=\(parsedConfig.channelCount) " +
                        "framesPerPacket=\(parsedConfig.framesPerPacket) cookie=\(cookie.count)B profile=\(codecpar.pointee.profile)"
                    )
                }
            }

            let status = cookie.withUnsafeBytes {
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: 0, layout: nil,
                    magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
                    extensions: nil, formatDescriptionOut: &desc
                )
            }
            guard status == noErr, let result = desc else {
                throw FFmpegError.formatDescriptionFailed(status: status)
            }
            return result
        } else {
            // AAC in some containers may not expose codec extradata through FFmpeg.
            // Build a conservative AudioSpecificConfig so AudioToolbox can initialize.
            if formatId == kAudioFormatMPEG4AAC,
               let asc = synthesizeAACAudioSpecificConfig(
                sampleRate: Int(codecpar.pointee.sample_rate),
                channels: Int(codecpar.pointee.ch_layout.nb_channels),
                ffmpegProfile: Int(codecpar.pointee.profile)
               ) {
                let status = asc.withUnsafeBytes {
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault, asbd: &asbd,
                        layoutSize: 0, layout: nil,
                        magicCookieSize: asc.count, magicCookie: $0.baseAddress,
                        extensions: nil, formatDescriptionOut: &desc
                    )
                }
                if status == noErr, let result = desc {
                    print("[FFmpegDemuxer] Synthesized AAC magic cookie (profile=\(codecpar.pointee.profile), sr=\(codecpar.pointee.sample_rate), ch=\(codecpar.pointee.ch_layout.nb_channels))")
                    return result
                }
            }

            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &desc
            )
            guard status == noErr, let result = desc else {
                throw FFmpegError.formatDescriptionFailed(status: status)
            }
            return result
        }
    }

    private struct AACAudioSpecificConfig {
        let audioObjectType: Int
        let coreSampleRate: Float64
        let outputSampleRate: Float64
        let channelCount: UInt32
        let framesPerPacket: Int
    }

    private final class AACBitReader {
        private let data: Data
        private var bitOffset: Int = 0

        init(data: Data) {
            self.data = data
        }

        func readBits(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            var value = 0
            for _ in 0..<count {
                let byteIndex = bitOffset / 8
                let inByteBitIndex = 7 - (bitOffset % 8)
                guard byteIndex < data.count else { return value }
                let bit = (Int(data[byteIndex]) >> inByteBitIndex) & 0x01
                value = (value << 1) | bit
                bitOffset += 1
            }
            return value
        }
    }

    private func parseAACAudioSpecificConfig(_ data: Data) -> AACAudioSpecificConfig? {
        guard data.count >= 2 else { return nil }

        let sampleRateTable: [Float64] = [
            96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
            16_000, 12_000, 11_025, 8_000, 7_350
        ]

        let channelMap: [Int: UInt32] = [
            1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8
        ]

        let reader = AACBitReader(data: data)

        var audioObjectType = reader.readBits(5)
        if audioObjectType == 31 {
            audioObjectType = 32 + reader.readBits(6)
        }
        guard audioObjectType > 0 else { return nil }

        let samplingFrequencyIndex = reader.readBits(4)
        let coreSampleRate: Float64
        if samplingFrequencyIndex == 0x0F {
            coreSampleRate = Float64(reader.readBits(24))
        } else if samplingFrequencyIndex < sampleRateTable.count {
            coreSampleRate = sampleRateTable[samplingFrequencyIndex]
        } else {
            return nil
        }

        let channelConfig = reader.readBits(4)
        let parsedChannelCount = channelMap[channelConfig] ?? 2

        var outputSampleRate = coreSampleRate
        if audioObjectType == 5 || audioObjectType == 29 {
            let extSamplingFrequencyIndex = reader.readBits(4)
            if extSamplingFrequencyIndex == 0x0F {
                outputSampleRate = Float64(reader.readBits(24))
            } else if extSamplingFrequencyIndex < sampleRateTable.count {
                outputSampleRate = sampleRateTable[extSamplingFrequencyIndex]
            }
        }

        let framesPerPacket = (audioObjectType == 5 || audioObjectType == 29) ? 2048 : 1024

        return AACAudioSpecificConfig(
            audioObjectType: audioObjectType,
            coreSampleRate: coreSampleRate,
            outputSampleRate: outputSampleRate,
            channelCount: parsedChannelCount,
            framesPerPacket: framesPerPacket
        )
    }

    private func normalizeAACMagicCookie(rawCookie: Data, sampleRate: Int, channels: Int, ffmpegProfile: Int) -> Data {
        if looksLikeAACAudioSpecificConfig(rawCookie) {
            return rawCookie
        }

        if let extracted = extractAACAudioSpecificConfig(from: rawCookie),
           looksLikeAACAudioSpecificConfig(extracted) {
            return extracted
        }

        if let synthesized = synthesizeAACAudioSpecificConfig(
            sampleRate: sampleRate,
            channels: channels,
            ffmpegProfile: ffmpegProfile
        ) {
            return synthesized
        }

        return rawCookie
    }

    private func looksLikeAACAudioSpecificConfig(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }

        let audioObjectType = Int((data[0] & 0xF8) >> 3)
        let samplingFrequencyIndex = Int(((data[0] & 0x07) << 1) | ((data[1] & 0x80) >> 7))
        let channelConfig = Int((data[1] & 0x78) >> 3)

        guard audioObjectType > 0 else { return false }
        guard samplingFrequencyIndex < 13 else { return false }
        guard channelConfig <= 7 else { return false }
        return true
    }

    private func extractAACAudioSpecificConfig(from data: Data) -> Data? {
        guard data.count >= 4 else { return nil }

        var index = data.startIndex
        while index < data.endIndex {
            guard data[index] == 0x05 else {
                index += 1
                continue
            }

            var lengthIndex = index + 1
            var length = 0
            var lengthBytes = 0

            while lengthIndex < data.endIndex && lengthBytes < 4 {
                let byte = Int(data[lengthIndex])
                length = (length << 7) | (byte & 0x7F)
                lengthBytes += 1
                lengthIndex += 1
                if (byte & 0x80) == 0 { break }
            }

            guard length > 0 else {
                index += 1
                continue
            }

            let endIndex = lengthIndex + length
            guard endIndex <= data.endIndex else {
                index += 1
                continue
            }

            let candidate = data.subdata(in: lengthIndex..<endIndex)
            if candidate.count >= 2 {
                return candidate
            }

            index += 1
        }

        return nil
    }

    private func synthesizeAACAudioSpecificConfig(sampleRate: Int, channels: Int, ffmpegProfile: Int) -> Data? {
        // ISO/IEC 14496-3 sample rate index table
        let sampleRateTable = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        guard let samplingFrequencyIndex = sampleRateTable.firstIndex(of: sampleRate) else {
            return nil
        }

        // Map FFmpeg AAC profile enum to MPEG-4 Audio Object Type.
        // Defaults to AAC-LC (2), which is the most common Plex direct-play AAC profile.
        let audioObjectType: Int
        switch ffmpegProfile {
        case 0: audioObjectType = 1  // MAIN
        case 1: audioObjectType = 2  // LC
        case 2: audioObjectType = 3  // SSR
        case 3: audioObjectType = 4  // LTP
        case 4: audioObjectType = 5  // HE-AAC (SBR)
        case 28: audioObjectType = 29 // HE-AACv2 (PS)
        default: audioObjectType = 2
        }

        let channelConfig = max(1, min(channels, 7))
        let byte0 = UInt8((audioObjectType << 3) | (samplingFrequencyIndex >> 1))
        let byte1 = UInt8(((samplingFrequencyIndex & 0x1) << 7) | (channelConfig << 3))
        return Data([byte0, byte1])
    }

    private func stripADTSHeaderIfNeeded(from data: Data) -> Data {
        guard data.count > 9 else { return data }

        // ADTS syncword: 0xFFF (12 bits) => first byte 0xFF, high nibble of second byte 0xF
        guard data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else {
            return data
        }

        let protectionAbsent = (data[1] & 0x01) != 0
        let adtsHeaderLength = protectionAbsent ? 7 : 9
        guard data.count > adtsHeaderLength else { return data }

        if !hasLoggedADTSStripping {
            hasLoggedADTSStripping = true
            print("[FFmpegDemuxer] Detected ADTS-wrapped AAC packets; stripping ADTS header (\(adtsHeaderLength) bytes)")
        }

        return data.subdata(in: adtsHeaderLength..<data.count)
    }

    // MARK: - Private: DV Detection

    private func detectDolbyVisionFromSideData() -> Bool {
        guard let ctx = formatContext, selectedVideoStream >= 0 else { return false }
        let stream = ctx.pointee.streams[Int(selectedVideoStream)]!

        if let sideData = av_packet_side_data_get(
            stream.pointee.codecpar.pointee.coded_side_data,
            stream.pointee.codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ), sideData.pointee.size >= 4 {
            let configData = Data(bytes: sideData.pointee.data, count: Int(sideData.pointee.size))
            if parseDolbyVisionConfig(configData, source: "codecpar_side_data") {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func parseDolbyVisionConfig(_ configData: Data, source: String) -> Bool {
        guard configData.count >= 4 else { return false }

        let profile = (configData[2] >> 1) & 0x7F
        let level = ((configData[2] & 0x01) << 5) | ((configData[3] >> 3) & 0x1F)
        let blCompat = configData.count >= 5 ? ((configData[4] >> 4) & 0x0F) : nil

        dvProfile = profile
        dvLevel = level
        dvBLCompatID = blCompat
        hasDolbyVision = true

        let compatText = blCompat.map(String.init) ?? "unknown"
        print(
            "[FFmpegDemuxer] Dolby Vision config (\(source)): " +
            "profile=\(profile) level=\(level) bl_compat=\(compatText) size=\(configData.count)B"
        )
        return true
    }

    // MARK: - Private: Color Mapping

    private func mapColorPrimaries(_ primaries: AVColorPrimaries) -> CFString? {
        switch primaries {
        case AVCOL_PRI_BT709: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: return kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: return kCMFormatDescriptionColorPrimaries_DCI_P3
        default: return nil
        }
    }

    private func mapTransferCharacteristics(_ trc: AVColorTransferCharacteristic) -> CFString? {
        switch trc {
        case AVCOL_TRC_BT709: return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    private func mapColorSpace(_ space: AVColorSpace) -> CFString? {
        switch space {
        case AVCOL_SPC_BT709: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: return nil
        }
    }

    // MARK: - Private: Helpers

    private func extractMetadata(from metadata: OpaquePointer?, key: String) -> String? {
        guard let metadata = metadata,
              let entry = av_dict_get(metadata, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }

    private func channelLayoutString(channels: Int32) -> String {
        switch channels {
        case 1: return "Mono"; case 2: return "Stereo"
        case 6: return "5.1"; case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }
}

/// AVERROR_EOF as usable Int32
private let AVERROR_EOF_VALUE: Int32 = {
    let tag = Int32(bitPattern:
        (UInt32(Character("E").asciiValue!) |
        (UInt32(Character("O").asciiValue!) << 8) |
        (UInt32(Character("F").asciiValue!) << 16) |
        (UInt32(Character(" ").asciiValue!) << 24)))
    return -tag
}()

#else

// =============================================================================
// MARK: - Stub Implementation (FFmpeg not available)
// =============================================================================

/// Stub demuxer when FFmpeg libraries are not linked.
/// All operations throw .notAvailable, causing ContentRouter to use HLS instead.
final class FFmpegDemuxer: @unchecked Sendable {

    private(set) var videoFormatDescription: CMFormatDescription?
    private(set) var audioFormatDescription: CMFormatDescription?

    private(set) var videoTracks: [FFmpegTrackInfo] = []
    private(set) var audioTracks: [FFmpegTrackInfo] = []
    private(set) var subtitleTracks: [FFmpegTrackInfo] = []

    private(set) var duration: TimeInterval = 0

    private(set) var selectedVideoStream: Int32 = -1
    private(set) var selectedAudioStream: Int32 = -1
    private(set) var selectedSubtitleStream: Int32 = -1

    private(set) var hasDolbyVision = false
    private(set) var dvProfile: UInt8?
    private(set) var dvLevel: UInt8?
    private(set) var dvBLCompatID: UInt8?

    /// FFmpeg libraries are not linked
    static let isAvailable = false

    func open(url: URL, headers: [String: String]? = nil, forceDolbyVision: Bool = false) throws {
        throw FFmpegError.notAvailable
    }

    func readPacket() throws -> DemuxedPacket? {
        throw FFmpegError.notAvailable
    }

    func seek(to time: TimeInterval) throws {
        throw FFmpegError.notAvailable
    }

    func selectAudioStream(index: Int32) throws {
        throw FFmpegError.notAvailable
    }

    func selectAudioStreamForClientDecode(index: Int32) throws {
        throw FFmpegError.notAvailable
    }

    func selectSubtitleStream(index: Int32) {}

    func codecParameters(forStream index: Int32) -> UnsafeRawPointer? { nil }

    func close() {}

    static func extractSubtitles(
        url: URL, headers: [String: String]?, streamIndex: Int32
    ) throws -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        throw FFmpegError.notAvailable
    }

    func createVideoSampleBuffer(from packet: DemuxedPacket, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        throw FFmpegError.notAvailable
    }

    func createAudioSampleBuffer(from packet: DemuxedPacket, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        throw FFmpegError.notAvailable
    }
}

#endif
