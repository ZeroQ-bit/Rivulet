//
//  DirectPlayPipeline.swift
//  Rivulet
//
//  Direct play pipeline using FFmpeg libavformat for container demuxing.
//  Opens raw media files (MKV, MP4, etc.) and feeds compressed packets
//  to SampleBufferRenderer via CMSampleBuffers.
//
//  Supports HEVC, H.264, Dolby Vision (with RPU conversion for P7/P8.6),
//  HDR10, HLG, and SDR content.
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import Sentry

/// Pipeline state for tracking lifecycle
enum PipelineState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case running
    case paused
    case seeking
    case ended
    case failed(String) // Error message (Equatable-friendly)

    static func == (lhs: PipelineState, rhs: PipelineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready),
             (.running, .running), (.paused, .paused), (.seeking, .seeking),
             (.ended, .ended):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Backpressure gate for queued audio sample buffers.
/// Read loop increments pending count when yielding a buffer;
/// audio enqueue task decrements after renderer enqueue completes.
private final class AudioBufferGate: @unchecked Sendable {
    nonisolated(unsafe) var pending = 0
    nonisolated(unsafe) var dropped = 0
    nonisolated(unsafe) var maxPending = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }
}

/// Direct play pipeline: FFmpegDemuxer → CMSampleBuffer → SampleBufferRenderer
@MainActor
final class DirectPlayPipeline {

    // MARK: - Dependencies

    private let renderer: SampleBufferRenderer
    let demuxer = FFmpegDemuxer()

    // MARK: - DV Processing

    private var profileConverter: DoviProfileConverter?
    private var requiresProfileConversion = false

    // MARK: - Client-Side Audio Decoding

    private var audioDecoder: FFmpegAudioDecoder?

    // MARK: - Client-Side Subtitle Decoding (PGS, DVB-SUB)

    private var subtitleDecoder: FFmpegSubtitleDecoder?
    private var bitmapCueCounter = 0

    // MARK: - State

    private(set) var state: PipelineState = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0

    private var readTask: Task<Void, Never>?
    private var audioEnqueueTask: Task<Void, Never>?
    private var isPlaying = false
    private var playbackRate: Float = 1.0
    private var needsInitialSync = false
    private var needsRateRestoreAfterSeek = false
    private var streamURL: URL?
    private var lastRequestedSeekTime: TimeInterval = -1
    private var lastSeekWallTime: CFAbsoluteTime = 0
    private var previousMaxVideoLookahead: TimeInterval?

    // MARK: - Callbacks

    /// Called when playback state changes
    var onStateChange: ((PipelineState) -> Void)?
    /// Called when an error occurs
    var onError: ((Error) -> Void)?
    /// Called when end of stream is reached
    var onEndOfStream: (() -> Void)?
    /// Called with subtitle text, start time, and end time from embedded subtitle packets
    var onSubtitleCue: ((String, TimeInterval, TimeInterval) -> Void)?
    /// Called with bitmap subtitle cues (PGS, DVB-SUB) from embedded subtitle packets
    var onBitmapSubtitleCue: ((BitmapSubtitleCue) -> Void)?

    // MARK: - Track Info

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []

    // MARK: - Init

    init(renderer: SampleBufferRenderer) {
        self.renderer = renderer
    }

    // MARK: - Load

