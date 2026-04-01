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
    let hasKeyframeIndex: Bool
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

    // Sequential generation: skip expensive HTTP seeks for sequential segments.
    // After segment N, the format context is positioned near segment N+1's start.
    private var lastGeneratedSegmentIndex: Int = -1

    // DTS continuity across segments. Each segment's DTS must continue where
    // the previous segment ended, otherwise AVPlayer sees gaps/overlaps and stalls.
    // Reset to nil after seeks (non-sequential segments start fresh).
    private var continuationVideoDTS: Int64?
    private var continuationVideoPTSShift: Int64 = 0
    private var segmentsGenerated: Int = 0

    /// Actual duration of the last generated segment (in seconds).
    /// Used to update EXTINF durations in the playlist for timeline alignment.
    private(set) var lastSegmentActualDuration: TimeInterval?
    private(set) var lastSegmentIndex: Int?

    // Target segment duration in seconds
    private let targetSegmentDuration: TimeInterval = 6.0
    // Hard ceiling to avoid pathological scans on damaged/odd streams.
    private let maxPacketsPerSegmentRead = 60_000

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

    /// Shared interrupt flag for aborting in-progress FFmpeg I/O.
    /// Accessible outside the actor (nonisolated) so the server can signal
    /// cancellation immediately without waiting for actor serialization.
    /// Set to 1 to interrupt; cleared to 0 at the start of each generateSegment().
    nonisolated(unsafe) let interruptFlag: UnsafeMutablePointer<Int32> = {
        let ptr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        ptr.initialize(to: 0)
        return ptr
    }()

    deinit {
        if let ctx = formatContext {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }
        interruptFlag.deinitialize(count: 1)
        interruptFlag.deallocate()
    }

    // MARK: - Open

    /// Open a source URL, discover streams, and scan keyframes to build the segment list.
    func open(url: URL, headers: [String: String]? = nil) throws -> RemuxSessionInfo {
        guard !isOpen else { throw RemuxError.alreadyOpen }
        let openStart = Date()

        self.sourceURL = url
        self.sourceHeaders = headers

        // Allocate format context
        guard let ctx = avformat_alloc_context() else {
            throw RemuxError.openFailed("Failed to allocate format context")
        }

        // Wire up interrupt callback so stale I/O can be aborted from outside
        // the actor (e.g., when the server detects a seek and needs the actor
        // to stop generating a stale read-ahead segment immediately).
        ctx.pointee.interrupt_callback.callback = { opaquePtr -> Int32 in
            guard let ptr = opaquePtr?.assumingMemoryBound(to: Int32.self) else { return 0 }
            return ptr.pointee
        }
        ctx.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(interruptFlag)

        // Set up HTTP headers
        var options: OpaquePointer? = nil
        if let headers = headers, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
            av_dict_set(&options, "headers", headerString, 0)
            av_dict_set(&options, "reconnect", "1", 0)
            av_dict_set(&options, "reconnect_streamed", "1", 0)
            av_dict_set(&options, "reconnect_delay_max", "5", 0)
            av_dict_set(&options, "reconnect_on_network_error", "1", 0)
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
            print("[Remux] DV P7→P8.1 conversion enabled")
        }

        // Get duration
        if openCtx.pointee.duration > 0 {
            duration = Double(openCtx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // Build estimated segment list. The actual segment content may differ from
        // the estimated EXTINF durations, but AVPlayer uses the tfdt (baseMediaDecodeTime)
        // for timeline positioning, not EXTINF. With correct tfdt patching and sample
        // durations, playback is smooth despite EXTINF approximation.
        buildEstimatedSegmentList()
        let gotKeyframeIndex = false

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
            needsDVConversion: needsDVConversion,
            hasKeyframeIndex: gotKeyframeIndex
        )

        let openMs = Int(Date().timeIntervalSince(openStart) * 1000)
        print("[Remux] open: \(openMs)ms — \(videoCodecName) \(videoWidth)x\(videoHeight), audio=\(audioCodecName), " +
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

        // Log box structure for diagnostics
        let rawBoxes = topLevelBoxes(in: rawData).joined(separator: ", ")
        let initBoxes = topLevelBoxes(in: initData).joined(separator: ", ")
        let moovChildren = moovSubBoxes(in: initData)
        let codecTag = videoCodecTag()
        let tagStr = String(format: "%c%c%c%c",
                            codecTag & 0xFF, (codecTag >> 8) & 0xFF,
                            (codecTag >> 16) & 0xFF, (codecTag >> 24) & 0xFF)
        print("[Remux] Init segment: \(initData.count) bytes (raw \(rawData.count) bytes)")
        print("[Remux] Init boxes: [\(initBoxes)] moov=[\(moovChildren)] codecTag=\(tagStr)")
        return initData
    }

    // MARK: - Media Segment Generation

    /// Generate an fMP4 media segment (moof + mdat) for the given segment index.
    /// On network failure (stale connection after pause), automatically reconnects
    /// to the Plex server and retries once.
    func generateSegment(index: Int) throws -> Data {
        guard isOpen else { throw RemuxError.notOpen }
        guard index >= 0 && index < segments.count else {
            throw RemuxError.segmentOutOfRange(index)
        }
        guard !isCancelled && !Task.isCancelled else { throw RemuxError.cancelled }

        interruptFlag.pointee = 0

        do {
            return try performSegmentGeneration(index: index)
        } catch RemuxError.cancelled {
            throw RemuxError.cancelled
        } catch RemuxError.segmentOutOfRange {
            throw RemuxError.segmentOutOfRange(index)
        } catch {
            // Network errors after long pauses leave the format context dead.
            // Reopen the connection and retry once.
            guard !isCancelled && !Task.isCancelled else { throw RemuxError.cancelled }

            print("[Remux] Segment \(index) failed (\(error)), reconnecting...")
            try reopenFormatContext()
            interruptFlag.pointee = 0
            return try performSegmentGeneration(index: index)
        }
    }

    /// Core segment generation logic — seek to position and mux packets into fMP4.
    private func performSegmentGeneration(index: Int) throws -> Data {
        guard let ctx = formatContext else { throw RemuxError.notOpen }

        let generationStart = Date()
        let segment = segments[index]
        let startPTS = segment.startPTS
        let nextSegmentPTS: Int64? = (index + 1 < segments.count) ? segments[index + 1].startPTS : nil

        // For sequential segments, skip the expensive HTTP seek — the format context
        // is already positioned near this segment's start after the previous generation.
        // The foundFirstKeyframe logic will skip packets until the right keyframe.
        // Also skip for segment 0 on first generation — the format context is already
        // at position 0 after open() + init segment generation. Seeking + flushing
        // would just clear HTTP buffers and force an expensive re-fetch (~3-4s).
        let isSequential = (index == lastGeneratedSegmentIndex + 1) && lastGeneratedSegmentIndex >= 0
        let isFirstSegmentFromStart = index == 0 && lastGeneratedSegmentIndex == -1
        if !isSequential && !isFirstSegmentFromStart {
            let seekStart = Date()
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
                    print("[Remux] Seek failed for segment \(index): stream=\(streamSeekRet), global=\(globalSeekRet)")
                }
            }
            avformat_flush(ctx)
            let seekMs = Int(Date().timeIntervalSince(seekStart) * 1000)
            print("[Remux] Segment \(index) seek: \(seekMs)ms")
        }

        // Read packets for this segment and write to fMP4 fragment.
        // For sequential segments, carry over DTS from the previous segment
        // to ensure timeline continuity (prevents AVPlayer stalls at boundaries).
        let result = try writeMediaSegment(
            sourceCtx: ctx,
            segmentIndex: index,
            startPTS: startPTS,
            endPTS: nextSegmentPTS,
            continuationDTS: isSequential ? continuationVideoDTS : nil,
            continuationPTSShift: isSequential ? continuationVideoPTSShift : 0
        )
        let segmentData = result.data

        lastGeneratedSegmentIndex = index
        continuationVideoDTS = result.endVideoDTS
        continuationVideoPTSShift = result.videoPTSShift

        lastSegmentActualDuration = result.actualDuration
        lastSegmentIndex = index

        let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
        let seqLabel = isSequential ? " (seq)" : (isFirstSegmentFromStart ? " (first)" : "")
        let boxes = topLevelBoxes(in: segmentData).joined(separator: "+")
        print("[Remux] Segment \(index)\(seqLabel): \(segmentData.count) bytes [\(boxes)], " +
              "actualDur=\(String(format: "%.3f", lastSegmentActualDuration!))s, elapsed=\(elapsedMs)ms")

        // Log moof structure for first 3 segments generated to verify tfdt/duration
        if segmentsGenerated < 3 {
            logMoofStructure(segmentData, segmentIndex: index)
        }
        segmentsGenerated += 1

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
        lastGeneratedSegmentIndex = -1
        continuationVideoDTS = nil
        continuationVideoPTSShift = 0
        cachedInitSegment = nil
        cachedAudioPrimer = nil
        doviConverter = nil
        audioDecoder = nil
        audioEncoder = nil
        isCancelled = false
    }

    // MARK: - Reconnect

    /// Reopen the format context after a stale/dead connection.
    /// Preserves stream indices, codec state, and segment list — only the I/O
    /// connection is refreshed. Called automatically by generateSegment() on failure.
    private func reopenFormatContext() throws {
        guard let url = sourceURL else { throw RemuxError.notOpen }

        // Close old context
        if let ctx = formatContext {
            var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&mutableCtx)
        }
        formatContext = nil
        lastGeneratedSegmentIndex = -1
        continuationVideoDTS = nil
        continuationVideoPTSShift = 0

        // Allocate new context
        guard let ctx = avformat_alloc_context() else {
            throw RemuxError.openFailed("Failed to allocate format context for reconnect")
        }

        // Wire up interrupt callback
        ctx.pointee.interrupt_callback.callback = { opaquePtr -> Int32 in
            guard let ptr = opaquePtr?.assumingMemoryBound(to: Int32.self) else { return 0 }
            return ptr.pointee
        }
        ctx.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(interruptFlag)

        // Set up HTTP options (same as open())
        var options: OpaquePointer? = nil
        if let headers = sourceHeaders, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
            av_dict_set(&options, "headers", headerString, 0)
        }
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        av_dict_set(&options, "reconnect_delay_max", "5", 0)
        av_dict_set(&options, "reconnect_on_network_error", "1", 0)

        var mutableCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
        let ret = avformat_open_input(&mutableCtx, url.absoluteString, nil, &options)
        av_dict_free(&options)

        guard ret >= 0, let openCtx = mutableCtx else {
            throw RemuxError.openFailed("Reconnect failed: avformat_open_input returned \(ret)")
        }

        let findRet = avformat_find_stream_info(openCtx, nil)
        guard findRet >= 0 else {
            var closable: UnsafeMutablePointer<AVFormatContext>? = openCtx
            avformat_close_input(&closable)
            throw RemuxError.openFailed("Reconnect failed: avformat_find_stream_info returned \(findRet)")
        }

        self.formatContext = openCtx
        print("[Remux] Reconnected to source after stale connection")
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

        print("[Remux] Selected audio stream \(index): \(audioCodecName)")
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
            print("[Remux] Dolby Vision detected: profile=\(profile), bl_compat_id=\(blCompatId)")
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

        print("[Remux] Audio transcoder: \(audioCodecName) → EAC3 (\(srcChannels)ch → \(outChannels)ch)")
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

    /// Build segment list from duration using estimated time intervals.
    /// Segments are approximate — generateSegment() snaps to actual keyframes.
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
            // Skip tiny trailing segments — no keyframes exist in the last fraction
            // of a second, and they cause "No keyframe found" infinite retry loops.
            if segDuration < 1.0 && !result.isEmpty {
                // Extend the previous segment's duration instead
                result[result.count - 1] = RemuxSegmentInfo(
                    index: result[result.count - 1].index,
                    startPTS: result[result.count - 1].startPTS,
                    duration: result[result.count - 1].duration + segDuration,
                    bytePosition: -1
                )
                break
            }
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
        print("[Remux] Built \(segments.count) estimated segments (\(String(format: "%.1f", targetSegmentDuration))s each)")
    }

    /// Scan the first ~60 seconds of packets to find the keyframe interval,
    /// then build the segment list using that interval for accurate EXTINF.
    /// Returns true if keyframes were found.
    private func buildKeyframeSegmentList() -> Bool {
        guard let ctx = formatContext else { return false }

        let tbFactor = Double(videoTimebase.num) / Double(videoTimebase.den)
        guard tbFactor > 0 else { return false }

        // Scan first ~60s for keyframe positions
        let scanStart = Date()
        var keyframePTS: [Int64] = []
        var pkt = av_packet_alloc()
        guard let packet = pkt else { return false }
        defer { av_packet_free(&pkt) }

        let scanLimitPTS = Int64(60.0 / tbFactor)  // 60 seconds in timebase
        while av_read_frame(ctx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == videoStreamIndex else { continue }
            let pts = packet.pointee.pts != avNoPTSValue ? packet.pointee.pts : packet.pointee.dts
            guard pts != avNoPTSValue else { continue }

            if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                keyframePTS.append(pts)
            }
            if pts > scanLimitPTS && keyframePTS.count >= 4 { break }
        }

        // Seek back to start
        avformat_seek_file(ctx, videoStreamIndex, Int64.min, 0, 0, AVSEEK_FLAG_BACKWARD)
        avformat_flush(ctx)

        guard keyframePTS.count >= 2 else { return false }

        // Compute average keyframe interval
        var intervals: [Double] = []
        for i in 1..<keyframePTS.count {
            intervals.append(Double(keyframePTS[i] - keyframePTS[i-1]) * tbFactor)
        }
        let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        guard avgInterval > 0.1 else { return false }

        // Build segments using the detected keyframe interval, grouped to ~targetSegmentDuration
        let keyframesPerSegment = max(1, Int(round(targetSegmentDuration / avgInterval)))
        let segmentInterval = avgInterval * Double(keyframesPerSegment)

        var result: [RemuxSegmentInfo] = []
        var segIdx = 0
        var currentTime: TimeInterval = 0

        while currentTime < duration {
            let segDuration = min(segmentInterval, duration - currentTime)
            if segDuration < 0.5 && !result.isEmpty {
                result[result.count - 1] = RemuxSegmentInfo(
                    index: result[result.count - 1].index,
                    startPTS: result[result.count - 1].startPTS,
                    duration: result[result.count - 1].duration + segDuration,
                    bytePosition: -1
                )
                break
            }
            let startPTS = Int64(currentTime / tbFactor)
            result.append(RemuxSegmentInfo(
                index: segIdx,
                startPTS: startPTS,
                duration: segDuration,
                bytePosition: -1
            ))
            segIdx += 1
            currentTime += segmentInterval
        }

        guard !result.isEmpty else { return false }
        segments = result

        let scanMs = Int(Date().timeIntervalSince(scanStart) * 1000)
        print("[Remux] Built \(segments.count) segments from keyframe scan: " +
              "avgGOP=\(String(format: "%.2f", avgInterval))s, " +
              "segDur=\(String(format: "%.2f", segmentInterval))s, " +
              "scan=\(scanMs)ms (\(keyframePTS.count) keyframes found)")
        return true
    }

    /// Load keyframe index (no-op placeholder — scanning is done at open time now).
    func loadKeyframeIndex() -> Bool {
        return false
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

        // Apple HLS requires hvc1 (not hev1) for HEVC. FFmpeg defaults to hev1
        // when codec_tag=0, which causes AVPlayer to reject every video sample
        // with -12860 (kCMSampleBufferError_DataFailed). For DV, use dvh1 which
        // triggers AVPlayer's Dolby Vision decode pipeline.
        outVideoStream.pointee.codecpar.pointee.codec_tag = videoCodecTag()

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
            // AAC often arrives with unset frame_size when copied from source metadata.
            if outAudioStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_AAC,
               outAudioStream.pointee.codecpar.pointee.frame_size <= 0 {
                outAudioStream.pointee.codecpar.pointee.frame_size = 1024
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
                    if pkt.pointee.pts == avNoPTSValue {
                        pkt.pointee.pts = (pkt.pointee.dts != avNoPTSValue) ? pkt.pointee.dts : 0
                    }
                    if pkt.pointee.dts == avNoPTSValue {
                        pkt.pointee.dts = pkt.pointee.pts
                    }
                    if pkt.pointee.duration <= 0 {
                        pkt.pointee.duration = 1
                    }
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
                        if pkt.pointee.pts == avNoPTSValue {
                            pkt.pointee.pts = (pkt.pointee.dts != avNoPTSValue) ? pkt.pointee.dts : 0
                        }
                        if pkt.pointee.dts == avNoPTSValue {
                            pkt.pointee.dts = pkt.pointee.pts
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
        /// The DTS value the next segment should start at for continuity.
        let endVideoDTS: Int64
        /// The PTS shift applied in this segment (carry over for continuity).
        let videoPTSShift: Int64
        /// Actual segment duration in seconds (computed from output timebase).
        let actualDuration: TimeInterval
    }

    /// Write an fMP4 media segment (moof+mdat) containing packets for the given segment.
    /// - Parameter continuationDTS: If non-nil, start DTS here for timeline continuity with the previous segment.
    /// - Parameter continuationPTSShift: PTS shift from the previous segment (carry over for continuity).
    private func writeMediaSegment(
        sourceCtx: UnsafeMutablePointer<AVFormatContext>,
        segmentIndex: Int,
        startPTS: Int64,
        endPTS: Int64?,
        continuationDTS: Int64? = nil,
        continuationPTSShift: Int64 = 0
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
        outVideoStream.pointee.codecpar.pointee.codec_tag = videoCodecTag()

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
            if audioCodecId == AV_CODEC_ID_AAC, outAudioStream.pointee.codecpar.pointee.frame_size <= 0 {
                outAudioStream.pointee.codecpar.pointee.frame_size = 1024
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
        var firstWrittenVideoDTS: Int64 = 0
        var firstWrittenAudioDTS: Int64 = 0
        var audioPacketWritten = false
        var actualStartPTS: Int64?
        var nextSegmentStartPTS: Int64?
        // For sequential segments, carry over DTS from the previous segment to ensure
        // timeline continuity. AVPlayer expects baseMediaDecodeTime to be continuous
        // across segments — gaps cause stalls, overlaps cause drops.
        var nextVideoDTS: Int64 = continuationDTS ?? Int64.min
        var videoPTSShift: Int64 = continuationPTSShift
        var packetsScanned = 0

        while !isCancelled && !Task.isCancelled {
            packetsScanned += 1
            if packetsScanned > maxPacketsPerSegmentRead {
                break
            }
            let readRet = av_read_frame(sourceCtx, packet)
            if readRet < 0 { break }  // EOF, error, or interrupt

            // Re-check cancellation after potentially long-blocking network read.
            // The interrupt callback aborts av_read_frame quickly, but we also
            // check here for Task-level cancellation.
            if Task.isCancelled || interruptFlag.pointee != 0 { break }

            do {
                defer { av_packet_unref(packet) }

                let streamIndex = packet.pointee.stream_index

                // Only process video and audio
                guard streamIndex == videoStreamIndex || streamIndex == audioStreamIndex else {
                    continue
                }

                if streamIndex == videoStreamIndex {
                    let packetVideoPTS = packet.pointee.pts != avNoPTSValue
                        ? packet.pointee.pts
                        : packet.pointee.dts
                    guard packetVideoPTS != avNoPTSValue else { continue }

                    // Check if we've reached the next segment.
                    // Only break on a KEYFRAME past endPTS — non-keyframes (B/P-frames)
                    // with PTS >= endPTS may still belong to the current GOP. Breaking
                    // on a non-keyframe would lose trailing B-frames in decode order.
                    if let endPTS = endPTS, packetVideoPTS >= endPTS,
                       (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                        if foundFirstKeyframe {
                            nextSegmentStartPTS = packetVideoPTS
                            break
                        }
                    }

                    // Wait for the first keyframe at or after our start PTS.
                    if !foundFirstKeyframe {
                        if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 && packetVideoPTS >= startPTS {
                            foundFirstKeyframe = true
                            actualStartPTS = packetVideoPTS
                        } else {
                            continue
                        }
                    }

                    packet.pointee.pts = packetVideoPTS
                    if packet.pointee.dts == avNoPTSValue {
                        packet.pointee.dts = packet.pointee.pts
                    }
                    if packet.pointee.duration <= 0 {
                        packet.pointee.duration = 1
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
                    // Ensure the muxer writes a non-zero sample duration in the trun.
                    // Without this, rescaling turns small durations to 0 via integer
                    // division (e.g., 1 tick at 1/1000 → 0 ticks at 1/25).
                    packet.pointee.duration = frameDur

                    let writeRet = av_write_frame(outCtx, packet)
                    if writeRet < 0 {
                        print("[Remux] Warning: video write failed for segment \(segmentIndex): \(writeRet)")
                    }
                    if videoPacketCount == 0 {
                        firstWrittenVideoDTS = packet.pointee.dts
                    }
                    videoPacketCount += 1

                } else if streamIndex == audioStreamIndex {
                    guard foundFirstKeyframe else { continue }

                    let rawAudioPTS: Int64
                    if packet.pointee.pts != avNoPTSValue {
                        rawAudioPTS = packet.pointee.pts
                    } else if packet.pointee.dts != avNoPTSValue {
                        rawAudioPTS = packet.pointee.dts
                    } else {
                        continue
                    }
                    // Don't filter audio by endPTS — video reads to the actual keyframe
                    // (which can be far past the estimated endPTS). Audio must cover the
                    // same range as video. Audio naturally stops when the video loop
                    // breaks at the keyframe boundary.

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
                                print("[Remux] Warning: transcoded audio write failed for segment \(segmentIndex): \(writeRet)")
                            }
                            if !audioPacketWritten {
                                firstWrittenAudioDTS = fp.pointee.dts
                                audioPacketWritten = true
                            }
                            av_packet_free(&outPkt)
                            audioPacketCount += 1
                        }
                    } else {
                        if packet.pointee.pts == avNoPTSValue {
                            packet.pointee.pts = rawAudioPTS
                        }
                        if packet.pointee.dts == avNoPTSValue {
                            packet.pointee.dts = packet.pointee.pts
                        }
                        packet.pointee.stream_index = outStreamIdx

                        let srcAudioStream = sourceCtx.pointee.streams[Int(audioStreamIndex)]!
                        let dstAudioStream = outCtx.pointee.streams[Int(outStreamIdx)]!
                        av_packet_rescale_ts(packet,
                                             srcAudioStream.pointee.time_base,
                                             dstAudioStream.pointee.time_base)

                        let writeRet = av_write_frame(outCtx, packet)
                        if writeRet < 0 {
                            print("[Remux] Warning: audio write failed for segment \(segmentIndex): \(writeRet)")
                        }
                        if !audioPacketWritten {
                            firstWrittenAudioDTS = packet.pointee.dts
                            audioPacketWritten = true
                        }
                        audioPacketCount += 1
                    }
                }
            }
        }

        guard !isCancelled && !Task.isCancelled else {
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
                            print("[Remux] Warning: audio primer write failed for segment \(segmentIndex): \(primerWriteRet)")
                        }
                        if !audioPacketWritten {
                            firstWrittenAudioDTS = pp.pointee.dts
                            audioPacketWritten = true
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
        var segmentData = stripMoovBox(from: outputData)
        guard isValidMediaFragment(segmentData) else {
            throw RemuxError.writeFailed("Invalid media fragment structure for segment \(segmentIndex)")
        }

        // Patch both tracks' tfdt with actual baseMediaDecodeTime values.
        // delay_moov normalizes all timestamps to start at 0 for each muxer context,
        // so the tfdt is always 0. We overwrite with correct DTS values
        // to ensure timeline continuity across segments for both A/V tracks.
        patchTfdt(in: &segmentData,
                  videoBaseDecodeTime: firstWrittenVideoDTS,
                  audioBaseDecodeTime: firstWrittenAudioDTS)

        // Compute actual duration using the OUTPUT timebase (which the muxer may
        // have changed from the source timebase during avformat_write_header).
        let outTB = outVideoStream.pointee.time_base
        let dtsTicks = nextVideoDTS - firstWrittenVideoDTS
        let segActualDuration = Double(dtsTicks) * Double(outTB.num) / Double(outTB.den)

        return MediaSegmentResult(
            data: segmentData,
            actualStartPTS: actualStartPTS ?? startPTS,
            nextSegmentStartPTS: nextSegmentStartPTS,
            endVideoDTS: nextVideoDTS,
            videoPTSShift: videoPTSShift,
            actualDuration: segActualDuration > 0 ? segActualDuration : 6.0
        )
    }

    // MARK: - Private: Codec Tag

    /// Returns the correct mp4 codec tag for the video stream.
    /// Apple HLS requires `hvc1` for HEVC (not FFmpeg's default `hev1`).
    /// Dolby Vision content uses `dvh1` to trigger AVPlayer's DV pipeline.
    private func videoCodecTag() -> UInt32 {
        // MKTAG('a','v','c','1') = 0x31637661
        // MKTAG('h','v','c','1') = 0x31637668
        // MKTAG('d','v','h','1') = 0x31687664
        if hasDolbyVision {
            return 0x31687664  // dvh1
        } else if videoCodecId == AV_CODEC_ID_HEVC {
            return 0x31637668  // hvc1
        } else if videoCodecId == AV_CODEC_ID_H264 {
            return 0x31637661  // avc1
        } else {
            return 0  // Let muxer choose
        }
    }

    // MARK: - Private: fMP4 Box Parsing

    /// List direct children of the moov box (mvhd, trak, mvex, etc.)
    private func moovSubBoxes(in data: Data) -> String {
        var offset = 0
        // Find moov box
        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            guard boxSize >= 8 && offset + boxSize <= data.count else { break }
            if boxType == "moov" {
                // Parse children of moov
                var children: [String] = []
                var childOffset = offset + 8
                let moovEnd = offset + boxSize
                while childOffset + 8 <= moovEnd {
                    let childSize = Int(data.loadBigEndianUInt32(at: childOffset))
                    let childType = String(data: data[childOffset+4..<childOffset+8], encoding: .ascii) ?? ""
                    guard childSize >= 8 && childOffset + childSize <= moovEnd else { break }
                    children.append(childType)
                    childOffset += childSize
                }
                return children.joined(separator: ", ")
            }
            offset += boxSize
        }
        return "moov not found"
    }

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

    // MARK: - Private: tfdt Patching

    /// Patch all tracks' baseMediaDecodeTime (tfdt) in a moof+mdat fragment.
    /// delay_moov normalizes timestamps to start at 0 for each muxer context,
    /// so we overwrite the tfdt with the actual DTS for timeline continuity.
    private func patchTfdt(in data: inout Data, videoBaseDecodeTime: Int64, audioBaseDecodeTime: Int64) {
        var offset = 0
        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            guard boxSize >= 8 && offset + boxSize <= data.count else { break }

            if boxType == "moof" {
                var trafOffset = offset + 8
                let moofEnd = offset + boxSize
                var trackIdx = 0
                while trafOffset + 8 <= moofEnd {
                    let trafSize = Int(data.loadBigEndianUInt32(at: trafOffset))
                    let trafType = String(data: data[trafOffset+4..<trafOffset+8], encoding: .ascii) ?? ""
                    guard trafSize >= 8 && trafOffset + trafSize <= moofEnd else { break }

                    if trafType == "traf" {
                        let baseTime = trackIdx == 0 ? videoBaseDecodeTime : audioBaseDecodeTime
                        patchTfdtInTraf(in: &data, trafOffset: trafOffset, trafSize: trafSize, baseDecodeTime: baseTime)
                        trackIdx += 1
                    }
                    trafOffset += trafSize
                }
            }
            offset += boxSize
        }
    }

    private func patchTfdtInTraf(in data: inout Data, trafOffset: Int, trafSize: Int, baseDecodeTime: Int64) {
        var childOffset = trafOffset + 8
        let trafEnd = trafOffset + trafSize
        while childOffset + 8 <= trafEnd {
            let childSize = Int(data.loadBigEndianUInt32(at: childOffset))
            let childType = String(data: data[childOffset+4..<childOffset+8], encoding: .ascii) ?? ""
            guard childSize >= 8 && childOffset + childSize <= trafEnd else { break }

            if childType == "tfdt" {
                let version = data[childOffset + 8]
                if version == 1 && childSize >= 20 {
                    let val = UInt64(bitPattern: baseDecodeTime)
                    for i in 0..<8 {
                        data[childOffset + 12 + i] = UInt8((val >> ((7 - i) * 8)) & 0xFF)
                    }
                } else if childSize >= 16 {
                    let val = UInt32(truncatingIfNeeded: baseDecodeTime)
                    for i in 0..<4 {
                        data[childOffset + 12 + i] = UInt8((val >> ((3 - i) * 8)) & 0xFF)
                    }
                }
                return
            }
            childOffset += childSize
        }
    }

    // MARK: - Private: fMP4 Diagnostics

    /// Parse and log the moof structure of an fMP4 segment for debugging.
    /// Logs baseMediaDecodeTime, sample count, and duration info per track.
    private func logMoofStructure(_ data: Data, segmentIndex: Int) {
        var offset = 0
        while offset + 8 <= data.count {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            guard boxSize >= 8 && offset + boxSize <= data.count else { break }

            if boxType == "moof" {
                parseMoof(data, moofOffset: offset, moofSize: boxSize, segmentIndex: segmentIndex)
            }
            offset += boxSize
        }
    }

    private func parseMoof(_ data: Data, moofOffset: Int, moofSize: Int, segmentIndex: Int) {
        var offset = moofOffset + 8
        let moofEnd = moofOffset + moofSize
        var trackIdx = 0

        while offset + 8 <= moofEnd {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            guard boxSize >= 8 && offset + boxSize <= moofEnd else { break }

            if boxType == "traf" {
                parseTraf(data, trafOffset: offset, trafSize: boxSize, segmentIndex: segmentIndex, trackIdx: trackIdx)
                trackIdx += 1
            }
            offset += boxSize
        }
    }

    private func parseTraf(_ data: Data, trafOffset: Int, trafSize: Int, segmentIndex: Int, trackIdx: Int) {
        var offset = trafOffset + 8
        let trafEnd = trafOffset + trafSize
        var baseDecodeTime: UInt64 = 0
        var sampleCount: UInt32 = 0
        var firstSampleDur: UInt32 = 0
        var trackId: UInt32 = 0

        while offset + 8 <= trafEnd {
            let boxSize = Int(data.loadBigEndianUInt32(at: offset))
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            guard boxSize >= 8 && offset + boxSize <= trafEnd else { break }

            if boxType == "tfhd" && boxSize >= 16 {
                // version(1) + flags(3) + track_id(4)
                trackId = data.loadBigEndianUInt32(at: offset + 12)
            } else if boxType == "tfdt" && boxSize >= 16 {
                let version = data[offset + 8]
                if version == 1 && boxSize >= 20 {
                    baseDecodeTime = data.loadBigEndianUInt64(at: offset + 12)
                } else {
                    baseDecodeTime = UInt64(data.loadBigEndianUInt32(at: offset + 12))
                }
            } else if boxType == "trun" && boxSize >= 12 {
                let flags = UInt32(data[offset + 9]) << 16 | UInt32(data[offset + 10]) << 8 | UInt32(data[offset + 11])
                sampleCount = data.loadBigEndianUInt32(at: offset + 12)
                // If sample-duration-present flag (0x100), read first sample duration
                if flags & 0x100 != 0 {
                    var sampleOffset = offset + 16
                    // Skip data-offset if present (flag 0x1)
                    if flags & 0x1 != 0 { sampleOffset += 4 }
                    // Skip first-sample-flags if present (flag 0x4)
                    if flags & 0x4 != 0 { sampleOffset += 4 }
                    if sampleOffset + 4 <= offset + boxSize {
                        firstSampleDur = data.loadBigEndianUInt32(at: sampleOffset)
                    }
                }
            }
            offset += boxSize
        }

        let trackLabel = trackIdx == 0 ? "video" : "audio"
        print("[Remux] Seg\(segmentIndex) \(trackLabel): tfdt=\(baseDecodeTime) samples=\(sampleCount) firstDur=\(firstSampleDur) trackId=\(trackId)")
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

        print("[Remux] [\(label)] boxes: \(boxes.joined(separator: " | "))")
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

    func loadBigEndianUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return withUnsafeBytes { buf in
            let ptr = buf.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt64(ptr[0]) << 56 | UInt64(ptr[1]) << 48 | UInt64(ptr[2]) << 40 | UInt64(ptr[3]) << 32 |
                   UInt64(ptr[4]) << 24 | UInt64(ptr[5]) << 16 | UInt64(ptr[6]) << 8 | UInt64(ptr[7])
        }
    }
}

// MARK: - AVSEEK_FLAG constants

private let AVSEEK_FLAG_BACKWARD: Int32 = 1
private let AVSEEK_FLAG_BYTE: Int32 = 2
private let avNoPTSValue: Int64 = Int64.min

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
    let hasKeyframeIndex: Bool
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
    private(set) var lastSegmentActualDuration: TimeInterval?
    private(set) var lastSegmentIndex: Int?

    nonisolated(unsafe) let interruptFlag: UnsafeMutablePointer<Int32> = {
        let ptr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        ptr.initialize(to: 0)
        return ptr
    }()

    deinit { interruptFlag.deinitialize(count: 1); interruptFlag.deallocate() }

    func open(url: URL, headers: [String: String]? = nil) throws -> RemuxSessionInfo {
        throw RemuxError.openFailed("FFmpeg not available")
    }

    func generateInitSegment() throws -> Data {
        throw RemuxError.notOpen
    }

    func generateSegment(index: Int) throws -> Data {
        throw RemuxError.notOpen
    }

    func loadKeyframeIndex() -> Bool { return false }
    func cancel() {}
    func close() {}
    func selectAudioStream(index: Int32) throws {
        throw RemuxError.notOpen
    }
}

#endif
