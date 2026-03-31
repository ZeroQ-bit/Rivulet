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
    private let targetSegmentDuration: TimeInterval = 2.0
    private let estimatedSegmentDurationMin: TimeInterval = 2.0
    private let estimatedSegmentDurationMax: TimeInterval = 12.0
    private var estimatedSegmentDuration: TimeInterval = 2.0
    // Hard ceiling to avoid pathological scans on damaged/odd streams.
    private let maxPacketsPerSegmentRead = 60_000
    // Estimated segments can drift from real keyframe boundaries. As we generate
    // sequentially, capture actual keyframe starts per index to keep continuity.
    private var usesEstimatedSegments = false
    private var actualSegmentStartPTS: [Int: Int64] = [:]

    // Cached init segment (moov)
    private var cachedInitSegment: Data?

    // Cached raw audio frame from init segment generation. The EAC3/AC3 muxer
    // needs to parse a real audio packet before it can build the moov (dec3 box).
    // If a media segment has no audio, we inject this primer so the moov succeeds.
    private var cachedAudioPrimer: Data?

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
            let headerString = headers.map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
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

        // Build segment list from actual keyframes (reads the file's index/keyframes).
        // Falls back to estimated segments if keyframe scan finds nothing.
        estimatedSegmentDuration = targetSegmentDuration
        buildKeyframeSegmentList(ctx: openCtx)
        if segments.isEmpty {
            usesEstimatedSegments = true
            if let probed = probeKeyframeInterval(ctx: openCtx) {
                estimatedSegmentDuration = probed
            }
            buildEstimatedSegmentList()
        } else {
            usesEstimatedSegments = false
        }
        actualSegmentStartPTS.removeAll()

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

        let rawData = try writeInitSegment(sourceCtx: ctx)
        // Extract only ftyp + moov boxes (strip any moof+mdat from delay_moov output)
        let initData = extractInitBoxes(from: rawData)
        guard isValidInitSegment(initData) else {
            throw RemuxError.writeFailed("Invalid init segment structure")
        }
        cachedInitSegment = initData
        print("[RemuxSession] Init segment: \(initData.count) bytes (raw \(rawData.count) bytes)")
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
        let generationStart = Date()

        let segment = segments[index]
        var startPTS = segment.startPTS
        if usesEstimatedSegments, let refinedStart = actualSegmentStartPTS[index] {
            startPTS = refinedStart
        }
        var nextSegmentPTS: Int64?
        if index + 1 < segments.count {
            if usesEstimatedSegments, let refinedNextStart = actualSegmentStartPTS[index + 1] {
                nextSegmentPTS = refinedNextStart
            } else {
                nextSegmentPTS = segments[index + 1].startPTS
            }
        }

        // Seek to segment start position (time-based, backward to nearest keyframe)
        let streamSeekRet = avformat_seek_file(
            ctx,
            videoStreamIndex,
            Int64.min,
            startPTS,
            startPTS,
            AVSEEK_FLAG_BACKWARD
        )
        if streamSeekRet < 0 {
            let seekTarget = av_rescale_q(startPTS, videoTimebase,
                                          AVRational(num: 1, den: Int32(AV_TIME_BASE)))
            let globalSeekRet = avformat_seek_file(
                ctx,
                -1,
                Int64.min,
                seekTarget,
                seekTarget,
                AVSEEK_FLAG_BACKWARD
            )
            if globalSeekRet < 0, index > 0 {
                print("[RemuxSession] Seek failed for segment \(index): stream=\(streamSeekRet), global=\(globalSeekRet)")
            }
        }
        avformat_flush(ctx)

        // Read packets for this segment and write to fMP4 fragment
        let result = try writeMediaSegment(
            sourceCtx: ctx,
            segmentIndex: index,
            startPTS: startPTS,
            endPTS: nextSegmentPTS
        )
        let segmentData = result.data

        if usesEstimatedSegments {
            actualSegmentStartPTS[index] = result.actualStartPTS
            let nextIndex = index + 1
            if nextIndex < segments.count,
               let observedNextStart = result.nextSegmentStartPTS,
               actualSegmentStartPTS[nextIndex] == nil {
                actualSegmentStartPTS[nextIndex] = max(observedNextStart, result.actualStartPTS + 1)
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
        print("[RemuxSession] Segment \(index): \(segmentData.count) bytes, " +
              "duration=\(String(format: "%.2f", segment.duration))s, elapsed=\(elapsedMs)ms")

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
        actualSegmentStartPTS.removeAll()
        usesEstimatedSegments = false
        cachedInitSegment = nil
        cachedAudioPrimer = nil
        doviConverter = nil
        audioDecoder = nil
        audioEncoder = nil
        isCancelled = false
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
        cachedAudioPrimer = nil
        audioDecoder = nil
        audioEncoder = nil
        if needsAudioTranscode {
            try setupAudioTranscoder()
        }

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

    /// Build segment list from the container's index entries (MKV Cues, MP4 stss).
    /// These are already in memory after avformat_find_stream_info — no I/O needed.
    /// Groups keyframes into segments of approximately targetSegmentDuration.
    private func buildKeyframeSegmentList(ctx: UnsafeMutablePointer<AVFormatContext>) {
        let timebaseFactor = Double(videoTimebase.num) / Double(videoTimebase.den)
        guard timebaseFactor > 0, duration > 0 else { return }

        let stream = ctx.pointee.streams[Int(videoStreamIndex)]!
        let numEntries = Int(avformat_index_get_entries_count(stream))
        guard numEntries >= 2 else { return }

        // Collect keyframe timestamps from the container index (MKV Cues, etc.)
        var keyframePTS: [Int64] = []
        keyframePTS.reserveCapacity(numEntries)
        for i in 0..<numEntries {
            guard let entry = avformat_index_get_entry(stream, Int32(i)) else { continue }
            if entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 {
                keyframePTS.append(entry.pointee.timestamp)
            }
        }

        guard keyframePTS.count >= 2 else { return }

        // Group keyframes into segments of approximately targetSegmentDuration
        let targetDurationPTS = Int64(targetSegmentDuration / timebaseFactor)
        var result: [RemuxSegmentInfo] = []
        var segIdx = 0
        var segStartIdx = 0

        while segStartIdx < keyframePTS.count {
            let startPTS = keyframePTS[segStartIdx]

            // Find the next keyframe that's at least targetDuration past our start
            var nextSegStartIdx = segStartIdx + 1
            while nextSegStartIdx < keyframePTS.count {
                if keyframePTS[nextSegStartIdx] - startPTS >= targetDurationPTS {
                    break
                }
                nextSegStartIdx += 1
            }

            let endPTS: Int64
            if nextSegStartIdx < keyframePTS.count {
                endPTS = keyframePTS[nextSegStartIdx]
            } else {
                endPTS = Int64(duration / timebaseFactor)
            }
            let segDuration = Double(endPTS - startPTS) * timebaseFactor

            result.append(RemuxSegmentInfo(
                index: segIdx,
                startPTS: startPTS,
                duration: max(segDuration, 0.001),
                bytePosition: -1
            ))

            segIdx += 1
            segStartIdx = nextSegStartIdx
        }

        segments = result
        print("[RemuxSession] Built \(segments.count) keyframe-aligned segments from \(keyframePTS.count) keyframes " +
              "(avg \(String(format: "%.1f", duration / Double(max(segments.count, 1))))s each)")
    }

    /// Build segment list using estimated time intervals.
    /// Fallback when keyframe scan produces no results.
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

        let segmentDuration = max(
            estimatedSegmentDurationMin,
            min(estimatedSegmentDuration, estimatedSegmentDurationMax)
        )

        while currentTime < duration {
            let segDuration = min(segmentDuration, duration - currentTime)
            let startPTS = Int64(currentTime / timebaseFactor)

            result.append(RemuxSegmentInfo(
                index: segIdx,
                startPTS: startPTS,
                duration: segDuration,
                bytePosition: -1
            ))
            segIdx += 1
            currentTime += segmentDuration
        }

        segments = result
        print("[RemuxSession] Built \(segments.count) estimated segments (\(String(format: "%.1f", segmentDuration))s each)")
    }

    /// Probe the first few keyframes directly from packets when container index
    /// metadata is unavailable. This keeps fallback segmenting aligned to real GOP.
    private func probeKeyframeInterval(ctx: UnsafeMutablePointer<AVFormatContext>) -> TimeInterval? {
        guard videoStreamIndex >= 0 else { return nil }
        let timebaseFactor = Double(videoTimebase.num) / Double(videoTimebase.den)
        guard timebaseFactor > 0 else { return nil }

        let seekRet = avformat_seek_file(ctx, videoStreamIndex, Int64.min, 0, 0, AVSEEK_FLAG_BACKWARD)
        if seekRet >= 0 {
            avformat_flush(ctx)
        }

        var pkt = av_packet_alloc()
        guard let packet = pkt else { return nil }
        defer { av_packet_free(&pkt) }
        defer {
            let resetRet = avformat_seek_file(ctx, videoStreamIndex, Int64.min, 0, 0, AVSEEK_FLAG_BACKWARD)
            if resetRet >= 0 {
                avformat_flush(ctx)
            }
        }

        var keyframePTS: [Int64] = []
        keyframePTS.reserveCapacity(4)
        var packetsRead = 0
        let maxPackets = 20_000

        while packetsRead < maxPackets && keyframePTS.count < 4 {
            packetsRead += 1
            let readRet = av_read_frame(ctx, packet)
            if readRet < 0 { break }
            defer { av_packet_unref(packet) }

            guard packet.pointee.stream_index == videoStreamIndex else { continue }
            guard (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 else { continue }
            let pts = packet.pointee.pts
            if keyframePTS.last != pts {
                keyframePTS.append(pts)
            }
        }

        guard keyframePTS.count >= 2 else { return nil }
        let diffs = zip(keyframePTS, keyframePTS.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard !diffs.isEmpty else { return nil }

        let sortedDiffs = diffs.sorted()
        let medianPTS = sortedDiffs[sortedDiffs.count / 2]
        let rawSeconds = Double(medianPTS) * timebaseFactor
        let clamped = max(estimatedSegmentDurationMin, min(rawSeconds, estimatedSegmentDurationMax))

        print("[RemuxSession] Probed fallback keyframe interval: raw=\(String(format: "%.2f", rawSeconds))s, using=\(String(format: "%.2f", clamped))s")
        return clamped
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

        // Let FFmpeg choose the codec tag (hev1/hvc1).
        // DV signaling (dvh1) will be patched in the init segment after muxing if needed.

        // Add audio stream (if present)
        if audioStreamIndex >= 0 {
            guard let outAudioStream = avformat_new_stream(outCtx, nil) else {
                throw RemuxError.muxerFailed("Failed to create output audio stream")
            }
            let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!

            if needsAudioTranscode {
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

            // EAC3 requires frame_size to be set before moov can be written
            if outAudioStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3 {
                outAudioStream.pointee.codecpar.pointee.frame_size = 1536
            }
            // AC3 also needs frame_size
            if outAudioStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_AC3 {
                outAudioStream.pointee.codecpar.pointee.frame_size = 1536
            }
        }

        // Set up in-memory I/O
        let bufferSize: Int = 32768
        guard let avioBuffer = av_malloc(bufferSize) else {
            throw RemuxError.muxerFailed("Failed to allocate AVIO buffer")
        }

        var outputData = Data()
        let writer = OutputWriter(target: &outputData)
        let opaquePtr = Unmanaged.passRetained(writer).toOpaque()

        guard let avioCtx = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            1,  // write flag
            opaquePtr,
            nil,  // read
            { opaquePtr, buf, bufSize -> Int32 in
                guard let opaque = opaquePtr, let buf = buf, bufSize > 0 else { return 0 }
                let w = Unmanaged<OutputWriter>.fromOpaque(opaque).takeUnretainedValue()
                return w.write(buf, count: bufSize)
            },
            nil   // seek
        ) else {
            av_free(avioBuffer)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate AVIO context")
        }

        outCtx.pointee.pb = avioCtx
        outCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        // Use delay_moov: moov is written after first fragment, allowing EAC3 muxer
        // to parse a real packet before creating the dec3 box.
        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "movflags", "frag_custom+delay_moov+default_base_moof+omit_tfhd_offset", 0)

        // Allow unofficial extensions (DV dvcC/dvvC boxes)
        outCtx.pointee.strict_std_compliance = -2  // FF_COMPLIANCE_UNOFFICIAL

        let headerRet = avformat_write_header(outCtx, &opts)
        av_dict_free(&opts)
        guard headerRet >= 0 else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to write header: \(headerRet)")
        }

        // Feed a few real packets so EAC3 muxer can parse the bitstream.
        // Seek to start and read until we have at least one audio packet.
        avformat_seek_file(sourceCtx, -1, 0, 0, 0, 0)
        var initPkt = av_packet_alloc()
        guard let pkt = initPkt else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate init packet")
        }
        defer { av_packet_free(&initPkt) }

        var wroteVideo = false
        var wroteAudio = false
        let needAudio = audioStreamIndex >= 0

        for _ in 0..<200 {  // Read up to 200 packets to find one of each
            let readRet = av_read_frame(sourceCtx, pkt)
            if readRet < 0 { break }

            do {
                defer { av_packet_unref(pkt) }

                if pkt.pointee.stream_index == videoStreamIndex && !wroteVideo {
                    pkt.pointee.stream_index = 0
                    av_packet_rescale_ts(pkt, srcVideoStream.pointee.time_base, outVideoStream.pointee.time_base)
                    let writeRet = av_write_frame(outCtx, pkt)
                    if writeRet >= 0 {
                        wroteVideo = true
                    }
                } else if pkt.pointee.stream_index == audioStreamIndex && !wroteAudio {
                    let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
                    let dstAudioStream = outCtx.pointee.streams[1]!

                    if needsAudioTranscode {
                        // Transcode the audio packet (e.g., TrueHD → EAC3) so the
                        // muxer sees real EAC3 data for building the dec3 box.
                        let encodedPackets = transcodeAudioPacket(pkt, timebase: srcAudioStream.pointee.time_base)
                        if let first = encodedPackets.first {
                            // Cache the transcoded frame as primer for audio-less segments
                            cachedAudioPrimer = first.data

                            let bufSize = Int32(first.data.count)
                            if let packetBuf = av_malloc(Int(bufSize)) {
                                first.data.copyBytes(to: packetBuf.assumingMemoryBound(to: UInt8.self),
                                                     count: Int(bufSize))
                                var outPkt = av_packet_alloc()
                                if let fp = outPkt,
                                   av_packet_from_data(fp, packetBuf.assumingMemoryBound(to: UInt8.self), bufSize) >= 0 {
                                    fp.pointee.stream_index = 1
                                    fp.pointee.pts = first.pts
                                    fp.pointee.dts = first.pts
                                    fp.pointee.duration = first.duration
                                    av_packet_rescale_ts(fp, AVRational(num: 1, den: 48000),
                                                         dstAudioStream.pointee.time_base)
                                    let writeRet = av_write_frame(outCtx, fp)
                                    if writeRet >= 0 {
                                        wroteAudio = true
                                    }
                                } else {
                                    av_free(packetBuf)
                                }
                                av_packet_free(&outPkt)
                            }
                        }
                        // If transcoder didn't produce output yet, keep reading
                        if !wroteAudio { continue }
                    } else {
                        // Passthrough: cache raw frame and write directly
                        if let rawData = pkt.pointee.data, pkt.pointee.size > 0 {
                            cachedAudioPrimer = Data(bytes: rawData, count: Int(pkt.pointee.size))
                        }
                        pkt.pointee.stream_index = 1
                        av_packet_rescale_ts(pkt, srcAudioStream.pointee.time_base,
                                             dstAudioStream.pointee.time_base)
                        let writeRet = av_write_frame(outCtx, pkt)
                        if writeRet >= 0 {
                            wroteAudio = true
                        }
                    }
                }
            }

            if wroteVideo && (!needAudio || wroteAudio) { break }
        }

        guard wroteVideo else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.writeFailed("Unable to write video sample for init segment")
        }

        // Flush the fragment — this triggers moov + moof+mdat to be written
        avio_flush(outCtx.pointee.pb)
        av_write_frame(outCtx, nil)  // Flush interleaving queue
        avio_flush(outCtx.pointee.pb)

        av_write_trailer(outCtx)
        avio_flush(outCtx.pointee.pb)

        // Seek source back to start for future segment generation
        avformat_seek_file(sourceCtx, -1, 0, 0, 0, 0)

        // Clean up AVIO
        avio_context_free(&outCtx.pointee.pb)
        Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()

        return outputData
    }

    // MARK: - Private: Media Segment Writing

    private struct MediaSegmentResult {
        let data: Data
        let actualStartPTS: Int64
        let nextSegmentStartPTS: Int64?
    }

    /// Write an fMP4 media segment (moof+mdat) containing packets for the given segment.
    private func writeMediaSegment(
        sourceCtx: UnsafeMutablePointer<AVFormatContext>,
        segmentIndex: Int,
        startPTS: Int64,
        endPTS: Int64?
    ) throws -> MediaSegmentResult {
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
        let copyVideoRet = avcodec_parameters_copy(outVideoStream.pointee.codecpar, srcVideoStream.pointee.codecpar)
        guard copyVideoRet >= 0 else {
            throw RemuxError.muxerFailed("Failed to copy segment video codec params: \(copyVideoRet)")
        }
        outVideoStream.pointee.time_base = srcVideoStream.pointee.time_base
        outVideoStream.pointee.codecpar.pointee.codec_tag = 0

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
                let copyAudioRet = avcodec_parameters_copy(outAudioStream.pointee.codecpar, srcAudioStream.pointee.codecpar)
                guard copyAudioRet >= 0 else {
                    throw RemuxError.muxerFailed("Failed to copy segment audio codec params: \(copyAudioRet)")
                }
                outAudioStream.pointee.time_base = srcAudioStream.pointee.time_base
            }
            outAudioStream.pointee.codecpar.pointee.codec_tag = 0

            // EAC3/AC3 require frame_size set before header write
            let audioCodecId = outAudioStream.pointee.codecpar.pointee.codec_id
            if audioCodecId == AV_CODEC_ID_EAC3 || audioCodecId == AV_CODEC_ID_AC3 {
                outAudioStream.pointee.codecpar.pointee.frame_size = 1536
            }
        }

        // Set up in-memory I/O
        let bufferSize: Int = 65536
        guard let avioBuffer = av_malloc(bufferSize) else {
            throw RemuxError.muxerFailed("Failed to allocate segment AVIO buffer")
        }

        var outputData = Data()
        let writer = OutputWriter(target: &outputData)
        let opaquePtr = Unmanaged.passRetained(writer).toOpaque()

        guard let avioCtx = avio_alloc_context(
            avioBuffer.assumingMemoryBound(to: UInt8.self),
            Int32(bufferSize),
            1,
            opaquePtr,
            nil,
            { opaquePtr, buf, bufSize -> Int32 in
                guard let opaque = opaquePtr, let buf = buf, bufSize > 0 else { return 0 }
                let w = Unmanaged<OutputWriter>.fromOpaque(opaque).takeUnretainedValue()
                return w.write(buf, count: bufSize)
            },
            nil
        ) else {
            av_free(avioBuffer)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate segment AVIO context")
        }

        outCtx.pointee.pb = avioCtx
        outCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        // delay_moov: the EAC3/AC3 muxer needs to parse a real audio packet
        // before it can build the moov's dec3 box. We strip init boxes from
        // media segments afterwards (they only need moof+mdat).
        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "movflags", "frag_custom+delay_moov+default_base_moof+omit_tfhd_offset", 0)
        outCtx.pointee.strict_std_compliance = -2  // FF_COMPLIANCE_UNOFFICIAL

        let headerRet = avformat_write_header(outCtx, &opts)
        av_dict_free(&opts)
        guard headerRet >= 0 else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to write segment header: \(headerRet)")
        }

        // Read packets from source and write to output
        var pkt = av_packet_alloc()
        guard let packet = pkt else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.muxerFailed("Failed to allocate packet")
        }
        defer { av_packet_free(&pkt) }

        var videoPacketCount = 0
        var audioPacketCount = 0
        var foundFirstKeyframe = false
        var actualStartPTS: Int64?
        var nextSegmentStartPTS: Int64?
        var nextVideoDTS: Int64 = Int64.min
        var videoPTSShift: Int64 = 0  // Shift applied when PTS too small for depth offset
        var packetsScanned = 0

        while !isCancelled {
            packetsScanned += 1
            if packetsScanned > maxPacketsPerSegmentRead {
                break
            }
            let readRet = av_read_frame(sourceCtx, packet)
            if readRet < 0 { break }  // EOF or error

            do {
                defer { av_packet_unref(packet) }

                let streamIndex = packet.pointee.stream_index

                // Only process video and audio
                guard streamIndex == videoStreamIndex || streamIndex == audioStreamIndex else {
                    continue
                }

                if streamIndex == videoStreamIndex {
                    // Check if we've reached the next segment.
                    // Only break on a KEYFRAME past endPTS — non-keyframes (B/P-frames)
                    // with PTS >= endPTS may still belong to the current GOP. Breaking
                    // on a non-keyframe would lose trailing B-frames in decode order.
                    if let endPTS = endPTS, packet.pointee.pts >= endPTS,
                       (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                        if foundFirstKeyframe {
                            nextSegmentStartPTS = packet.pointee.pts
                            break
                        }
                    }

                    // Wait for the first keyframe at or after our start PTS.
                    if !foundFirstKeyframe {
                        if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 && packet.pointee.pts >= startPTS {
                            foundFirstKeyframe = true
                            actualStartPTS = packet.pointee.pts
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
                            let newSize = Int32(convertedData.count)
                            if let newBuf = av_malloc(Int(newSize)) {
                                convertedData.copyBytes(to: newBuf.assumingMemoryBound(to: UInt8.self),
                                                        count: Int(newSize))
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

                    av_packet_rescale_ts(packet,
                                         srcVideoStream.pointee.time_base,
                                         outVideoStream.pointee.time_base)

                    // Synthesize monotonic DTS. MKV demuxer produces non-monotonic
                    // DTS after seeking for B-frame content. We replace it with a
                    // strictly increasing linear counter. When cumulative rounding
                    // causes DTS to exceed PTS for B-frames, we bump PTS up instead
                    // of clamping DTS down — this preserves DTS monotonicity (the
                    // muxer hard-rejects non-monotonic DTS) at the cost of a
                    // sub-frame PTS shift that's imperceptible in playback.
                    let frameDur = packet.pointee.duration > 0 ? packet.pointee.duration : 1
                    if nextVideoDTS == Int64.min {
                        let depth = Int64(srcVideoStream.pointee.codecpar.pointee.video_delay)
                        let d = depth > 0 ? depth : 4
                        let neededRoom = d * frameDur
                        if packet.pointee.pts < neededRoom {
                            videoPTSShift = neededRoom
                        }
                        let shiftedPTS = packet.pointee.pts + videoPTSShift
                        nextVideoDTS = shiftedPTS - neededRoom
                    }
                    packet.pointee.pts += videoPTSShift
                    packet.pointee.dts = nextVideoDTS
                    // If DTS exceeds PTS (cumulative frameDur drift on B-frames),
                    // bump PTS up to match — keeps both constraints satisfied
                    if packet.pointee.pts < packet.pointee.dts {
                        packet.pointee.pts = packet.pointee.dts
                    }
                    nextVideoDTS += frameDur

                    let writeRet = av_write_frame(outCtx, packet)
                    if writeRet < 0 {
                        print("[RemuxSession] Warning: video write failed for segment \(segmentIndex): \(writeRet)")
                    }
                    videoPacketCount += 1

                } else if streamIndex == audioStreamIndex {
                    guard foundFirstKeyframe else { continue }

                    let audioPTS = av_rescale_q(packet.pointee.pts, audioTimebase, videoTimebase)
                    if let endPTS = endPTS, audioPTS >= endPTS {
                        continue
                    }

                    let outStreamIdx = (outAudioStreamIndex >= 0) ? outAudioStreamIndex : 1

                    if needsAudioTranscode {
                        let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
                        let encodedPackets = transcodeAudioPacket(packet, timebase: srcAudioStream.pointee.time_base)

                        for enc in encodedPackets {
                            let bufSize = Int32(enc.data.count)
                            guard let packetBuf = av_malloc(Int(bufSize)) else { continue }
                            enc.data.copyBytes(to: packetBuf.assumingMemoryBound(to: UInt8.self), count: Int(bufSize))

                            var outPkt = av_packet_alloc()
                            guard let fp = outPkt else {
                                av_free(packetBuf)
                                continue
                            }

                            let packetRet = av_packet_from_data(
                                fp,
                                packetBuf.assumingMemoryBound(to: UInt8.self),
                                bufSize
                            )
                            guard packetRet >= 0 else {
                                av_packet_free(&outPkt)
                                av_free(packetBuf)
                                continue
                            }

                            fp.pointee.stream_index = outStreamIdx
                            fp.pointee.pts = enc.pts
                            fp.pointee.dts = enc.pts
                            fp.pointee.duration = enc.duration

                            let dstAudioStream = outCtx.pointee.streams[Int(outStreamIdx)]!
                            av_packet_rescale_ts(fp,
                                                 AVRational(num: 1, den: 48000),
                                                 dstAudioStream.pointee.time_base)

                            let writeRet = av_write_frame(outCtx, fp)
                            if writeRet < 0 {
                                print("[RemuxSession] Warning: transcoded audio write failed for segment \(segmentIndex): \(writeRet)")
                            }
                            av_packet_free(&outPkt)
                            audioPacketCount += 1
                        }
                    } else {
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
        }

        guard !isCancelled else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.cancelled
        }

        guard foundFirstKeyframe else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.writeFailed("No keyframe found at/after start PTS for segment \(segmentIndex)")
        }

        guard videoPacketCount > 0 else {
            avio_context_free(&outCtx.pointee.pb)
            Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()
            throw RemuxError.writeFailed("No video packets written for segment \(segmentIndex)")
        }

        // If no audio was written, inject a cached primer packet so the EAC3/AC3
        // muxer can parse the bitstream and build the moov's dec3/dac3 box.
        // Without this, delay_moov fails for audio-less segments.
        if audioPacketCount == 0, let primer = cachedAudioPrimer, outAudioStreamIndex >= 0 {
            let bufSize = Int32(primer.count)
            if let packetBuf = av_malloc(Int(bufSize)) {
                primer.copyBytes(to: packetBuf.assumingMemoryBound(to: UInt8.self), count: Int(bufSize))
                var primerPkt = av_packet_alloc()
                if let pp = primerPkt {
                    if av_packet_from_data(pp, packetBuf.assumingMemoryBound(to: UInt8.self), bufSize) >= 0 {
                        pp.pointee.stream_index = outAudioStreamIndex
                        // Convert video startPTS to output audio timebase directly
                        let dstAudioStream = outCtx.pointee.streams[Int(outAudioStreamIndex)]!
                        let audioPTS = av_rescale_q(startPTS,
                                                     sourceCtx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base,
                                                     dstAudioStream.pointee.time_base)
                        pp.pointee.pts = audioPTS
                        pp.pointee.dts = audioPTS
                        pp.pointee.duration = 1536  // Standard EAC3 frame size
                        let primerWriteRet = av_write_frame(outCtx, pp)
                        if primerWriteRet < 0 {
                            print("[RemuxSession] Warning: audio primer write failed for segment \(segmentIndex): \(primerWriteRet)")
                        }
                    } else {
                        av_free(packetBuf)
                    }
                    av_packet_free(&primerPkt)
                }
            }
        }

        // Flush the muxer
        avio_flush(outCtx.pointee.pb)
        av_write_frame(outCtx, nil)  // Flush interleaving queue
        avio_flush(outCtx.pointee.pb)

        // Write trailer
        av_write_trailer(outCtx)
        avio_flush(outCtx.pointee.pb)

        // Clean up AVIO
        avio_context_free(&outCtx.pointee.pb)
        Unmanaged<OutputWriter>.fromOpaque(opaquePtr).release()

        // Strip ftyp/moov so each media segment only contains moof+mdat fragment data.
        let segmentData = stripMoovBox(from: outputData)
        guard isValidMediaFragment(segmentData) else {
            throw RemuxError.writeFailed("Invalid media fragment structure for segment \(segmentIndex)")
        }

        return MediaSegmentResult(
            data: segmentData,
            actualStartPTS: actualStartPTS ?? startPTS,
            nextSegmentStartPTS: nextSegmentStartPTS
        )
    }

    // MARK: - Private: fMP4 Box Parsing

    /// Extract only moof+mdat (and styp if present) from fMP4 output.
    /// Allowlist approach: only keep boxes that belong in an HLS media segment.
    /// Strips ftyp, moov (init-only), mfra (trailer), and anything else.
    private func stripMoovBox(from data: Data) -> Data {
        var result = Data()
        var offset = 0
        let allowedBoxes: Set<String> = ["styp", "moof", "mdat"]

        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""

            guard boxSize >= 8 && offset + boxSize <= data.count else { break }

            if allowedBoxes.contains(boxType) {
                result.append(data[offset..<offset+boxSize])
            }

            offset += boxSize
        }

        return result.isEmpty ? data : result
    }

    /// Extract only ftyp + moov boxes from fMP4 data (for init segment).
    /// With delay_moov, the output contains ftyp + moov + moof + mdat — we only want ftyp + moov.
    private func extractInitBoxes(from data: Data) -> Data {
        var result = Data()
        var offset = 0

        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""

            guard boxSize >= 8 && offset + boxSize <= data.count else { break }

            // Keep only ftyp and moov (init segment boxes)
            if boxType == "ftyp" || boxType == "moov" {
                result.append(data[offset..<offset+boxSize])
            }

            offset += boxSize
        }

        return result.isEmpty ? data : result
    }

    private func isValidInitSegment(_ data: Data) -> Bool {
        var sawFtyp = false
        var sawMoov = false
        for box in topLevelBoxes(in: data) {
            if box == "ftyp" { sawFtyp = true }
            if box == "moov" { sawMoov = true }
        }
        return sawFtyp && sawMoov
    }

    private func isValidMediaFragment(_ data: Data) -> Bool {
        var sawMoof = false
        var sawMdat = false
        for box in topLevelBoxes(in: data) {
            if box == "moof" { sawMoof = true }
            if box == "mdat" { sawMdat = true }
            // Media segments should not include init-only top-level boxes.
            if box == "moov" || box == "ftyp" {
                return false
            }
        }
        return sawMoof && sawMdat
    }

    private func topLevelBoxes(in data: Data) -> [String] {
        var boxes: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            guard boxSize >= 8, offset + boxSize <= data.count else { break }
            let boxType = String(data: data[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            boxes.append(boxType)
            offset += boxSize
        }
        return boxes
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

    // MARK: - Private: fMP4 Debug Logging

    /// Log the top-level (and one level nested) box structure of fMP4 data.
    private func logBoxStructure(data: Data, label: String) {
        var offset = 0
        var boxes: [String] = []

        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? "????"

            guard boxSize >= 8 && offset + boxSize <= data.count else {
                boxes.append("\(boxType)(\(boxSize)B TRUNCATED)")
                break
            }

            var detail = "\(boxType)(\(boxSize)B)"

            // For moov/moof, list child boxes one level deep
            if boxType == "moov" || boxType == "moof" {
                var childOffset = offset + 8
                var children: [String] = []
                while childOffset + 8 <= offset + boxSize {
                    let childSize = Int(data.loadBigEndianUInt32(at: childOffset))
                    let childType = String(data: data[childOffset+4..<childOffset+8], encoding: .ascii) ?? "????"
                    guard childSize >= 8 && childOffset + childSize <= offset + boxSize else { break }

                    // For trak/traf, go one more level
                    if childType == "trak" || childType == "traf" {
                        var gcOffset = childOffset + 8
                        var grandchildren: [String] = []
                        while gcOffset + 8 <= childOffset + childSize {
                            let gcSize = Int(data.loadBigEndianUInt32(at: gcOffset))
                            let gcType = String(data: data[gcOffset+4..<gcOffset+8], encoding: .ascii) ?? "????"
                            guard gcSize >= 8 && gcOffset + gcSize <= childOffset + childSize else { break }
                            grandchildren.append(gcType)
                            gcOffset += gcSize
                        }
                        children.append("\(childType)[\(grandchildren.joined(separator: ","))]")
                    } else {
                        children.append(childType)
                    }
                    childOffset += childSize
                }
                detail = "\(boxType)(\(boxSize)B: \(children.joined(separator: " ")))"
            }

            boxes.append(detail)
            offset += boxSize
        }

        print("[RemuxSession] [\(label)] boxes: \(boxes.joined(separator: " | "))")
    }

    // MARK: - Private: Helpers

    private func fourCC(_ string: String) -> UInt32 {
        let chars = Array(string.utf8)
        guard chars.count == 4 else { return 0 }
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }
}

// MARK: - AVIO Output Writer

/// Wrapper for AVIO write callbacks. Accumulates bytes in memory.
private final class OutputWriter {
    let dataPtr: UnsafeMutablePointer<Data>

    init(target: UnsafeMutablePointer<Data>) {
        self.dataPtr = target
    }

    /// Write bytes to the buffer. Returns number of bytes written.
    func write(_ buffer: UnsafePointer<UInt8>, count: Int32) -> Int32 {
        dataPtr.pointee.append(buffer, count: Int(count))
        return count
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