    /// Open a media file for direct playback.
    /// - Parameters:
    ///   - url: Direct play URL (raw file URL from Plex server)
    ///   - headers: HTTP headers including Plex auth token
    ///   - startTime: Optional resume position in seconds
    ///   - isDolbyVision: Whether Plex metadata indicates this is DV content.
    ///     Forces dvh1 format description even if FFmpeg doesn't detect DOVI config.
    ///   - enableDVConversion: Enable DV P7/P8.6 → P8.1 conversion
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool = false) async throws {
        state = .loading
        onStateChange?(.loading)
        self.streamURL = url

        if previousMaxVideoLookahead == nil {
            previousMaxVideoLookahead = renderer.maxVideoLookahead
        }
        // DV content needs larger lookahead because VideoToolbox's DV decoder has
        // variable processing time, causing bursty isReadyForMoreMediaData waits.
        // Conversion sessions need the most buffer; non-conversion DV still needs
        // more than plain HEVC to absorb 200-300ms decode stalls.
        if enableDVConversion {
            renderer.maxVideoLookahead = 1.2
        } else if isDolbyVision {
            renderer.maxVideoLookahead = 0.6
        } else {
            renderer.maxVideoLookahead = 0.35
        }
        print("[DirectPlay] Renderer lookahead set to \(String(format: "%.1f", renderer.maxVideoLookahead))s")

        print("[DirectPlay] Loading: \(url.lastPathComponent) (DV=\(isDolbyVision), conversion=\(enableDVConversion))")

        // Open the container with FFmpeg
        try demuxer.open(url: url, headers: headers, forceDolbyVision: isDolbyVision)

        self.duration = demuxer.duration

        let audioTracksSummary = demuxer.audioTracks.map { t in
            "\(t.codecName) \(t.channels)ch [stream \(t.streamIndex)]"
        }.joined(separator: ", ")
        let selectedAudioDesc = demuxer.audioTracks
            .first(where: { $0.streamIndex == demuxer.selectedAudioStream })
            .map { "\($0.codecName) \($0.channelLayout ?? "\($0.channels)ch")" } ?? "none"

        print("[DirectPlay] Opened: duration=\(String(format: "%.1f", duration))s, " +
              "video=\(demuxer.videoTracks.first?.codecName ?? "none") " +
              "\(demuxer.videoTracks.first.map { "\($0.width)x\($0.height)" } ?? ""), " +
              "audio=\(selectedAudioDesc) (selected=\(demuxer.selectedAudioStream)), " +
              "audioTracks=[\(audioTracksSummary)], " +
              "DV=\(demuxer.hasDolbyVision) profile=\(demuxer.dvProfile.map(String.init) ?? "none") " +
              "level=\(demuxer.dvLevel.map(String.init) ?? "none") blCompat=\(demuxer.dvBLCompatID.map(String.init) ?? "none"), " +
              "videoFD=\(demuxer.videoFormatDescription != nil), " +
              "audioFD=\(demuxer.audioFormatDescription != nil)")

        // Set up DV processing if needed
        if demuxer.hasDolbyVision && enableDVConversion {
            requiresProfileConversion = true
            profileConverter = DoviProfileConverter()
            print("[DirectPlay] DV profile conversion enabled (P7/P8.6 → P8.1)")
        }

        // Set up audio path.
        // For DV conversion sessions, prefer a native passthrough track (AC3/EAC3/AAC...)
        // to keep read-loop throughput high and avoid TrueHD software decode bottlenecks.
        var selectedAudioTrack = demuxer.audioTracks.first(where: {
            $0.streamIndex == demuxer.selectedAudioStream
        })

        if demuxer.hasDolbyVision,
           let current = selectedAudioTrack,
           codecNeedsClientDecode(current.codecName),
           let nativeFallback = preferredNativeAudioTrack(preferredLanguage: current.language) {
            do {
                try demuxer.selectAudioStream(index: nativeFallback.streamIndex)
                selectedAudioTrack = nativeFallback
                audioDecoder?.close()
                audioDecoder = nil
                let reason = enableDVConversion ? "DV conversion mode" : "DV direct play mode"
                print("[DirectPlay] \(reason): switched audio stream \(current.streamIndex) " +
                      "(\(current.codecName) \(current.channels)ch) → \(nativeFallback.streamIndex) " +
                      "(\(nativeFallback.codecName) \(nativeFallback.channels)ch) to preserve throughput")
            } catch {
                print("[DirectPlay] Failed to switch to native DV audio fallback: \(error)")
            }
        }

        if let selectedAudioTrack, codecNeedsClientDecode(selectedAudioTrack.codecName) {
            do {
                // TrueHD/DTS has no CoreAudio format id in demuxer path.
                try demuxer.selectAudioStreamForClientDecode(index: selectedAudioTrack.streamIndex)
            } catch {
                print("[DirectPlay] Failed to select client-decode stream \(selectedAudioTrack.streamIndex): \(error)")
            }

            if let codecpar = demuxer.codecParameters(forStream: selectedAudioTrack.streamIndex) {
                do {
                    audioDecoder = try FFmpegAudioDecoder(
                        codecpar: codecpar,
                        codecNameHint: selectedAudioTrack.codecName
                    )
                    print("[DirectPlay] Client-side audio decoding enabled for " +
                          "\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch")
                } catch {
                    print("[DirectPlay] Failed to init audio decoder for " +
                          "\(selectedAudioTrack.codecName): \(error) — falling back to passthrough")
                    audioDecoder = nil
                }
            }
        } else if let selectedAudioTrack,
                  let clientDecodeTrack = demuxer.audioTracks.first(where: { codecNeedsClientDecode($0.codecName) }) {
            print("[DirectPlay] Keeping native audio stream \(selectedAudioTrack.streamIndex) " +
                  "(\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch); " +
                  "not auto-switching to software-decoded \(clientDecodeTrack.codecName)")
        }

        // Populate track info
        populateTrackInfo()

        // Handle start time
        if let startTime = startTime, startTime > 0 {
            try demuxer.seek(to: startTime)
            needsInitialSync = true
            print("[DirectPlay] Seeking to start time: \(String(format: "%.1f", startTime))s")
        }

        state = .ready
        onStateChange?(.ready)
        print("[DirectPlay] Ready")

        // Log session info
        let breadcrumb = Breadcrumb(level: .info, category: "direct_play")
        breadcrumb.message = "DirectPlay Load"
        breadcrumb.data = [
            "stream_url": url.absoluteString,
            "stream_host": url.host ?? "unknown",
            "duration": duration,
            "has_dv": demuxer.hasDolbyVision,
            "dv_profile": demuxer.dvProfile as Any,
            "video_tracks": demuxer.videoTracks.count,
            "audio_tracks": demuxer.audioTracks.count,
            "subtitle_tracks": demuxer.subtitleTracks.count,
            "dv_conversion": enableDVConversion
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // MARK: - Playback Control

    func start(rate: Float = 1.0) {
        guard state == .ready || state == .paused else {
            print("[DirectPlay] start() ignored — state is \(state)")
            return
        }

        let isResume = (state == .paused && readTask != nil)
        isPlaying = true
        playbackRate = rate
        state = .running
        onStateChange?(.running)

        if isResume {
            // Resume: read loop is already running and blocked on pacing (rate=0).
            // Just set the rate so the synchronizer advances and pacing unblocks.
            renderer.setRate(rate)
            print("[DirectPlay] resume (rate=\(rate))")
        } else {
            // Fresh start: sync to first video frame's PTS
            needsInitialSync = true
            print("[DirectPlay] start(rate=\(rate))")
            startReadLoop()
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        renderer.setRate(0)
        state = .paused
        onStateChange?(.paused)
        print("[DirectPlay] paused")
    }

    func resume() {
        guard !isPlaying, state == .paused else { return }
        isPlaying = true
        state = .running
        onStateChange?(.running)

        if readTask == nil {
            // Read loop exited after a paused seek (only a preview frame was shown).
            // Restart it with preroll so buffers refill before the clock starts.
            print("[DirectPlay] resume: read loop was dead, restarting with preroll")
            needsRateRestoreAfterSeek = true
            startReadLoop()
        } else {
            print("[DirectPlay] resume (rate=\(playbackRate))")
            renderer.setRate(playbackRate)
        }
    }

    func stop() {
        isPlaying = false
        audioEnqueueTask?.cancel()
        audioEnqueueTask = nil
        readTask?.cancel()
        readTask = nil
        audioDecoder?.close()
        audioDecoder = nil
        subtitleDecoder?.close()
        subtitleDecoder = nil
        demuxer.close()
        if let previousMaxVideoLookahead {
            renderer.maxVideoLookahead = previousMaxVideoLookahead
            self.previousMaxVideoLookahead = nil
        }
        state = .idle
        onStateChange?(.idle)
    }

    /// Enable embedded subtitle extraction for a specific FFmpeg stream index.
    /// Subtitle packets will be delivered via the `onSubtitleCue` or `onBitmapSubtitleCue` callback.
    func selectSubtitleStream(ffmpegStreamIndex: Int32) {
        // Close any previous bitmap decoder
        subtitleDecoder?.close()
        subtitleDecoder = nil

        // Check if this stream is a bitmap subtitle codec (PGS, DVB-SUB, etc.)
        if let trackInfo = demuxer.subtitleTracks.first(where: { $0.streamIndex == ffmpegStreamIndex }) {
            let codec = trackInfo.codecName.lowercased()
            if FFmpegSubtitleDecoder.supportedCodecs.contains(codec) {
                // Open bitmap subtitle decoder
                if let codecpar = demuxer.codecParameters(forStream: ffmpegStreamIndex) {
                    do {
                        subtitleDecoder = try FFmpegSubtitleDecoder(codecpar: codecpar)
                        bitmapCueCounter = 0
                        print("[DirectPlay] Bitmap subtitle decoder opened for stream \(ffmpegStreamIndex) (\(codec))")
                    } catch {
                        print("[DirectPlay] Failed to open bitmap subtitle decoder: \(error)")
                    }
                }
            }
        }

        demuxer.selectSubtitleStream(index: ffmpegStreamIndex)
        print("[DirectPlay] Subtitle stream selected: FFmpeg index \(ffmpegStreamIndex)")
    }

    /// Disable subtitle stream reading.
    func deselectSubtitleStream() {
        subtitleDecoder?.close()
        subtitleDecoder = nil
        demuxer.selectSubtitleStream(index: -1)
    }

    // MARK: - Seek

    func seek(to time: TimeInterval, isPlaying: Bool) async throws {
        let now = CFAbsoluteTimeGetCurrent()
        let currentTime = renderer.currentTime
        let deltaFromCurrent = abs(time - currentTime)
        let deltaFromLastRequest = lastRequestedSeekTime >= 0 ? abs(time - lastRequestedSeekTime) : .infinity

        // Drop noisy duplicate seek requests that arrive back-to-back with nearly identical targets.
        if now - lastSeekWallTime < 0.2 && deltaFromLastRequest < 0.25 {
            print("[DirectPlay] seek deduped: Δ=\(String(format: "%.0f", deltaFromLastRequest * 1000))ms from last request")
            return
        }
        // Ignore tiny seeks near current position to avoid unnecessary read-loop churn.
        if deltaFromCurrent < 0.20 {
            print("[DirectPlay] seek ignored: Δ=\(String(format: "%.0f", deltaFromCurrent * 1000))ms from current (too small)")
            return
        }

        lastSeekWallTime = now
        lastRequestedSeekTime = time
        print(
            "[DirectPlay] seek request: from=\(String(format: "%.3f", currentTime))s " +
            "to=\(String(format: "%.3f", time))s playing=\(isPlaying)"
        )

        state = .seeking
        renderer.jitterStats.reset()

        // Cancel current read loop
        audioEnqueueTask?.cancel()
        let oldAudioTask = audioEnqueueTask
        audioEnqueueTask = nil
        readTask?.cancel()
        let oldTask = readTask
        readTask = nil
        await oldAudioTask?.value
        await oldTask?.value

        // Flush renderer buffers and discard any batched audio
        renderer.flush()
        _ = audioDecoder?.flushBatch()

        // Seek in demuxer
        try demuxer.seek(to: time)

        // Set synchronizer time, paused
        let targetCMTime = CMTime(seconds: time, preferredTimescale: 90000)
        renderer.setRate(0, time: targetCMTime)

        self.isPlaying = isPlaying
        needsInitialSync = false
        needsRateRestoreAfterSeek = isPlaying

        // Restart reading
        startReadLoop()
    }

    // MARK: - Audio Track Selection

    func selectAudioTrack(streamIndex: Int32) async throws {
        guard let track = demuxer.audioTracks.first(where: { $0.streamIndex == streamIndex }) else {
            throw FFmpegError.invalidStream
        }

        print("[DirectPlay] Switching audio to stream \(streamIndex) (\(track.codecName) \(track.channels)ch)")

        // Pause the sync clock so it doesn't advance while the read loop is stopped.
        // Without this, the clock drifts ahead during the restart gap, causing a
        // cascade of "late video" frames when the new loop starts.
        renderer.setRate(0)

        // Stop the read loop — it captures audioDecoder/audioFD at startup,
        // so we must restart it to pick up the new decoder configuration.
        audioEnqueueTask?.cancel()
        let oldAudioTask = audioEnqueueTask
        audioEnqueueTask = nil
        readTask?.cancel()
        let oldTask = readTask
        readTask = nil
        await oldAudioTask?.value
        await oldTask?.value

        // Flush audio renderer and decoder
        renderer.audioRenderer.flush()
        _ = audioDecoder?.flushBatch()

        if codecNeedsClientDecode(track.codecName) {
            print("[DirectPlay] Audio switch: \(track.codecName) → client decode path")
            try demuxer.selectAudioStreamForClientDecode(index: streamIndex)
            guard let codecpar = demuxer.codecParameters(forStream: streamIndex) else {
                throw FFmpegError.noCodecParameters
            }
            audioDecoder?.close()
            audioDecoder = try FFmpegAudioDecoder(
                codecpar: codecpar,
                codecNameHint: track.codecName
            )
        } else {
            print("[DirectPlay] Audio switch: \(track.codecName) → passthrough path")
            audioDecoder?.close()
            audioDecoder = nil
            try demuxer.selectAudioStream(index: streamIndex)
        }

        // Restart read loop with preroll — the display layer's lookahead was
        // partially drained during the restart gap, so we must rebuild video
        // lead before resuming the clock. Without preroll, the clock runs ahead
        // of the empty buffer and every frame arrives "late".
        print("[DirectPlay] Audio switch complete, restarting read loop")
        needsRateRestoreAfterSeek = isPlaying
        startReadLoop()
    }

    // MARK: - Private: Read Loop

    private func startReadLoop() {
        audioEnqueueTask?.cancel()
        audioEnqueueTask = nil
        readTask?.cancel()

        // Capture everything the detached task needs — avoid referencing self directly
        // since self is @MainActor and the task must run off MainActor for FFmpeg I/O.
        let demuxer = self.demuxer
        let renderer = self.renderer
        let profileConverter = self.profileConverter
        let requiresConversion = self.requiresProfileConversion
        let audioDecoder = self.audioDecoder

        guard let videoFD = demuxer.videoFormatDescription else {
            print("[DirectPlay] No video format description — cannot start read loop")
            onError?(FFmpegError.noCodecParameters)
            return
        }
        let audioFD = demuxer.audioFormatDescription
        let hasDV = demuxer.hasDolbyVision

        var audioContinuation: AsyncStream<CMSampleBuffer>.Continuation?
        var audioGate: AudioBufferGate?
        var audioDecodeStream: AsyncStream<DemuxedPacket>?
        var audioDecodeContinuation: AsyncStream<DemuxedPacket>.Continuation?
        var audioDecodeGate: AudioBufferGate?

        if audioDecoder != nil || audioFD != nil {
            // AC3 packets are typically 32ms; keep queue under ~0.8s so audio
            // cannot run multiple seconds ahead of video on slow-start bursts.
            let gate = AudioBufferGate(limit: 24)
            audioGate = gate
            print("[DirectPlay] Audio enqueue queue enabled (limit=\(gate.limit))")

            let (stream, continuation) = AsyncStream<CMSampleBuffer>.makeStream(
                bufferingPolicy: .unbounded
            )
            audioContinuation = continuation

            audioEnqueueTask = Task.detached {
                for await sampleBuffer in stream {
                    guard !Task.isCancelled else { break }
                    await renderer.enqueueAudio(sampleBuffer)
                    gate.pending -= 1
                }
            }
        }

        if audioDecoder != nil {
            // Keep compressed audio decode off the packet-read path so video can
            // continue progressing even when TrueHD/DTS decoding is expensive.
            let gate = AudioBufferGate(limit: 512)
            audioDecodeGate = gate
            let (stream, continuation) = AsyncStream<DemuxedPacket>.makeStream(
                bufferingPolicy: .unbounded
            )
            audioDecodeStream = stream
            audioDecodeContinuation = continuation
            print("[DirectPlay] Audio decode queue enabled (limit=\(gate.limit))")
        }

        let localAudioEnqueueTask = audioEnqueueTask
        let localAudioContinuation = audioContinuation
        let localAudioGate = audioGate
        let localAudioDecodeStream = audioDecodeStream
        let localAudioDecodeContinuation = audioDecodeContinuation
        let localAudioDecodeGate = audioDecodeGate

        print("[DirectPlay] Starting read loop (audioFD=\(audioFD != nil), hasDV=\(hasDV), conversion=\(requiresConversion))")

        readTask = Task.detached { [weak self] in
            print("[DirectPlay] Read loop started on background thread")
            var isFirstVideoFrame = true
            var videoPacketCount = 0
            var audioPacketCount = 0
            var conversionDisabled = false
            let videoDiagStartWall = CFAbsoluteTimeGetCurrent()
            var firstVideoPTSForDiag: TimeInterval?
            var lastVideoWallTime: CFAbsoluteTime?
            var maxVideoWallGapMs: Double = 0
            var longVideoWallGaps = 0
            var lateVideoObservationCount = 0
            var lateVideoDropCount = 0
            var lateVideoSoftDropCount = 0
            var consecutiveLateVideoFrames = 0
            var lateVideoResyncCount = 0
            var lastLateVideoResyncWall: CFAbsoluteTime = 0
            let lateVideoDropThreshold: TimeInterval = 0.75 // 750ms behind sync clock
            let forceLateResyncThreshold: TimeInterval = 2.0 // hard recover when >2s behind
            let maxConsecutiveLateFramesBeforeResync = 24 // ~1s at 24fps
            let lateResyncCooldown: TimeInterval = 0.5 // avoid rapid sync thrash
            let softLateDropThreshold: TimeInterval = requiresConversion ? 0.90 : 1.10
            let maxSoftLateDropsPerBurst = requiresConversion ? 12 : 8
            var slowVideoPipelineCount = 0
            var waitingForPrerollStart = false
            var prerollWaitStartWall: CFAbsoluteTime?
            var prerollAnchorPTSSeconds: Double?
            var prerollMaxPTSSeconds: Double?

            let enqueueAudioBuffer: @Sendable (CMSampleBuffer) async -> Void = { sampleBuffer in
                if let localAudioContinuation, let localAudioGate {
                    let depth = localAudioGate.pending
                    if depth > localAudioGate.maxPending {
                        localAudioGate.maxPending = depth
                    }

                    if depth >= localAudioGate.limit {
                        localAudioGate.dropped += 1
                        let dropped = localAudioGate.dropped
                        if dropped <= 10 || dropped % 120 == 0 {
                            print("[DirectPlayDiag] Dropping queued audio sample #\(dropped) " +
                                  "(audioQ=\(depth), limit=\(localAudioGate.limit))")
                        }
                        return
                    }

                    guard !Task.isCancelled else { return }
                    localAudioContinuation.yield(sampleBuffer)
                    localAudioGate.pending += 1
                } else {
                    await renderer.enqueueAudio(sampleBuffer)
                }
            }

            var localAudioDecodeTask: Task<Void, Never>?
            if let decoder = audioDecoder,
               let localAudioDecodeStream,
               let localAudioDecodeGate {
                localAudioDecodeTask = Task.detached {
                    for await compressedPacket in localAudioDecodeStream {
                        guard !Task.isCancelled else { break }

                        let batchedFrames = decoder.decodeAndBatch(compressedPacket)
                        for batchedFrame in batchedFrames {
                            if let sampleBuffer = try? decoder.createPCMSampleBuffer(from: batchedFrame) {
                                await enqueueAudioBuffer(sampleBuffer)
                            }
                        }

                        localAudioDecodeGate.pending -= 1
                    }

                    // Flush residual decoder batch on stream end.
                    if let remaining = decoder.flushBatch(),
                       let sampleBuffer = try? decoder.createPCMSampleBuffer(from: remaining) {
                        await enqueueAudioBuffer(sampleBuffer)
                    }
                }
            }

            // Track loop exit reason for cleanup
            enum LoopExit { case eos, pausedSeek, error(Error), cancelled }
            var exitReason: LoopExit = .cancelled

            readLoop: while !Task.isCancelled {
                do {
                    guard let packet = try demuxer.readPacket() else {
                        exitReason = .eos
                        break readLoop
                    }

                    switch packet.trackType {
                    case .video:
                        let frameWallStart = CFAbsoluteTimeGetCurrent()
                        videoPacketCount += 1
                        if videoPacketCount == 1 {
                            print("[DirectPlay] First video packet: pts=\(packet.ptsSeconds)s size=\(packet.data.count)B keyframe=\(packet.isKeyframe) tb=\(packet.timebase.timescale)")
                        } else if videoPacketCount % 500 == 0 {
                            print("[DirectPlay] Progress: \(videoPacketCount) video / \(audioPacketCount) audio packets, pts=\(String(format: "%.1f", packet.ptsSeconds))s")
                        }

                        // If the render clock has run ahead of packet PTS, attempt bounded
                        // clock recovery; only drop in emergency stale-frame cases.
                        if !isFirstVideoFrame {
                            let syncTime = renderer.currentTime
                            let lateness = syncTime - packet.ptsSeconds
                            if lateness > lateVideoDropThreshold {
                                lateVideoObservationCount += 1
                                consecutiveLateVideoFrames += 1

                                let nowWall = CFAbsoluteTimeGetCurrent()
                                let wantsKeyframeResync = packet.isKeyframe && consecutiveLateVideoFrames >= 4
                                let wantsForcedResync = lateness > forceLateResyncThreshold ||
                                    consecutiveLateVideoFrames >= maxConsecutiveLateFramesBeforeResync
                                let canResync = nowWall - lastLateVideoResyncWall >= lateResyncCooldown
                                var didResync = false

                                if (wantsKeyframeResync || wantsForcedResync) && canResync {
                                    let resyncRate = await MainActor.run { [weak self] in
                                        guard let self else { return Float?.none }
                                        let rate = self.isPlaying ? self.playbackRate : Float(0)
                                        renderer.setRate(rate, time: packet.cmPTS)
                                        return rate
                                    }

                                    if let resyncRate {
                                        lateVideoResyncCount += 1
                                        lastLateVideoResyncWall = nowWall

                                        if lateVideoResyncCount <= 10 || lateVideoResyncCount % 60 == 0 {
                                            print("[DirectPlayDiag] Late-video resync #\(lateVideoResyncCount): " +
                                                  "rate=\(String(format: "%.2f", resyncRate)) " +
                                                  "pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                                  "sync=\(String(format: "%.3f", syncTime))s " +
                                                  "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                                  "lateBurst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                                        }
                                        consecutiveLateVideoFrames = 0
                                        didResync = true
                                    }
                                }

                                if !didResync {
                                    let shouldSoftDrop = !packet.isKeyframe &&
                                        lateness >= softLateDropThreshold &&
                                        consecutiveLateVideoFrames <= maxSoftLateDropsPerBurst

                                    if shouldSoftDrop {
                                        lateVideoDropCount += 1
                                        lateVideoSoftDropCount += 1
                                        if lateVideoSoftDropCount <= 10 || lateVideoSoftDropCount % 120 == 0 {
                                            print("[DirectPlayDiag] Soft drop late video #\(lateVideoSoftDropCount): " +
                                                  "pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                                  "sync=\(String(format: "%.3f", syncTime))s " +
                                                  "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                                  "burst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                                        }
                                        continue
                                    }

                                    if lateVideoObservationCount <= 10 || lateVideoObservationCount % 120 == 0 {
                                        print("[DirectPlayDiag] Late video frame #\(lateVideoObservationCount): " +
                                              "pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                              "sync=\(String(format: "%.3f", syncTime))s " +
                                              "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                              "burst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                                    }
                                }
                                // Emergency only: if a frame is extremely stale, drop it.
                                if lateness > 4.0 {
                                    lateVideoDropCount += 1
                                    if lateVideoDropCount <= 10 || lateVideoDropCount % 60 == 0 {
                                        print("[DirectPlayDiag] Emergency drop #\(lateVideoDropCount): " +
                                              "pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                              "sync=\(String(format: "%.3f", syncTime))s " +
                                              "lateness=\(String(format: "%.0f", lateness * 1000))ms")
                                    }
                                    continue
                                }
                            } else if consecutiveLateVideoFrames > 0 {
                                if consecutiveLateVideoFrames >= 8 {
                                    print("[DirectPlayDiag] Late-video burst recovered after \(consecutiveLateVideoFrames) frames")
                                }
                                consecutiveLateVideoFrames = 0
                            }
                        }

                        // Inline DV conversion: RPU conversion + EL stripping (~0.7ms/frame)
                        let conversionStart = CFAbsoluteTimeGetCurrent()
                        var packetData = packet.data
                        if requiresConversion && !conversionDisabled, let converter = profileConverter {
                            packetData = converter.processVideoSample(packetData)

                            // Auto-fallback: after 48 frames, check if conversion can sustain
                            // realtime. If not, disable for the rest of the stream (HDR10 passthrough).
                            if converter.framesConverted == 48 {
                                if !converter.canSustainRealTime() {
                                    conversionDisabled = true
                                    print("[DirectPlay] DV conversion too slow " +
                                          "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame, " +
                                          "budget=41.7ms), switching to HDR10 passthrough")
                                } else {
                                    print("[DirectPlay] DV conversion sustaining realtime " +
                                          "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame)")
                                }
                            }
                        }
                        let conversionEnd = CFAbsoluteTimeGetCurrent()

                        let processedPacket = DemuxedPacket(
                            streamIndex: packet.streamIndex,
                            trackType: packet.trackType,
                            data: packetData,
                            pts: packet.pts, dts: packet.dts,
                            duration: packet.duration,
                            timebase: packet.timebase,
                            isKeyframe: packet.isKeyframe
                        )

                        let sampleCreateStart = CFAbsoluteTimeGetCurrent()
                        let effectiveVideoFD = hasDV ? (demuxer.videoFormatDescription ?? videoFD) : videoFD
                        let sampleBuffer = try demuxer.createVideoSampleBuffer(
                            from: processedPacket, formatDescription: effectiveVideoFD
                        )
                        let sampleCreateEnd = CFAbsoluteTimeGetCurrent()

                        let isFirst = isFirstVideoFrame
                        let ptsSeconds = packet.ptsSeconds

                        let syncPrepStart = CFAbsoluteTimeGetCurrent()
                        let shouldStartPreroll = await MainActor.run { [weak self] () -> Bool in
                            renderer.jitterStats.recordVideoPTS(ptsSeconds)
                            guard let self else { return false }
                            if self.needsInitialSync {
                                self.needsInitialSync = false
                                let pts = packet.cmPTS
                                renderer.setRate(0, time: pts)
                                let shouldPreroll = self.isPlaying
                                print("[DirectPlay] Initial sync: setting rate=0.0 time=\(CMTimeGetSeconds(pts))s (preroll=\(shouldPreroll))")
                                return shouldPreroll
                            } else if self.needsRateRestoreAfterSeek && isFirst {
                                self.needsRateRestoreAfterSeek = false
                                let pts = packet.cmPTS
                                renderer.setRate(0, time: pts)
                                let shouldPreroll = self.isPlaying
                                print("[DirectPlay] Post-seek sync: setting rate=0.0 time=\(CMTimeGetSeconds(pts))s (preroll=\(shouldPreroll))")
                                return shouldPreroll
                            } else if !self.isPlaying && isFirst {
                                renderer.setRate(0, time: packet.cmPTS)
                            }
                            return false
                        }
                        if shouldStartPreroll {
                            waitingForPrerollStart = true
                            prerollWaitStartWall = CFAbsoluteTimeGetCurrent()
                            prerollAnchorPTSSeconds = ptsSeconds
                            prerollMaxPTSSeconds = ptsSeconds
                        }
                        let syncPrepEnd = CFAbsoluteTimeGetCurrent()

                        let enqueueStart = CFAbsoluteTimeGetCurrent()
                        await renderer.enqueueVideo(
                            sampleBuffer,
                            bypassLookahead: waitingForPrerollStart
                        )
                        let enqueueEnd = CFAbsoluteTimeGetCurrent()

                        if waitingForPrerollStart {
                            if let maxPTS = prerollMaxPTSSeconds {
                                prerollMaxPTSSeconds = max(maxPTS, ptsSeconds)
                            } else {
                                prerollMaxPTSSeconds = ptsSeconds
                            }

                            let audioPrimed = await MainActor.run {
                                renderer.isAudioPrimedForPlayback
                            }
                            let hasAudioPath = (localAudioGate != nil)
                            let audioReady = !hasAudioPath || audioPrimed
                            let prerollLeadSeconds: Double = {
                                guard let anchor = prerollAnchorPTSSeconds, let maxPTS = prerollMaxPTSSeconds else { return 0 }
                                return max(0, maxPTS - anchor)
                            }()
                            // Non-conversion streams commonly expose ~200ms reordered lead at startup.
                            // Requiring more can stall preroll on some DV direct-play files.
                            let requiredPrerollLeadSeconds = requiresConversion ? 0.45 : 0.20
                            let videoReady = prerollLeadSeconds >= requiredPrerollLeadSeconds
                            let waitedMs: Double = {
                                guard let start = prerollWaitStartWall else { return 0 }
                                return (CFAbsoluteTimeGetCurrent() - start) * 1000
                            }()
                            let timedOut = hasAudioPath && waitedMs >= 1000

                            if timedOut {
                                print("[DirectPlay] Preroll timeout after \(String(format: "%.0f", waitedMs))ms " +
                                      "(audioReady=\(audioReady) videoReady=\(videoReady) " +
                                      "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                                      "need=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms)")
                            }
                            if (audioReady && videoReady) || timedOut {
                                let startedRate = await MainActor.run { [weak self] () -> (Float, Double, String)? in
                                    guard let self, self.isPlaying else { return nil }
                                    let rate = self.playbackRate
                                    // Keep the preroll anchor time to avoid jumping the clock
                                    // ahead of already-enqueued B-frame reordered samples.
                                    let anchorTime = renderer.currentTime
                                    renderer.setRate(rate)
                                    let reason = timedOut ? "timeout" : "audio+video_primed"
                                    return (rate, anchorTime, reason)
                                }
                                if let started = startedRate {
                                    let (startedRate, anchorTime, reason) = started
                                    waitingForPrerollStart = false
                                    prerollWaitStartWall = nil
                                    prerollAnchorPTSSeconds = nil
                                    prerollMaxPTSSeconds = nil
                                    print(
                                        "[DirectPlay] Preroll complete: starting clock from anchor=\(String(format: "%.3f", anchorTime))s " +
                                        "packet=\(String(format: "%.3f", ptsSeconds))s rate=\(String(format: "%.2f", startedRate)) " +
                                        "reason=\(reason) wait=\(String(format: "%.0f", waitedMs))ms " +
                                        "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms"
                                    )
                                }
                            } else if videoPacketCount <= 10 || videoPacketCount % 120 == 0 {
                                print(
                                    "[DirectPlayDiag] Waiting for preroll start: frame=\(videoPacketCount) " +
                                    "pts=\(String(format: "%.3f", ptsSeconds))s audioQ=\(localAudioGate?.pending ?? -1) " +
                                    "audioPrimed=\(audioPrimed) videoLead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                                    "needLead=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms " +
                                    "wait=\(String(format: "%.0f", waitedMs))ms"
                                )
                            }
                        }

                        let totalPipelineMs = (enqueueEnd - frameWallStart) * 1000
                        if totalPipelineMs > 120 {
                            slowVideoPipelineCount += 1
                            if slowVideoPipelineCount <= 10 || slowVideoPipelineCount % 120 == 0 {
                                let conversionMs = (conversionEnd - conversionStart) * 1000
                                let sampleCreateMs = (sampleCreateEnd - sampleCreateStart) * 1000
                                let syncPrepMs = (syncPrepEnd - syncPrepStart) * 1000
                                let enqueueMs = (enqueueEnd - enqueueStart) * 1000
                                print(
                                    "[DirectPlayDiag] Slow video pipeline frame \(videoPacketCount): " +
                                    "total=\(String(format: "%.0f", totalPipelineMs))ms " +
                                    "conv=\(String(format: "%.1f", conversionMs))ms " +
                                    "sample=\(String(format: "%.1f", sampleCreateMs))ms " +
                                    "sync=\(String(format: "%.1f", syncPrepMs))ms " +
                                    "enqueue=\(String(format: "%.1f", enqueueMs))ms"
                                )
                            }
                        }

                        // Video cadence diagnostics (ground truth for jump/stutter analysis).
                        // Tracks wall-clock inter-frame gaps and render-clock drift vs enqueued PTS.
                        let nowWall = CFAbsoluteTimeGetCurrent()
                        if let previousWall = lastVideoWallTime {
                            let wallGapMs = (nowWall - previousWall) * 1000
                            if wallGapMs > maxVideoWallGapMs {
                                maxVideoWallGapMs = wallGapMs
                            }
                            if wallGapMs > 120 {
                                longVideoWallGaps += 1
                                if longVideoWallGaps <= 5 || longVideoWallGaps % 50 == 0 {
                                    print("[DirectPlayDiag] Long wall gap: \(String(format: "%.0f", wallGapMs))ms at frame \(videoPacketCount)")
                                }
                            }
                        }
                        lastVideoWallTime = nowWall

                        if firstVideoPTSForDiag == nil {
                            firstVideoPTSForDiag = ptsSeconds
                        }

                        if videoPacketCount % 240 == 0 {
                            let syncTime = renderer.currentTime
                            let syncMinusPTS = (syncTime - ptsSeconds) * 1000
                            let elapsedWall = nowWall - videoDiagStartWall
                            let streamElapsed = firstVideoPTSForDiag.map { ptsSeconds - $0 } ?? 0
                            let playbackRateVsWall = elapsedWall > 0 ? (streamElapsed / elapsedWall) : 0
                            let audioQueueDepth = localAudioGate?.pending ?? -1
                            let audioQueueMaxDepth = localAudioGate?.maxPending ?? -1
                            let audioQueueDrops = localAudioGate?.dropped ?? -1
                            let audioDecodeQueueDepth = localAudioDecodeGate?.pending ?? -1
                            let audioDecodeQueueMaxDepth = localAudioDecodeGate?.maxPending ?? -1
                            let audioDecodeQueueDrops = localAudioDecodeGate?.dropped ?? -1

                            print(
                                "[DirectPlayDiag] v=\(videoPacketCount) a=\(audioPacketCount) " +
                                "pts=\(String(format: "%.3f", ptsSeconds))s sync=\(String(format: "%.3f", syncTime))s " +
                                "sync-pts=\(String(format: "%.0f", syncMinusPTS))ms " +
                                "media/wall=\(String(format: "%.3f", playbackRateVsWall))x " +
                                "audioQ=\(audioQueueDepth) maxGap=\(String(format: "%.0f", maxVideoWallGapMs))ms " +
                                "maxAudioQ=\(audioQueueMaxDepth) audioQDrops=\(audioQueueDrops) " +
                                "audioDecQ=\(audioDecodeQueueDepth) maxAudioDecQ=\(audioDecodeQueueMaxDepth) " +
                                "audioDecDrops=\(audioDecodeQueueDrops) " +
                                "longGaps=\(longVideoWallGaps) lateObs=\(lateVideoObservationCount) " +
                                "lateDrops=\(lateVideoDropCount) lateSoftDrops=\(lateVideoSoftDropCount) " +
                                "lateBurst=\(consecutiveLateVideoFrames) " +
                                "lateResyncs=\(lateVideoResyncCount) slowFrames=\(slowVideoPipelineCount)"
                            )
                        }

                        // Single MainActor hop for post-enqueue state updates
                        // (state transition + paused-seek check + bufferedTime + layer error).
                        let shouldStop = await MainActor.run { [weak self] () -> Bool in
                            guard let self else { return false }

                            if let layerError = renderer.displayLayerError {
                                print("[DirectPlay] Display layer error after frame \(videoPacketCount): \(layerError)")
                            }

                            if self.state == .seeking && self.isPlaying {
                                self.state = .running
                                self.onStateChange?(.running)
                            }

                            self.bufferedTime = ptsSeconds

                            if isFirst && !self.isPlaying {
                                self.state = .paused
                                self.onStateChange?(.paused)
                                return true
                            }
                            return false
                        }
                        if shouldStop {
                            exitReason = .pausedSeek
                            break readLoop
                        }

                        isFirstVideoFrame = false

                    case .audio:
                        audioPacketCount += 1
                        if audioPacketCount == 1 {
                            let durationSeconds = CMTimeGetSeconds(packet.cmDuration)
                            let dtsSeconds = CMTimeGetSeconds(packet.cmDTS)
                            let durationLog = durationSeconds.isFinite ? String(format: "%.4f", durationSeconds) : "invalid"
                            let dtsLog = dtsSeconds.isFinite ? String(format: "%.3f", dtsSeconds) : "invalid"
                            print(
                                "[DirectPlay] First audio packet: pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                "dts=\(dtsLog)s dur=\(durationLog)s size=\(packet.data.count)B tb=\(packet.timebase.timescale)" +
                                " decode=\(audioDecoder != nil ? "client" : "passthrough")"
                            )
                        }

                        if let decoder = audioDecoder {
                            if let localAudioDecodeContinuation, let localAudioDecodeGate {
                                let depth = localAudioDecodeGate.pending
                                if depth > localAudioDecodeGate.maxPending {
                                    localAudioDecodeGate.maxPending = depth
                                }

                                if depth >= localAudioDecodeGate.limit {
                                    localAudioDecodeGate.dropped += 1
                                    let dropped = localAudioDecodeGate.dropped
                                    if dropped <= 10 || dropped % 120 == 0 {
                                        print("[DirectPlayDiag] Dropping queued compressed audio packet #\(dropped) " +
                                              "(audioDecQ=\(depth), limit=\(localAudioDecodeGate.limit))")
                                    }
                                    continue
                                }

                                localAudioDecodeContinuation.yield(packet)
                                localAudioDecodeGate.pending += 1
                            } else {
                                // Fallback if decode queue setup failed.
                                let batchedFrames = decoder.decodeAndBatch(packet)
                                for batchedFrame in batchedFrames {
                                    let sampleBuffer = try decoder.createPCMSampleBuffer(from: batchedFrame)
                                    await enqueueAudioBuffer(sampleBuffer)
                                }
                            }
                        } else {
                            // Passthrough: native codec (AAC, AC3, EAC3, etc.)
                            guard let audioFD else {
                                if audioPacketCount == 1 {
                                    print("[DirectPlay] Skipping audio — no format description")
                                }
                                continue
                            }
                            let sampleBuffer = try demuxer.createAudioSampleBuffer(
                                from: packet, formatDescription: audioFD
                            )
                            await enqueueAudioBuffer(sampleBuffer)
                        }

                    case .subtitle:
                        if let decoder = await MainActor.run(body: { [weak self] in self?.subtitleDecoder }) {
                            // Bitmap subtitle (PGS, DVB-SUB)
                            if let frame = decoder.decode(packet) {
                                let cueId = await MainActor.run { [weak self] () -> Int in
                                    guard let self else { return 0 }
                                    let id = self.bitmapCueCounter
                                    self.bitmapCueCounter += 1
                                    return id
                                }
                                let cue = BitmapSubtitleCue(
                                    id: cueId,
                                    startTime: frame.startTime,
                                    endTime: frame.endTime,
                                    rects: frame.rects
                                )
                                await MainActor.run { [weak self] in
                                    self?.onBitmapSubtitleCue?(cue)
                                }
                            }
                        } else {
                            // Text subtitle (SRT, ASS)
                            let rawText = String(data: packet.data, encoding: .utf8) ?? ""
                            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                let start = packet.ptsSeconds
                                let dur = Double(packet.duration) * Double(packet.timebase.value) / Double(packet.timebase.timescale)
                                let end = start + dur
                                if dur > 0 {
                                    await MainActor.run { [weak self] in
                                        self?.onSubtitleCue?(text, start, end)
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    exitReason = .error(error)
                    break readLoop
                }
            }

            // --- Cleanup ---
            let summaryMaxAudioQ = localAudioGate?.maxPending ?? -1
            let summaryAudioDrops = localAudioGate?.dropped ?? -1
            let summaryMaxAudioDecQ = localAudioDecodeGate?.maxPending ?? -1
            let summaryAudioDecDrops = localAudioDecodeGate?.dropped ?? -1
            print("[DirectPlay] Read loop exiting: reason=\(exitReason) video=\(videoPacketCount) audio=\(audioPacketCount)")
            print("[DirectPlayDiag] Summary: maxWallGap=\(String(format: "%.0f", maxVideoWallGapMs))ms " +
                  "maxAudioQ=\(summaryMaxAudioQ) audioQDrops=\(summaryAudioDrops) " +
                  "maxAudioDecQ=\(summaryMaxAudioDecQ) audioDecDrops=\(summaryAudioDecDrops) " +
                  "longGaps=\(longVideoWallGaps) lateObs=\(lateVideoObservationCount) " +
                  "lateDrops=\(lateVideoDropCount) lateSoftDrops=\(lateVideoSoftDropCount) " +
                  "lateResyncs=\(lateVideoResyncCount) " +
                  "slowFrames=\(slowVideoPipelineCount)")

            localAudioDecodeContinuation?.finish()
            await localAudioDecodeTask?.value

            localAudioContinuation?.finish()
            await localAudioEnqueueTask?.value

            await MainActor.run { [weak self] in
                self?.audioEnqueueTask = nil
            }

            // Handle exit reason
            switch exitReason {
            case .eos:
                print("[DirectPlay] End of stream (video=\(videoPacketCount) audio=\(audioPacketCount) packets)")
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.isPlaying = false
                        self.state = .ended
                        self.onEndOfStream?()
                    }
                }
            case .error(let error):
                if !Task.isCancelled {
                    print("[DirectPlay] Read error: \(error)")
                    SentrySDK.capture(error: error) { scope in
                        scope.setTag(value: "direct_play", key: "component")
                        scope.setTag(value: "read_loop", key: "error_type")
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.state = .failed(error.localizedDescription)
                        self.onError?(error)
                    }
                }
            case .pausedSeek:
                // Signal that resume() must restart the read loop
                await MainActor.run { [weak self] in
                    self?.readTask = nil
                }
            case .cancelled:
                break
            }
        }
    }

    // MARK: - Private: Track Population

    private func populateTrackInfo() {
        audioTracks = demuxer.audioTracks.enumerated().map { index, track in
            MediaTrack(
                id: Int(track.streamIndex),
                name: track.title ?? track.codecName.uppercased(),
                language: track.language.flatMap { languageName(from: $0) },
                languageCode: track.language,
                codec: track.codecName,
                isDefault: track.isDefault || index == 0,
                isForced: false,
                isHearingImpaired: false,
                channels: Int(track.channels)
            )
        }

        subtitleTracks = demuxer.subtitleTracks.enumerated().map { index, track in
            MediaTrack(
                id: Int(track.streamIndex),
                name: track.title ?? track.codecName.uppercased(),
                language: track.language.flatMap { languageName(from: $0) },
                languageCode: track.language,
                codec: track.codecName,
                isDefault: track.isDefault,
                isForced: false,
                isHearingImpaired: false
            )
        }
    }

    /// Convert ISO 639-2 language code to display name
    private func languageName(from code: String) -> String {
        let locale = Locale(identifier: "en")
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    private func codecNeedsClientDecode(_ codec: String) -> Bool {
        let normalized = codec.lowercased()
        return FFmpegAudioDecoder.supportedCodecs.contains(where: { supported in
            normalized == supported || normalized.hasPrefix(supported)
        })
    }

    private func preferredNativeAudioTrack(preferredLanguage: String?) -> FFmpegTrackInfo? {
        let nativeCandidates = demuxer.audioTracks.filter { track in
            !codecNeedsClientDecode(track.codecName) && codecIsLikelyNative(track.codecName)
        }
        guard !nativeCandidates.isEmpty else { return nil }

        let languageScoped: [FFmpegTrackInfo]
        if let preferredLanguage {
            let matches = nativeCandidates.filter { $0.language == preferredLanguage }
            languageScoped = matches.isEmpty ? nativeCandidates : matches
        } else {
            languageScoped = nativeCandidates
        }

        return languageScoped.max(by: { nativeTrackScore($0) < nativeTrackScore($1) })
    }

    private func codecIsLikelyNative(_ codec: String) -> Bool {
        let normalized = codec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let nativePrefixes = [
            "eac3", "ec3", "ac3",
            "aac", "alac", "flac",
            "mp3", "mp2", "opus", "pcm"
        ]
        return nativePrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0) })
    }

    private func nativeTrackScore(_ track: FFmpegTrackInfo) -> Int {
        let codec = track.codecName.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let codecScore: Int
        if codec.hasPrefix("eac3") || codec.hasPrefix("ec3") {
            codecScore = 500
        } else if codec.hasPrefix("ac3") {
            codecScore = 450
        } else if codec.hasPrefix("aac") {
            codecScore = 400
        } else if codec.hasPrefix("opus") {
            codecScore = 350
        } else if codec.hasPrefix("flac") || codec.hasPrefix("alac") {
            codecScore = 320
        } else if codec.hasPrefix("mp3") || codec.hasPrefix("mp2") {
            codecScore = 260
        } else {
            codecScore = 100
        }

        let defaultBonus = track.isDefault ? 30 : 0
        return codecScore + Int(track.channels) * 4 + defaultBonus
    }
}
