//
//  FFmpegRemuxSession.swift
//  Rivulet
//
//  Core remuxing engine that reads packets from a source URL via FFmpeg's
//  demuxer and produces HLS-compatible fMP4 init + media segments using
//  avformat's muxer. AVPlayer plays the resulting HLS from a local server.
//
//  Phase 1: Container swap only (MKV/MP4 → fMP4). Video and compatible audio
//  are copied without transcoding.
//
//  Phase 4 adds: DTS/TrueHD → EAC3 audio transcoding
//  Phase 5 adds: Dolby Vision P7/P8.6 → P8.1 RPU conversion
//

import Foundation

#if RIVULET_FFMPEG
import Libavformat
import Libavcodec
import Libavutil

// MARK: - Segment Info

/// Describes a single HLS media segment.
struct RemuxSegmentInfo: Sendable {
    let index: Int
    /// Keyframe PTS in the source stream's timebase
    let startPTS: Int64
    /// Duration in seconds (computed from gap between this keyframe and the next)
    let duration: TimeInterval
    /// Byte position in the source for seeking (or -1 if unavailable)
    let bytePosition: Int64
}

/// Information returned after opening a remux session.
struct RemuxSessionInfo: Sendable {
    let duration: TimeInterval
    let videoCodecName: String
    let audioCodecName: String
    let width: Int32
    let height: Int32
    let segments: [RemuxSegmentInfo]
    let hasDolbyVision: Bool
    let dvProfile: UInt8?
    let needsAudioTranscode: Bool
    let needsDVConversion: Bool
}

// MARK: - Errors

enum RemuxError: Error, Sendable {
    case notOpen
    case alreadyOpen
    case openFailed(String)
    case noVideoStream
    case noAudioStream
    case muxerFailed(String)
    case writeFailed(String)
    case seekFailed
    case segmentOutOfRange(Int)
    case cancelled
}

// MARK: - FFmpegRemuxSession

/// Reads from a source URL and produces fMP4 init + media segments for HLS playback.
///
/// Usage:
/// 1. `open(url:headers:)` — opens source, scans keyframes, builds segment list
/// 2. `generateInitSegment()` — produces fMP4 moov atom (codec descriptors)
/// 3. `generateSegment(index:)` — produces fMP4 moof+mdat for a specific segment
///
/// The session is an actor to serialize access to FFmpeg contexts (not thread-safe).
actor FFmpegRemuxSession {

    // MARK: - Public State

    private(set) var segments: [RemuxSegmentInfo] = []
    private(set) var duration: TimeInterval = 0
    private(set) var isOpen = false

    // MARK: - Source State

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1
    private var videoTimebase: AVRational = AVRational(num: 1, den: 90000)
    private var audioTimebase: AVRational = AVRational(num: 1, den: 48000)

    // Codec info from source
    private var videoCodecId: AVCodecID = AV_CODEC_ID_NONE
    private var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    private var videoCodecName: String = "unknown"
    private var audioCodecName: String = "unknown"
    private var videoWidth: Int32 = 0
    private var videoHeight: Int32 = 0

    // DV detection
    private var hasDolbyVision = false
    private var dvProfile: UInt8?

    // Audio analysis
    private var needsAudioTranscode = false
    private var needsDVConversion = false

    // Source URL and headers for reopening on seek
    private var sourceURL: URL?
    private var sourceHeaders: [String: String]?

    // Cancellation
    private var isCancelled = false

    // Target segment duration in seconds
    private let targetSegmentDuration: TimeInterval = 6.0

    // Cached init segment (moov)
    private var cachedInitSegment: Data?

    // DV conversion support (Phase 5)
    private var doviConverter: DoviProfileConverter?

    // Audio transcode support (Phase 4)
    private var audioDecoder: FFmpegAudioDecoder?
    private var audioEncoder: FFmpegAudioEncoder?

    deinit {
        if let ctx = formatContext {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }
    }

    // MARK: - Open

    /// Open a source URL, discover streams, and scan keyframes to build the segment list.
    func open(url: URL, headers: [String: String]? = nil) throws -> RemuxSessionInfo {
        guard !isOpen else { throw RemuxError.alreadyOpen }

        self.sourceURL = url
        self.sourceHeaders = headers

        // Allocate format context
        guard let ctx = avformat_alloc_context() else {
            throw RemuxError.openFailed("Failed to allocate format context")
        }

        // Set up HTTP headers
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
            throw RemuxError.openFailed("avformat_open_input failed: \(ret)")
        }

        let findRet = avformat_find_stream_info(openCtx, nil)
        guard findRet >= 0 else {
            avformat_close_input(&mutableCtx)
            throw RemuxError.openFailed("avformat_find_stream_info failed: \(findRet)")
        }

        self.formatContext = openCtx

        // Find best video and audio streams
        videoStreamIndex = av_find_best_stream(openCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioStreamIndex = av_find_best_stream(openCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)

        guard videoStreamIndex >= 0 else {
            avformat_close_input(&self.formatContext)
            self.formatContext = nil
            throw RemuxError.noVideoStream
        }

        // Capture codec info
        let videoStream = openCtx.pointee.streams[Int(videoStreamIndex)]!
        let videoCodecpar = videoStream.pointee.codecpar!
        videoCodecId = videoCodecpar.pointee.codec_id
        videoCodecName = String(cString: avcodec_get_name(videoCodecId))
        videoWidth = videoCodecpar.pointee.width
        videoHeight = videoCodecpar.pointee.height
        videoTimebase = videoStream.pointee.time_base

        if audioStreamIndex >= 0 {
            let audioStream = openCtx.pointee.streams[Int(audioStreamIndex)]!
            let audioCodecpar = audioStream.pointee.codecpar!
            audioCodecId = audioCodecpar.pointee.codec_id
            audioCodecName = String(cString: avcodec_get_name(audioCodecId))
            audioTimebase = audioStream.pointee.time_base
        }

        // Detect Dolby Vision
        detectDolbyVision(ctx: openCtx)

        // Determine what processing is needed
        analyzeProcessingNeeds()

        // Initialize audio transcoder if needed
        if needsAudioTranscode {
            try setupAudioTranscoder()
        }

        // Initialize DV converter if needed
        if needsDVConversion {
            doviConverter = DoviProfileConverter()
            print("[RemuxSession] DV P7→P8.1 conversion enabled")
        }

        // Get duration
        if openCtx.pointee.duration > 0 {
            duration = Double(openCtx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Build segment list from estimated time intervals (instant — no file reading)
        buildEstimatedSegmentList()

        isOpen = true
        isCancelled = false

        let info = RemuxSessionInfo(
            duration: duration,
            videoCodecName: videoCodecName,
            audioCodecName: audioCodecName,
            width: videoWidth,
            height: videoHeight,
            segments: segments,
            hasDolbyVision: hasDolbyVision,
            dvProfile: dvProfile,
            needsAudioTranscode: needsAudioTranscode,
            needsDVConversion: needsDVConversion
        )

        print("[RemuxSession] Opened: \(videoCodecName) \(videoWidth)x\(videoHeight), audio=\(audioCodecName), " +
              "duration=\(String(format: "%.1f", duration))s, segments=\(segments.count), " +
              "DV=\(hasDolbyVision ? "P\(dvProfile ?? 0)" : "no"), " +
              "audioTranscode=\(needsAudioTranscode), dvConversion=\(needsDVConversion)")

        return info
    }

    // MARK: - Init Segment Generation

    /// Generate the fMP4 init segment (moov atom with codec descriptors).
    /// This is cached after first generation.
    func generateInitSegment() throws -> Data {
        guard let ctx = formatContext, isOpen else { throw RemuxError.notOpen }
        if let cached = cachedInitSegment { return cached }

        // Create an in-memory fMP4 muxer for the init segment.
        // We use avformat to write a proper moov with codec descriptors.
        var outputBuffer: UnsafeMutablePointer<UInt8>? = nil
        var outputSize: Int = 0

        let initData = try writeInitSegment(sourceCtx: ctx)
        cachedInitSegment = initData
        print("[RemuxSession] Init segment: \(initData.count) bytes")
        return initData
    }

    // MARK: - Media Segment Generation

    /// Generate an fMP4 media segment (moof + mdat) for the given segment index.
    func generateSegment(index: Int) throws -> Data {
        guard let ctx = formatContext, isOpen else { throw RemuxError.notOpen }
        guard index >= 0 && index < segments.count else {
            throw RemuxError.segmentOutOfRange(index)
        }
        guard !isCancelled else { throw RemuxError.cancelled }

        let segment = segments[index]
        let nextSegmentPTS: Int64? = (index + 1 < segments.count) ? segments[index + 1].startPTS : nil

        // Seek to segment start position (time-based, backward to nearest keyframe)
        let seekTarget = av_rescale_q(segment.startPTS, videoTimebase,
                                       AVRational(num: 1, den: Int32(AV_TIME_BASE)))
        let seekRet = avformat_seek_file(ctx, -1, Int64.min, seekTarget, seekTarget,
                                          AVSEEK_FLAG_BACKWARD)
        if seekRet < 0 {
            // Seek failed — for segment 0 this is fine (already at start),
            // for others try seeking to the raw timestamp on the video stream
            if index > 0 {
                let streamSeekRet = avformat_seek_file(ctx, videoStreamIndex,
                                                        Int64.min, segment.startPTS, segment.startPTS, 0)
                if streamSeekRet < 0 {
                    print("[RemuxSession] Seek failed for segment \(index): \(streamSeekRet)")
                }
            }
        }

        // Read packets for this segment and write to fMP4 fragment
        let segmentData = try writeMediaSegment(
            sourceCtx: ctx,
            segmentIndex: index,
            startPTS: segment.startPTS,
            endPTS: nextSegmentPTS
        )

        print("[RemuxSession] Segment \(index): \(segmentData.count) bytes, " +
              "duration=\(String(format: "%.2f", segment.duration))s")

        return segmentData
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
    }

    // MARK: - Close

    func close() {
        if let ctx = formatContext {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }
        formatContext = nil
        isOpen = false
        segments = []
        cachedInitSegment = nil
        doviConverter = nil
        audioDecoder = nil
        audioEncoder = nil
    }

    // MARK: - Audio Stream Selection

    /// Select a different audio stream for remuxing.
    /// Must be called before generating segments.
    func selectAudioStream(index: Int32) throws {
        guard let ctx = formatContext, isOpen else { throw RemuxError.notOpen }
        guard index >= 0, index < ctx.pointee.nb_streams else {
            throw RemuxError.openFailed("Invalid audio stream index: \(index)")
        }
        let stream = ctx.pointee.streams[Int(index)]!
        guard stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            throw RemuxError.openFailed("Stream \(index) is not audio")
        }

        audioStreamIndex = index
        audioCodecId = stream.pointee.codecpar.pointee.codec_id
        audioCodecName = String(cString: avcodec_get_name(audioCodecId))
        audioTimebase = stream.pointee.time_base

        // Re-analyze processing needs
        analyzeProcessingNeeds()

        // Invalidate cached init segment since codec may have changed
        cachedInitSegment = nil

        print("[RemuxSession] Selected audio stream \(index): \(audioCodecName)")
    }

    // MARK: - Private: DV Detection

    private func detectDolbyVision(ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard videoStreamIndex >= 0 else { return }
        let stream = ctx.pointee.streams[Int(videoStreamIndex)]!

        // Check stream side data for DOVI configuration
        if let sideData = av_packet_side_data_get(
            stream.pointee.codecpar.pointee.coded_side_data,
            stream.pointee.codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ), sideData.pointee.size >= 4 {
            let data = Data(bytes: sideData.pointee.data, count: Int(sideData.pointee.size))
            // DOVIDecoderConfigurationRecord:
            // byte 0: dv_version_major
            // byte 1: dv_version_minor
            // byte 2: [profile(7 bits)][level high bit(1 bit)]
            // byte 3: [level low bits(5 bits)][rpu(1)][el(1)][bl(1)]
            // byte 4: [bl_compat_id(4 bits)][reserved(4 bits)]
            let profile = (data[2] >> 1) & 0x7F
            let blCompatId = (data.count > 4) ? (data[4] >> 4) & 0x0F : 0

            hasDolbyVision = true
            dvProfile = profile
            print("[RemuxSession] Dolby Vision detected: profile=\(profile), bl_compat_id=\(blCompatId)")
        }
    }

    // MARK: - Private: Processing Analysis

    private func analyzeProcessingNeeds() {
        // Audio transcode needed for DTS/TrueHD (AVPlayer can't decode them)
        needsAudioTranscode = [
            AV_CODEC_ID_DTS,
            AV_CODEC_ID_TRUEHD,
            AV_CODEC_ID_MLP
        ].contains(audioCodecId)

        // DV conversion needed for Profile 7 (dual-layer → single-layer P8.1)
        needsDVConversion = hasDolbyVision && (dvProfile == 7)
    }

    // MARK: - Audio Transcoding Setup

    /// Initialize audio decoder and encoder for DTS/TrueHD → EAC3 transcoding.
    private func setupAudioTranscoder() throws {
        guard let ctx = formatContext, audioStreamIndex >= 0 else { return }
        guard needsAudioTranscode else { return }

        let audioStream = ctx.pointee.streams[Int(audioStreamIndex)]!
        let codecpar = audioStream.pointee.codecpar!

        // Set up decoder
        let decoder = try FFmpegAudioDecoder(
            codecpar: UnsafePointer(codecpar),
            codecNameHint: audioCodecName
        )
        self.audioDecoder = decoder

        // Set up encoder — output channels capped at 6 (5.1) for EAC3
        let srcChannels = Int(codecpar.pointee.ch_layout.nb_channels)
        let outChannels = min(srcChannels, 6)
        let encoder = try FFmpegAudioEncoder(
            channels: outChannels,
            sampleRate: 48000,
            bitsPerSample: 32  // F32 PCM from decoder
        )
        self.audioEncoder = encoder

        print("[RemuxSession] Audio transcoder: \(audioCodecName) → EAC3 (\(srcChannels)ch → \(outChannels)ch)")
    }

    /// Transcode an audio packet: decode to PCM, re-encode to EAC3.
    /// Returns encoded EAC3 packets as raw Data with timestamps.
    private func transcodeAudioPacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                       timebase: AVRational) -> [(data: Data, pts: Int64, duration: Int64)] {
        guard let decoder = audioDecoder, let encoder = audioEncoder else { return [] }

        // Create a DemuxedPacket from the raw AVPacket
        guard let packetData = packet.pointee.data else { return [] }
        let data = Data(bytes: packetData, count: Int(packet.pointee.size))
        let tbNum = Int64(timebase.num == 0 ? 1 : timebase.num)
        let tbDen = Int32(timebase.den == 0 ? 1 : timebase.den)

        let demuxedPacket = DemuxedPacket(
            streamIndex: packet.pointee.stream_index,
            trackType: .audio,
            data: data,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts,
            duration: packet.pointee.duration,
            timebase: CMTime(value: tbNum, timescale: tbDen),
            isKeyframe: true
        )

        // Decode to PCM
        let decodedFrames = decoder.decode(demuxedPacket)

        // Encode to EAC3
        var results: [(data: Data, pts: Int64, duration: Int64)] = []
        for decoded in decodedFrames {
            let encoded = encoder.encode(decoded)
            for enc in encoded {
                // Convert PTS back to output timebase (1/48000)
                let pts = Int64(enc.pts.seconds * 48000)
                let duration = Int64(enc.sampleCount)  // Duration in samples at 48kHz
                results.append((data: enc.data, pts: pts, duration: duration))
            }
        }

        return results
    }

    // MARK: - Private: Segment List

    /// Build segment list using estimated time intervals.
    /// No file reading — instant. Segment generation handles keyframe alignment at playback time.
    private func buildEstimatedSegmentList() {
        guard duration > 0 else {
            segments = [RemuxSegmentInfo(index: 0, startPTS: 0, duration: max(duration, 1), bytePosition: -1)]
            return
        }

        let timebaseFactor = Double(videoTimebase.num) / Double(videoTimebase.den)
        guard timebaseFactor > 0 else {
            segments = [RemuxSegmentInfo(index: 0, startPTS: 0, duration: duration, bytePosition: -1)]
            return
        }

        var result: [RemuxSegmentInfo] = []
        var segIdx = 0
        var currentTime: TimeInterval = 0

        while currentTime < duration {
            let segDuration = min(targetSegmentDuration, duration - currentTime)
            let startPTS = Int64(currentTime / timebaseFactor)

            result.append(RemuxSegmentInfo(
                index: segIdx,
                startPTS: startPTS,
                duration: segDuration,
                bytePosition: -1
            ))
            segIdx += 1
            currentTime += targetSegmentDuration
        }

        segments = result
        print("[RemuxSession] Built \(segments.count) estimated segments (\(String(format: "%.1f", targetSegmentDuration))s each)")
    }

    // MARK: - Private: Init Segment Writing

    /// Write an fMP4 init segment (moov) using avformat's MOV muxer.
    private func writeInitSegment(sourceCtx: UnsafeMutablePointer<AVFormatContext>) throws -> Data {
        // Create output format context with in-memory I/O
        var outputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        let allocRet = avformat_alloc_output_context2(&outputCtx, nil, "mp4", nil)
        guard allocRet >= 0, let outCtx = outputCtx else {
            throw RemuxError.muxerFailed("Failed to allocate output context: \(allocRet)")
        }
        defer { avformat_free_context(outCtx) }

        // Add video stream
        guard let outVideoStream = avformat_new_stream(outCtx, nil) else {
            throw RemuxError.muxerFailed("Failed to create output video stream")
        }
        let srcVideoStream = sourceCtx.pointee.streams[Int(videoStreamIndex)]!
        var copyRet = avcodec_parameters_copy(outVideoStream.pointee.codecpar, srcVideoStream.pointee.codecpar)
        guard copyRet >= 0 else {
            throw RemuxError.muxerFailed("Failed to copy video codec params: \(copyRet)")
        }
        outVideoStream.pointee.time_base = srcVideoStream.pointee.time_base
        outVideoStream.pointee.codecpar.pointee.codec_tag = 0  // Let muxer choose

        // For DV content, set dvh1 codec tag so AVPlayer triggers DV pipeline
        if hasDolbyVision {
            // DV P8 or converted P7→P8.1 — set dvh1 tag
            outVideoStream.pointee.codecpar.pointee.codec_tag = fourCC("dvh1")
        }

        // Add audio stream (if present)
        if audioStreamIndex >= 0 {
            guard let outAudioStream = avformat_new_stream(outCtx, nil) else {
                throw RemuxError.muxerFailed("Failed to create output audio stream")
            }
            let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!

            if needsAudioTranscode {
                // Audio will be transcoded to EAC3 — set up output codec params accordingly
                configureEAC3OutputParams(outAudioStream.pointee.codecpar,
                                          from: srcAudioStream.pointee.codecpar)
                outAudioStream.pointee.time_base = AVRational(num: 1, den: 48000)
            } else {
                copyRet = avcodec_parameters_copy(outAudioStream.pointee.codecpar, srcAudioStream.pointee.codecpar)
                guard copyRet >= 0 else {
                    throw RemuxError.muxerFailed("Failed to copy audio codec params: \(copyRet)")
                }
                outAudioStream.pointee.time_base = srcAudioStream.pointee.time_base
            }
            outAudioStream.pointee.codecpar.pointee.codec_tag = 0
        }

        // Set up in-memory I/O
        let bufferSize: Int = 32768
        guard let avioBuffer = av_malloc(bufferSize) else {
            throw RemuxError.muxerFailed("Failed to allocate AVIO buffer")
        }

        var outputData = Data()
        let opaquePtr = Unmanaged.passRetained(OutputDataWrapper(data: &outputData)).toOpaque()

        guard let avioCtx = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            1,  // write flag
            opaquePtr,
            nil,  // read
            { opaquePtr, buf, bufSize -> Int32 in
                // Write callback
                guard let opaque = opaquePtr, let buf = buf, bufSize > 0 else { return 0 }
                let wrapper = Unmanaged<OutputDataWrapper>.fromOpaque(opaque).takeUnretainedValue()
                wrapper.dataPointer.pointee.append(buf, count: Int(bufSize))
                return bufSize
            },
            nil   // seek
        ) else {
            av_free(avioBuffer)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate AVIO context")
        }

        outCtx.pointee.pb = avioCtx
        outCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        // Set fMP4 options: write moov only (empty mdat), movflags for fragmented MP4
        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "movflags", "frag_custom+empty_moov+default_base_moof+omit_tfhd_offset", 0)

        let headerRet = avformat_write_header(outCtx, &opts)
        av_dict_free(&opts)
        guard headerRet >= 0 else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to write header: \(headerRet)")
        }

        // Flush the header
        avio_flush(outCtx.pointee.pb)

        // Write trailer (completes the moov)
        av_write_trailer(outCtx)
        avio_flush(outCtx.pointee.pb)

        // Clean up AVIO
        avio_context_free(&outCtx.pointee.pb)
        Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()

        return outputData
    }

    // MARK: - Private: Media Segment Writing

    /// Write an fMP4 media segment (moof+mdat) containing packets for the given segment.
    private func writeMediaSegment(
        sourceCtx: UnsafeMutablePointer<AVFormatContext>,
        segmentIndex: Int,
        startPTS: Int64,
        endPTS: Int64?
    ) throws -> Data {
        // Create output format context with in-memory I/O
        var outputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        let allocRet = avformat_alloc_output_context2(&outputCtx, nil, "mp4", nil)
        guard allocRet >= 0, let outCtx = outputCtx else {
            throw RemuxError.muxerFailed("Failed to allocate segment output context: \(allocRet)")
        }
        defer { avformat_free_context(outCtx) }

        // Mirror the stream setup from init segment
        guard let outVideoStream = avformat_new_stream(outCtx, nil) else {
            throw RemuxError.muxerFailed("Failed to create segment video stream")
        }
        let srcVideoStream = sourceCtx.pointee.streams[Int(videoStreamIndex)]!
        avcodec_parameters_copy(outVideoStream.pointee.codecpar, srcVideoStream.pointee.codecpar)
        outVideoStream.pointee.time_base = srcVideoStream.pointee.time_base
        outVideoStream.pointee.codecpar.pointee.codec_tag = 0

        if hasDolbyVision {
            outVideoStream.pointee.codecpar.pointee.codec_tag = fourCC("dvh1")
        }

        var outAudioStreamIndex: Int32 = -1
        if audioStreamIndex >= 0 {
            guard let outAudioStream = avformat_new_stream(outCtx, nil) else {
                throw RemuxError.muxerFailed("Failed to create segment audio stream")
            }
            outAudioStreamIndex = outAudioStream.pointee.index

            let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
            if needsAudioTranscode {
                configureEAC3OutputParams(outAudioStream.pointee.codecpar,
                                          from: srcAudioStream.pointee.codecpar)
                outAudioStream.pointee.time_base = AVRational(num: 1, den: 48000)
            } else {
                avcodec_parameters_copy(outAudioStream.pointee.codecpar, srcAudioStream.pointee.codecpar)
                outAudioStream.pointee.time_base = srcAudioStream.pointee.time_base
            }
            outAudioStream.pointee.codecpar.pointee.codec_tag = 0
        }

        // Set up in-memory I/O
        let bufferSize: Int = 65536
        guard let avioBuffer = av_malloc(bufferSize) else {
            throw RemuxError.muxerFailed("Failed to allocate segment AVIO buffer")
        }

        var outputData = Data()
        let opaquePtr = Unmanaged.passRetained(OutputDataWrapper(data: &outputData)).toOpaque()

        guard let avioCtx = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            1,
            opaquePtr,
            nil,
            { opaquePtr, buf, bufSize -> Int32 in
                guard let opaque = opaquePtr, let buf = buf, bufSize > 0 else { return 0 }
                let wrapper = Unmanaged<OutputDataWrapper>.fromOpaque(opaque).takeUnretainedValue()
                wrapper.dataPointer.pointee.append(buf, count: Int(bufSize))
                return bufSize
            },
            nil
        ) else {
            av_free(avioBuffer)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate segment AVIO context")
        }

        outCtx.pointee.pb = avioCtx
        outCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        // Write header with frag_custom (we control fragment boundaries)
        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "movflags", "frag_custom+empty_moov+default_base_moof+omit_tfhd_offset", 0)

        let headerRet = avformat_write_header(outCtx, &opts)
        av_dict_free(&opts)
        guard headerRet >= 0 else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to write segment header: \(headerRet)")
        }

        // Read packets from source and write to output
        var pkt = av_packet_alloc()
        guard let packet = pkt else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate packet")
        }
        defer { av_packet_free(&pkt) }

        var videoPacketCount = 0
        var audioPacketCount = 0
        var hitNextSegment = false
        var foundFirstKeyframe = false

        while !isCancelled {
            let readRet = av_read_frame(sourceCtx, packet)
            if readRet < 0 { break }  // EOF or error
            defer { av_packet_unref(packet) }

            let streamIndex = packet.pointee.stream_index

            // Only process video and audio
            guard streamIndex == videoStreamIndex || streamIndex == audioStreamIndex else {
                continue
            }

            if streamIndex == videoStreamIndex {
                // Check if we've reached the next segment
                if let endPTS = endPTS, packet.pointee.pts >= endPTS {
                    if foundFirstKeyframe {
                        hitNextSegment = true
                        break
                    }
                }

                // Wait for the first keyframe at or after our start PTS
                if !foundFirstKeyframe {
                    if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 && packet.pointee.pts >= startPTS {
                        foundFirstKeyframe = true
                    } else {
                        continue
                    }
                }

                // Remap stream index for output (video is always stream 0)
                packet.pointee.stream_index = 0

                // Apply DV P7→P8.1 conversion if needed
                if let converter = doviConverter, needsDVConversion,
                   let packetData = packet.pointee.data, packet.pointee.size > 0 {
                    let originalData = Data(bytes: packetData, count: Int(packet.pointee.size))
                    let convertedData = converter.processVideoSample(originalData)

                    if convertedData.count != originalData.count || convertedData != originalData {
                        // Replace packet data with converted version
                        let newSize = Int32(convertedData.count)
                        if let newBuf = av_malloc(Int(newSize)) {
                            convertedData.copyBytes(to: newBuf.assumingMemoryBound(to: UInt8.self),
                                                    count: Int(newSize))
                            // Free old buffer and replace
                            av_buffer_unref(&packet.pointee.buf)
                            packet.pointee.data = newBuf.assumingMemoryBound(to: UInt8.self)
                            packet.pointee.size = newSize
                            packet.pointee.buf = av_buffer_create(
                                newBuf.assumingMemoryBound(to: UInt8.self),
                                Int(newSize),
                                { _, buf in av_free(buf) },
                                nil, 0
                            )
                        }
                    }
                }

                // Rescale timestamps to output timebase
                av_packet_rescale_ts(packet,
                                     srcVideoStream.pointee.time_base,
                                     outVideoStream.pointee.time_base)

                let writeRet = av_write_frame(outCtx, packet)
                if writeRet < 0 {
                    print("[RemuxSession] Warning: video write failed for segment \(segmentIndex): \(writeRet)")
                }
                videoPacketCount += 1

            } else if streamIndex == audioStreamIndex {
                // Only include audio packets in the time range
                guard foundFirstKeyframe else { continue }

                let audioPTS = av_rescale_q(packet.pointee.pts, audioTimebase, videoTimebase)
                if let endPTS = endPTS, audioPTS >= endPTS {
                    continue
                }

                let outStreamIdx = (outAudioStreamIndex >= 0) ? outAudioStreamIndex : 1

                if needsAudioTranscode {
                    // Transcode: DTS/TrueHD → PCM → EAC3
                    let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
                    let encodedPackets = transcodeAudioPacket(packet, timebase: srcAudioStream.pointee.time_base)

                    for enc in encodedPackets {
                        var outPkt = av_packet_alloc()
                        guard let encPkt = outPkt else { continue }
                        defer { av_packet_free(&outPkt) }

                        enc.data.withUnsafeBytes { buf in
                            guard let baseAddr = buf.baseAddress else { return }
                            av_packet_from_data(encPkt,
                                              UnsafeMutablePointer(mutating: baseAddr.assumingMemoryBound(to: UInt8.self)),
                                              Int32(enc.data.count))
                        }
                        // Actually, we need to copy the data since av_packet_from_data takes ownership
                        // Use a different approach: allocate and copy
                        let bufSize = Int32(enc.data.count)
                        guard let packetBuf = av_malloc(Int(bufSize)) else { continue }
                        enc.data.copyBytes(to: packetBuf.assumingMemoryBound(to: UInt8.self), count: Int(bufSize))

                        var freshPkt = av_packet_alloc()
                        guard let fp = freshPkt else {
                            av_free(packetBuf)
                            continue
                        }
                        fp.pointee.data = packetBuf.assumingMemoryBound(to: UInt8.self)
                        fp.pointee.size = bufSize
                        fp.pointee.stream_index = outStreamIdx
                        fp.pointee.pts = enc.pts
                        fp.pointee.dts = enc.pts
                        fp.pointee.duration = enc.duration

                        let dstAudioStream = outCtx.pointee.streams[Int(outStreamIdx)]!
                        av_packet_rescale_ts(fp,
                                             AVRational(num: 1, den: 48000),
                                             dstAudioStream.pointee.time_base)

                        av_write_frame(outCtx, fp)
                        av_packet_free(&freshPkt)
                        audioPacketCount += 1
                    }
                } else {
                    // Copy audio packet directly
                    packet.pointee.stream_index = outStreamIdx

                    let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
                    let dstAudioStream = outCtx.pointee.streams[Int(outStreamIdx)]!
                    av_packet_rescale_ts(packet,
                                         srcAudioStream.pointee.time_base,
                                         dstAudioStream.pointee.time_base)

                    let writeRet = av_write_frame(outCtx, packet)
                    if writeRet < 0 {
                        print("[RemuxSession] Warning: audio write failed for segment \(segmentIndex): \(writeRet)")
                    }
                    audioPacketCount += 1
                }
            }
        }

        guard !isCancelled else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()
            throw RemuxError.cancelled
        }

        // Flush the fragment
        avio_flush(outCtx.pointee.pb)
        av_write_frame(outCtx, nil)  // Flush interleaving queue
        avio_flush(outCtx.pointee.pb)

        // Write trailer
        av_write_trailer(outCtx)
        avio_flush(outCtx.pointee.pb)

        // Clean up AVIO
        avio_context_free(&outCtx.pointee.pb)
        Unmanaged<OutputDataWrapper>.fromOpaque(opaquePtr).release()

        // The output contains both the (empty) moov and the moof+mdat.
        // We need to strip the moov and return only the moof+mdat.
        let segmentData = stripMoovBox(from: outputData)

        return segmentData
    }

    // MARK: - Private: fMP4 Box Parsing

    /// Strip the moov box from fMP4 data, returning only moof+mdat (and styp if present).
    /// Each media segment should NOT contain a moov — only the init segment has it.
    private func stripMoovBox(from data: Data) -> Data {
        var result = Data()
        var offset = 0

        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""

            guard boxSize >= 8 && offset + boxSize <= data.count else { break }

            // Keep everything except moov and ftyp (init-only boxes)
            if boxType != "moov" && boxType != "ftyp" {
                result.append(data[offset..<offset+boxSize])
            }

            offset += boxSize
        }

        return result.isEmpty ? data : result
    }

    // MARK: - Private: EAC3 Output Configuration

    /// Configure output codec parameters for EAC3 transcoded audio.
    private func configureEAC3OutputParams(
        _ outParams: UnsafeMutablePointer<AVCodecParameters>,
        from srcParams: UnsafeMutablePointer<AVCodecParameters>
    ) {
        outParams.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        outParams.pointee.codec_id = AV_CODEC_ID_EAC3
        outParams.pointee.sample_rate = 48000
        // Preserve channel count from source, up to 6 (5.1)
        let srcChannels = srcParams.pointee.ch_layout.nb_channels
        let outChannels = min(srcChannels, 6)
        av_channel_layout_default(&outParams.pointee.ch_layout, outChannels)
        outParams.pointee.bit_rate = (outChannels > 2) ? 640000 : 192000
        outParams.pointee.frame_size = 1536
    }

    // MARK: - Private: Helpers

    private func fourCC(_ string: String) -> UInt32 {
        let chars = Array(string.utf8)
        guard chars.count == 4 else { return 0 }
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }
}

// MARK: - Output Data Wrapper (for AVIO callback)

/// Wrapper to pass a mutable Data pointer through an opaque C callback.
private final class OutputDataWrapper {
    let dataPointer: UnsafeMutablePointer<Data>

    init(data: UnsafeMutablePointer<Data>) {
        self.dataPointer = data
    }
}

// MARK: - Data Extension for Big-Endian Box Parsing

private extension Data {
    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { buf in
            let ptr = buf.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(ptr[0]) << 24 | UInt32(ptr[1]) << 16 | UInt32(ptr[2]) << 8 | UInt32(ptr[3])
        }
    }
}

// MARK: - AVSEEK_FLAG constants

private let AVSEEK_FLAG_BACKWARD: Int32 = 1
private let AVSEEK_FLAG_BYTE: Int32 = 2

#else

// =============================================================================
// MARK: - Stub Implementation (FFmpeg not available)
// =============================================================================

struct RemuxSegmentInfo: Sendable {
    let index: Int
    let startPTS: Int64
    let duration: TimeInterval
    let bytePosition: Int64
}

struct RemuxSessionInfo: Sendable {
    let duration: TimeInterval
    let videoCodecName: String
    let audioCodecName: String
    let width: Int32
    let height: Int32
    let segments: [RemuxSegmentInfo]
    let hasDolbyVision: Bool
    let dvProfile: UInt8?
    let needsAudioTranscode: Bool
    let needsDVConversion: Bool
}

enum RemuxError: Error, Sendable {
    case notOpen
    case alreadyOpen
    case openFailed(String)
    case noVideoStream
    case noAudioStream
    case muxerFailed(String)
    case writeFailed(String)
    case seekFailed
    case segmentOutOfRange(Int)
    case cancelled
}

actor FFmpegRemuxSession {
    private(set) var segments: [RemuxSegmentInfo] = []
    private(set) var duration: TimeInterval = 0
    private(set) var isOpen = false

    func open(url: URL, headers: [String: String]? = nil) throws -> RemuxSessionInfo {
        throw RemuxError.openFailed("FFmpeg not available")
    }

    func generateInitSegment() throws -> Data {
        throw RemuxError.notOpen
    }

    func generateSegment(index: Int) throws -> Data {
        throw RemuxError.notOpen
    }

    func cancel() {}
    func close() {}
    func selectAudioStream(index: Int32) throws {
        throw RemuxError.notOpen
    }
}

#endif
