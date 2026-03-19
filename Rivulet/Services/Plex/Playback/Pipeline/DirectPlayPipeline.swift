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
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var maxPending = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Attempts to reserve one queue slot and updates queue diagnostics.
    func reserveSlot() -> (accepted: Bool, depth: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }

        let depth = pending
        if depth > maxPending {
            maxPending = depth
        }

        if depth >= limit {
            dropped += 1
            return (accepted: false, depth: depth, dropped: dropped)
        }

        pending += 1
        return (accepted: true, depth: depth, dropped: dropped)
    }

    func completeOne() {
        lock.lock()
        defer { lock.unlock() }
        if pending > 0 {
            pending -= 1
        }
    }

    func snapshot() -> (pending: Int, dropped: Int, maxPending: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pending: pending, dropped: dropped, maxPending: maxPending)
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

    /// When true, all audio codecs (including AAC) are decoded client-side via FFmpeg.
    /// Required for AirPlay routes — compressed passthrough to AVSampleBufferAudioRenderer
    /// is silently accepted but produces no audible output over AirPlay. Decoded PCM S16
    /// goes through the sample-buffer renderer's pull-mode path with larger AirPlay buffers.
    var forceClientDecodeAllAudio = false
    var forceClientDecodeCodecs: Set<String> = []

    /// Output signed 16-bit integer PCM instead of 32-bit float for client-decoded audio.
    /// AirPlay 2 natively supports S16/S24 but not float32 — avoids system-side conversion artifacts.
    /// Skips propagation when encoder is active — decoder must output native F32 for the encoder.
    var useSignedInt16Audio = false {
        didSet {
            if audioEncoder == nil { audioDecoder?.useSignedInt16Output = useSignedInt16Audio }
        }
    }

    /// When true, downmix multichannel audio to stereo for basic AirPlay speakers.
    /// Skips propagation when encoder is active — decoder must preserve full channel layout.
    var forceDownmixToStereo = false {
        didSet {
            if audioEncoder == nil { audioDecoder?.forceDownmixToStereo = forceDownmixToStereo }
        }
    }

    /// Target output sample rate for client-decoded audio.
    /// When set, swresample resamples to this rate to match the audio hardware.
    /// Critical for AirPlay (44100Hz) where source audio is typically 48000Hz.
    /// Skips propagation when encoder is active — decoder must output native rate for the encoder.
    var targetOutputSampleRate: Int = 0 {
        didSet {
            if audioEncoder == nil { audioDecoder?.targetOutputSampleRate = targetOutputSampleRate }
        }
    }

    /// When true, decoded PCM audio is routed through AVAudioEngine instead of
    /// AVSampleBufferAudioRenderer. Used for stereo AirPlay/HomePod routes where
    /// the engine has proven more tolerant than sample-buffer PCM delivery.
    var preferAudioEngineForPCM = false {
        didSet {
            guard audioDecoder != nil, audioEncoder == nil else { return }
            if preferAudioEngineForPCM {
                renderer.enableAudioEngine()
            } else {
                renderer.disableAudioEngine()
            }
        }
    }

    /// When true, re-encode client-decoded audio to EAC3 for surround over AirPlay.
    /// DTS/TrueHD -> PCM (F32, multichannel) -> EAC3 -> HomePods (5.1/7.1 surround).
    var enableSurroundReEncoding = false

    private var audioEncoder: FFmpegAudioEncoder?

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
    private var isAudioRecoveryInProgress = false
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0

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
            renderer.maxVideoLookahead = 5.0
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

            // Rebuild the format description with a proper dvcC config box signalling
            // Profile 8.1 with HDR10-compatible base layer. Without this, VideoToolbox
            // gets a dvh1-tagged stream with no DV configuration and may use a slow or
            // incorrect decode path (e.g., attempting dual-layer P7 processing).
            demuxer.rebuildFormatDescriptionWithDVCC(dvProfile: 8, blCompatId: 1)
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
                    let decoder = try FFmpegAudioDecoder(
                        codecpar: codecpar,
                        codecNameHint: selectedAudioTrack.codecName
                    )
                    if enableSurroundReEncoding && selectedAudioTrack.channels > 2 {
                        // Re-encoding path: decoder outputs native F32 multichannel PCM,
                        // encoder converts to EAC3 for surround passthrough over AirPlay.
                        decoder.useSignedInt16Output = false
                        decoder.forceDownmixToStereo = false
                        decoder.targetOutputSampleRate = 0

                        do {
                            let encoder = try FFmpegAudioEncoder(
                                channels: Int(selectedAudioTrack.channels),
                                sampleRate: Int(selectedAudioTrack.sampleRate),
                                bitsPerSample: 32  // F32 from decoder
                            )
                            audioEncoder = encoder
                            print("[DirectPlay] EAC3 re-encoder enabled for " +
                                  "\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch " +
                                  "-> EAC3 surround")
                        } catch {
                            // Encoder failed — fall back to stereo S16
                            print("[DirectPlay] EAC3 encoder init failed: \(error) — falling back to stereo PCM")
                            audioEncoder = nil
                            decoder.useSignedInt16Output = useSignedInt16Audio
                            decoder.forceDownmixToStereo = forceDownmixToStereo
                            decoder.targetOutputSampleRate = targetOutputSampleRate
                        }
                    } else {
                        decoder.useSignedInt16Output = useSignedInt16Audio
                        decoder.forceDownmixToStereo = forceDownmixToStereo
                        decoder.targetOutputSampleRate = targetOutputSampleRate
                    }
                    audioDecoder = decoder
                    print("[DirectPlay] Client-side audio decoding enabled for " +
                          "\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch" +
                          (audioEncoder != nil ? " (EAC3 re-encode)" : "") +
                          (useSignedInt16Audio && audioEncoder == nil ? " (S16 output)" : "") +
                          (forceDownmixToStereo && audioEncoder == nil ? " (stereo downmix)" : "") +
                          (targetOutputSampleRate > 0 && audioEncoder == nil ? " (resample->\(targetOutputSampleRate)Hz)" : ""))
                } catch {
                    print("[DirectPlay] Failed to init audio decoder for " +
                          "\(selectedAudioTrack.codecName): \(error) — falling back to passthrough")
                    audioDecoder = nil
                    audioEncoder = nil
                }
            }
        } else if let selectedAudioTrack,
                  let clientDecodeTrack = demuxer.audioTracks.first(where: { codecNeedsClientDecode($0.codecName) }) {
            print("[DirectPlay] Keeping native audio stream \(selectedAudioTrack.streamIndex) " +
                  "(\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch); " +
                  "not auto-switching to software-decoded \(clientDecodeTrack.codecName)")
        }

        if audioDecoder != nil && audioEncoder == nil && preferAudioEngineForPCM {
            renderer.enableAudioEngine()
        } else {
            renderer.disableAudioEngine()
        }

        let routeSnapshot = PlaybackAudioSessionConfigurator.currentRouteAudioSnapshot(
            owner: "DirectPlayPipeline",
            reason: "load"
        )
        let routeDecision = PlaybackAudioSessionConfigurator.policyDecisionReason(for: routeSnapshot)
        let startupCodec = selectedAudioTrack?.codecName ?? "unknown"
        let startupChannels = selectedAudioTrack.map { Int($0.channels) } ?? 0
        let startupDecodePath = audioDecoder != nil ? "client_decode" : "passthrough"
        print(
            "[DirectPlayAudioStartup] codec=\(startupCodec) decodePath=\(startupDecodePath) " +
            "streamChannels=\(startupChannels) routeAirPlay=\(routeSnapshot.isAirPlay) " +
            "maxOutCh=\(routeSnapshot.maximumOutputChannels) " +
            "supportsMultichannel=\(routeSnapshot.supportsMultichannelContent) " +
            "routeDecision=\(routeDecision) " +
            "routeRate=\(String(format: "%.0f", routeSnapshot.sampleRate))Hz " +
            "pipelineRate=\(targetOutputSampleRate > 0 ? "\(targetOutputSampleRate)" : "native") " +
            "audioEngine=\(audioDecoder != nil && audioEncoder == nil && preferAudioEngineForPCM) " +
            "reencode=\(audioEncoder != nil) audioFD=\(demuxer.audioFormatDescription != nil) tsValidity=runtime_pending"
        )

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
            "dv_conversion": enableDVConversion,
            "audio_decode_path": audioDecoder != nil ? "client_decode" : "passthrough",
            "audio_route_airplay": routeSnapshot.isAirPlay,
            "audio_route_max_out_ch": routeSnapshot.maximumOutputChannels,
            "audio_selected_codec": startupCodec,
            "audio_selected_channels": startupChannels
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
            renderer.resumeAudio()
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
        renderer.pauseAudio()
        renderer.setRate(0)
        state = .paused
        onStateChange?(.paused)
        print("[DirectPlay] paused")
        print("[PlaybackHealth] EVENT=pause")
    }

    func resume() {
        guard !isPlaying, state == .paused else { return }
        isPlaying = true
        print("[PlaybackHealth] EVENT=resume")
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
            renderer.resumeAudio()
            renderer.setRate(playbackRate)
        }
    }

    func stop() {
        isPlaying = false
        audioEnqueueTask?.cancel()
        audioEnqueueTask = nil
        readTask?.cancel()
        readTask = nil
        audioEncoder?.close()
        audioEncoder = nil
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

    /// Deterministic shutdown that waits for background tasks before tearing down decoders/demuxer.
    func shutdown() async {
        isPlaying = false

        audioEnqueueTask?.cancel()
        readTask?.cancel()

        let oldAudioTask = audioEnqueueTask
        let oldReadTask = readTask
        audioEnqueueTask = nil
        readTask = nil

        await oldAudioTask?.value
        await oldReadTask?.value

        audioEncoder?.close()
        audioEncoder = nil
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

    func seek(to time: TimeInterval, isPlaying: Bool, force: Bool = false) async throws {
        let now = CFAbsoluteTimeGetCurrent()
        let currentTime = renderer.currentTime
        let deltaFromCurrent = abs(time - currentTime)
        let deltaFromLastRequest = lastRequestedSeekTime >= 0 ? abs(time - lastRequestedSeekTime) : .infinity

        // Drop noisy duplicate seek requests that arrive back-to-back with nearly identical targets.
        if !force, now - lastSeekWallTime < 0.2 && deltaFromLastRequest < 0.25 {
            print("[DirectPlay] seek deduped: Δ=\(String(format: "%.0f", deltaFromLastRequest * 1000))ms from last request")
            return
        }
        // Ignore tiny seeks near current position to avoid unnecessary read-loop churn.
        if !force, deltaFromCurrent < 0.20 {
            print("[DirectPlay] seek ignored: Δ=\(String(format: "%.0f", deltaFromCurrent * 1000))ms from current (too small)")
            return
        }

        lastSeekWallTime = now
        lastRequestedSeekTime = time
        print(
            "[DirectPlay] seek request: from=\(String(format: "%.3f", currentTime))s " +
            "to=\(String(format: "%.3f", time))s playing=\(isPlaying)"
        )
        print("[PlaybackHealth] EVENT=seek from=\(String(format: "%.1f", currentTime))s to=\(String(format: "%.1f", time))s")

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

        // Flush renderer buffers and discard any batched/encoded audio
        renderer.flush()
        _ = audioDecoder?.flushBatch()
        audioDecoder?.resetTimestampTracking(reason: "seek")
        _ = audioEncoder?.flush()

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

    func recoverAudio(afterFlushTime flushTime: CMTime, reason: String) async throws {
        guard state != .idle, state != .loading else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if isAudioRecoveryInProgress {
            print("[DirectPlay] recoverAudio skipped (\(reason)) — recovery already in progress")
            return
        }
        if now - lastAudioRecoveryWallTime < 0.2 {
            print("[DirectPlay] recoverAudio debounced (\(reason))")
            return
        }

        lastAudioRecoveryWallTime = now
        isAudioRecoveryInProgress = true
        defer { isAudioRecoveryInProgress = false }

        let flushSeconds = CMTimeGetSeconds(flushTime)
        let syncTime = renderer.currentTime
        let targetTime = max(
            0,
            (flushSeconds.isFinite && flushSeconds >= 0) ? flushSeconds : syncTime
        )
        let wasPlaying = isPlaying

        print(
            "[DirectPlay] recoverAudio reason=\(reason) target=\(String(format: "%.3f", targetTime))s " +
            "flush=\(String(format: "%.3f", flushSeconds))s sync=\(String(format: "%.3f", syncTime))s " +
            "wasPlaying=\(wasPlaying)"
        )

        try await seek(to: targetTime, isPlaying: wasPlaying, force: true)
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

        // Flush audio, decoder, and encoder
        renderer.flush()
        _ = audioDecoder?.flushBatch()
        audioDecoder?.resetTimestampTracking(reason: "audio_track_switch")
        _ = audioEncoder?.flush()

        if codecNeedsClientDecode(track.codecName) {
            print("[DirectPlay] Audio switch: \(track.codecName) -> client decode path")
            try demuxer.selectAudioStreamForClientDecode(index: streamIndex)
            guard let codecpar = demuxer.codecParameters(forStream: streamIndex) else {
                throw FFmpegError.noCodecParameters
            }
            audioDecoder?.close()
            let decoder = try FFmpegAudioDecoder(
                codecpar: codecpar,
                codecNameHint: track.codecName
            )

            // Close old encoder before potentially creating new one
            audioEncoder?.close()
            audioEncoder = nil

            if enableSurroundReEncoding && track.channels > 2 {
                decoder.useSignedInt16Output = false
                decoder.forceDownmixToStereo = false
                decoder.targetOutputSampleRate = 0
                do {
                    audioEncoder = try FFmpegAudioEncoder(
                        channels: Int(track.channels),
                        sampleRate: Int(track.sampleRate),
                        bitsPerSample: 32
                    )
                    print("[DirectPlay] EAC3 re-encoder enabled for \(track.codecName) \(track.channels)ch")
                } catch {
                    print("[DirectPlay] EAC3 encoder init failed on track switch: \(error)")
                    decoder.useSignedInt16Output = useSignedInt16Audio
                    decoder.forceDownmixToStereo = forceDownmixToStereo
                    decoder.targetOutputSampleRate = targetOutputSampleRate
                }
            } else {
                decoder.useSignedInt16Output = useSignedInt16Audio
                decoder.forceDownmixToStereo = forceDownmixToStereo
                decoder.targetOutputSampleRate = targetOutputSampleRate
            }
            audioDecoder = decoder
            if audioEncoder == nil && preferAudioEngineForPCM {
                renderer.enableAudioEngine()
            } else {
                renderer.disableAudioEngine()
            }
        } else {
            print("[DirectPlay] Audio switch: \(track.codecName) -> passthrough path")
            audioEncoder?.close()
            audioEncoder = nil
            audioDecoder?.close()
            audioDecoder = nil
            renderer.disableAudioEngine()
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
        renderer.onAudioPrimedForPlayback = nil

        // Capture everything the detached task needs — avoid referencing self directly
        // since self is @MainActor and the task must run off MainActor for FFmpeg I/O.
        let demuxer = self.demuxer
        let renderer = self.renderer
        let profileConverter = self.profileConverter
        let requiresConversion = self.requiresProfileConversion
        let audioDecoder = self.audioDecoder
        let audioEncoder = self.audioEncoder

        guard let videoFD = demuxer.videoFormatDescription else {
            print("[DirectPlay] No video format description — cannot start read loop")
            onError?(FFmpegError.noCodecParameters)
            return
        }
        let audioFD = demuxer.audioFormatDescription
        let hasDV = demuxer.hasDolbyVision
        let activeAudioTrack = demuxer.audioTracks.first(where: { $0.streamIndex == demuxer.selectedAudioStream })
        let activeAudioSampleRate = activeAudioTrack.map { Int($0.sampleRate) } ?? 0
        let activeAudioChannels = activeAudioTrack.map { Int($0.channels) } ?? 0
        let activeTargetOutputSampleRate = self.targetOutputSampleRate

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
                    gate.completeOne()
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

        let capturedLookahead = renderer.maxVideoLookahead
        let capturedContainer = streamURL?.pathExtension ?? "?"

        readTask = Task.detached { [weak self] in
            print("[DirectPlay] Read loop started on background thread")
            print("[PlaybackHealth] CONFIG hasDV=\(hasDV) conversion=\(requiresConversion) " +
                  "lookahead=\(String(format: "%.1f", capturedLookahead))s " +
                  "audioDecoder=\(audioDecoder != nil) container=\(capturedContainer)")
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
            // DV conversion pipeline runs at ~80% real-time initially. Aggressive drop/resync
            // cascades make this worse by flushing the decode pipeline repeatedly. Give the
            // conversion pipeline generous headroom to absorb initial throughput deficit.
            let lateVideoDropThreshold: TimeInterval = requiresConversion ? 3.0 : 0.75
            let forceLateResyncThreshold: TimeInterval = requiresConversion ? 8.0 : 2.0
            let maxConsecutiveLateFramesBeforeResync = requiresConversion ? 120 : 24 // 5s at 24fps
            let lateResyncCooldown: TimeInterval = requiresConversion ? 2.0 : 0.5
            let softLateDropThreshold: TimeInterval = requiresConversion ? 3.0 : 1.10
            let maxSoftLateDropsPerBurst = requiresConversion ? 24 : 8
            var slowVideoPipelineCount = 0

            // Health report state (emits every 5s)
            var lastHealthReportWall: CFAbsoluteTime = 0
            let healthReportInterval: TimeInterval = 5.0
            var healthLateFramesSinceReport = 0
            var healthDropsSinceReport = 0
            var healthResyncsSinceReport = 0
            var healthSlowFramesSinceReport = 0
            var healthDisplayErrorsSinceReport = 0
            var healthLastPullDeliveries = 0
            var healthLastPeriodPTS: TimeInterval = 0
            var healthLastPeriodWall: CFAbsoluteTime = 0

            var waitingForPrerollStart = false
            var prerollWaitStartWall: CFAbsoluteTime?
            var prerollAnchorPTSSeconds: Double?
            var prerollAnchorTime: CMTime?
            var prerollMaxPTSSeconds: Double?
            var prerollMaxVideoPTSSeconds: Double?  // Video-only PTS for accurate preroll lead
            let hasAudioPath = (audioDecoder != nil || audioFD != nil)
            let prerollStartHostLeadSeconds: TimeInterval = activeTargetOutputSampleRate > 0 ? 0.10 : 0.03

            let maybePrimePrerollTimeline: @Sendable (Double, CMTime, String) async -> Void = { ptsSeconds, ptsTime, source in
                guard ptsSeconds.isFinite, ptsSeconds >= 0 else { return }
                guard !waitingForPrerollStart else { return }

                let decision = await MainActor.run { [weak self] () -> (shouldPreroll: Bool, label: String)? in
                    guard let self else { return nil }

                    if self.needsInitialSync {
                        self.needsInitialSync = false
                        renderer.setRate(0, time: ptsTime)
                        return (self.isPlaying, "Initial sync")
                    }

                    if self.needsRateRestoreAfterSeek {
                        self.needsRateRestoreAfterSeek = false
                        renderer.setRate(0, time: ptsTime)
                        return (self.isPlaying, "Post-seek sync")
                    }

                    return nil
                }

                guard let decision else { return }

                print(
                    "[DirectPlay] \(decision.label): setting rate=0.0 " +
                    "time=\(String(format: "%.3f", ptsSeconds))s " +
                    "(preroll=\(decision.shouldPreroll), source=\(source))"
                )

                if decision.shouldPreroll {
                    waitingForPrerollStart = true
                    prerollWaitStartWall = CFAbsoluteTimeGetCurrent()
                    prerollAnchorPTSSeconds = ptsSeconds
                    prerollAnchorTime = ptsTime
                    prerollMaxPTSSeconds = ptsSeconds
                }
            }

            let maybeCompletePrerollStart: @Sendable (Double?, Bool) async -> Bool = { currentPTSSeconds, audioReadyOverride in
                guard waitingForPrerollStart else { return false }

                let audioPrimed = await MainActor.run {
                    renderer.isAudioPrimedForPlayback
                }
                let audioReliableStart = await MainActor.run {
                    renderer.hasReliableAudioStart
                }
                let audioReady = audioReadyOverride || !hasAudioPath || audioPrimed
                let prerollLeadSeconds: Double = {
                    guard let anchor = prerollAnchorPTSSeconds, let maxPTS = prerollMaxPTSSeconds else { return 0 }
                    return max(0, maxPTS - anchor)
                }()
                // Use video-only PTS for videoReady check — audio PTS can race ahead
                // and cause preroll to complete with insufficient video buffer.
                let videoLeadSeconds: Double = {
                    guard let anchor = prerollAnchorPTSSeconds, let maxVPTS = prerollMaxVideoPTSSeconds else { return 0 }
                    return max(0, maxVPTS - anchor)
                }()
                // Non-conversion streams commonly expose ~200ms reordered lead at startup.
                // Requiring more can stall preroll on some DV direct-play files.
                let requiredPrerollLeadSeconds = requiresConversion ? 5.0 : 0.20
                let videoReady = videoLeadSeconds >= requiredPrerollLeadSeconds
                let waitedMs: Double = {
                    guard let start = prerollWaitStartWall else { return 0 }
                    return (CFAbsoluteTimeGetCurrent() - start) * 1000
                }()
                let prerollTimeout: Double = requiresConversion ? 5000 : 1000
                let timedOut = hasAudioPath && waitedMs >= prerollTimeout

                if timedOut {
                    print("[DirectPlay] Preroll timeout after \(String(format: "%.0f", waitedMs))ms " +
                          "(audioReady=\(audioReady) reliableStart=\(audioReliableStart) videoReady=\(videoReady) " +
                          "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                          "need=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms)")
                }

                guard (audioReady && videoReady) || timedOut else { return false }

                let startedRate = await MainActor.run { [weak self] () -> (Float, Double, Double, String)? in
                    guard let self else { return nil }
                    let shouldStartPlayback = (self.state == .running) || self.isPlaying
                    guard shouldStartPlayback else { return nil }
                    let rate = self.playbackRate
                    let anchorTime = prerollAnchorTime ?? CMTime(
                        seconds: prerollAnchorPTSSeconds ?? renderer.currentTime,
                        preferredTimescale: 90_000
                    )
                    let anchorSeconds = prerollAnchorPTSSeconds ?? CMTimeGetSeconds(anchorTime)
                    // Start against a short future host-time edge so the first
                    // enqueued preroll samples define the playback timeline rather
                    // than being treated as already late.
                    let hostLead = prerollStartHostLeadSeconds
                    let hostTime = CMTimeAdd(
                        CMClockGetTime(CMClockGetHostTimeClock()),
                        CMTime(seconds: hostLead, preferredTimescale: 90_000)
                    )
                    renderer.setRate(rate, time: anchorTime, atHostTime: hostTime)
                    let reason = timedOut ? "timeout" : "audio+video_primed"
                    return (rate, anchorSeconds, hostLead, reason)
                }

                guard let started = startedRate else { return false }

                let (playbackRate, anchorTime, hostLead, reason) = started
                let packetTime = currentPTSSeconds ?? prerollMaxPTSSeconds ?? anchorTime
                waitingForPrerollStart = false
                prerollWaitStartWall = nil
                prerollAnchorPTSSeconds = nil
                prerollAnchorTime = nil
                prerollMaxPTSSeconds = nil
                prerollMaxVideoPTSSeconds = nil
                print(
                    "[DirectPlay] Preroll complete: starting clock from anchor=\(String(format: "%.3f", anchorTime))s " +
                    "packet=\(String(format: "%.3f", packetTime))s rate=\(String(format: "%.2f", playbackRate)) " +
                    "reason=\(reason) wait=\(String(format: "%.0f", waitedMs))ms " +
                    "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                    "hostLead=\(String(format: "%.0f", hostLead * 1000))ms"
                )
                print("[PlaybackHealth] EVENT=preroll_complete elapsed=\(String(format: "%.0f", waitedMs))ms")

                return true
            }

            await MainActor.run {
                renderer.onAudioPrimedForPlayback = { deliveredPTSSeconds in
                    Task.detached {
                        _ = await maybeCompletePrerollStart(deliveredPTSSeconds, true)
                    }
                }
            }

            let enqueueAudioBuffer: @Sendable (CMSampleBuffer) async -> Void = { sampleBuffer in
                let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let samplePTSSeconds = CMTimeGetSeconds(samplePTS)

                await maybePrimePrerollTimeline(samplePTSSeconds, samplePTS, "audio")

                if waitingForPrerollStart,
                   let anchor = prerollAnchorPTSSeconds,
                   samplePTSSeconds.isFinite,
                   samplePTSSeconds + 0.05 < anchor {
                    let previousAnchor = anchor
                    prerollAnchorPTSSeconds = samplePTSSeconds
                    prerollAnchorTime = samplePTS
                    if let maxPTS = prerollMaxPTSSeconds {
                        prerollMaxPTSSeconds = max(maxPTS, samplePTSSeconds)
                    }
                    await MainActor.run {
                        renderer.setRate(0, time: samplePTS)
                    }
                    print(
                        "[DirectPlay] Preroll anchor adjusted for early audio sample: " +
                        "old=\(String(format: "%.3f", previousAnchor))s " +
                        "new=\(String(format: "%.3f", samplePTSSeconds))s " +
                        "delta=\(String(format: "%.0f", (previousAnchor - samplePTSSeconds) * 1000))ms"
                    )
                }

                if waitingForPrerollStart {
                    if let maxPTS = prerollMaxPTSSeconds {
                        prerollMaxPTSSeconds = max(maxPTS, samplePTSSeconds)
                    } else if samplePTSSeconds.isFinite {
                        prerollMaxPTSSeconds = samplePTSSeconds
                    }

                    await renderer.enqueueAudio(sampleBuffer)
                    _ = await maybeCompletePrerollStart(samplePTSSeconds, false)
                    return
                }

                if let localAudioContinuation, let localAudioGate {
                    let reservation = localAudioGate.reserveSlot()
                    if !reservation.accepted {
                        let dropped = reservation.dropped
                        if dropped <= 10 || dropped % 120 == 0 {
                            print("[DirectPlayDiag] Dropping queued audio sample #\(dropped) " +
                                  "(audioQ=\(reservation.depth), limit=\(localAudioGate.limit))")
                        }
                        return
                    }

                    guard !Task.isCancelled else { return }
                    localAudioContinuation.yield(sampleBuffer)
                } else {
                    await renderer.enqueueAudio(sampleBuffer)
                }
            }

            var localAudioDecodeTask: Task<Void, Never>?
            if let decoder = audioDecoder,
               let localAudioDecodeStream,
               let localAudioDecodeGate {
                if audioEncoder != nil {
                    print("[DirectPlayDiag] Audio transcode path active: decoder->EAC3 encoder " +
                          "encoderRate=\(activeAudioSampleRate)Hz encoderChannels=\(activeAudioChannels) " +
                          "routeTargetRate=\(activeTargetOutputSampleRate > 0 ? "\(activeTargetOutputSampleRate)" : "native")")
                }
                localAudioDecodeTask = Task.detached {
                    for await compressedPacket in localAudioDecodeStream {
                        guard !Task.isCancelled else { break }

                        let batchedFrames = decoder.decodeAndBatch(compressedPacket)
                        for batchedFrame in batchedFrames {
                            if let audioEncoder {
                                // Re-encode path: PCM -> EAC3
                                let encodedFrames = audioEncoder.encode(batchedFrame)
                                for encodedFrame in encodedFrames {
                                    if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                        await enqueueAudioBuffer(sb)
                                    }
                                }
                            } else {
                                // Direct PCM path
                                if let sampleBuffer = try? decoder.createPCMSampleBuffer(from: batchedFrame) {
                                    await enqueueAudioBuffer(sampleBuffer)
                                }
                            }
                        }

                        localAudioDecodeGate.completeOne()
                    }

                    // Flush residual decoder batch on stream end.
                    if let remaining = decoder.flushBatch() {
                        if let audioEncoder {
                            let encodedFrames = audioEncoder.encode(remaining)
                            for encodedFrame in encodedFrames {
                                if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                    await enqueueAudioBuffer(sb)
                                }
                            }
                            // Drain encoder's internal buffers
                            let flushed = audioEncoder.flush()
                            for encodedFrame in flushed {
                                if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                    await enqueueAudioBuffer(sb)
                                }
                            }
                        } else {
                            if let sampleBuffer = try? decoder.createPCMSampleBuffer(from: remaining) {
                                await enqueueAudioBuffer(sampleBuffer)
                            }
                        }
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
                        // DV conversion pipelines need a 30s startup grace period — the DV
                        // decoder warms up slowly and aggressive drop/resync cascades make
                        // things worse by repeatedly flushing the decode pipeline.
                        let startupGracePeriod: TimeInterval = requiresConversion ? 60.0 : 0.0
                        let elapsedSinceStart = CFAbsoluteTimeGetCurrent() - videoDiagStartWall
                        let inGracePeriod = elapsedSinceStart < startupGracePeriod
                        if !isFirstVideoFrame && !inGracePeriod {
                            let syncTime = renderer.currentTime
                            let lateness = syncTime - packet.ptsSeconds
                            if lateness > lateVideoDropThreshold {
                                lateVideoObservationCount += 1
                                healthLateFramesSinceReport += 1
                                consecutiveLateVideoFrames += 1

                                let nowWall = CFAbsoluteTimeGetCurrent()
                                let keyframeResyncThreshold = requiresConversion ? 48 : 4
                                let wantsKeyframeResync = packet.isKeyframe && consecutiveLateVideoFrames >= keyframeResyncThreshold
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
                                        healthResyncsSinceReport += 1
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
                                        healthDropsSinceReport += 1
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
                                    healthDropsSinceReport += 1
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
                        await MainActor.run {
                            renderer.jitterStats.recordVideoPTS(ptsSeconds)
                        }
                        await maybePrimePrerollTimeline(ptsSeconds, packet.cmPTS, "video")
                        if !waitingForPrerollStart {
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                if !self.isPlaying && isFirst {
                                    renderer.setRate(0, time: packet.cmPTS)
                                }
                            }
                        }
                        let syncPrepEnd = CFAbsoluteTimeGetCurrent()

                        // Always bypass the video lookahead during preroll.
                        // The lookahead sleep loop blocks on currentTime advancing,
                        // but during preroll rate=0 so time never advances — deadlock.
                        // The display layer's own isReadyForMoreMediaData prevents overflow.
                        let prerollBypassLookahead = waitingForPrerollStart

                        let enqueueStart = CFAbsoluteTimeGetCurrent()
                        await renderer.enqueueVideo(
                            sampleBuffer,
                            bypassLookahead: prerollBypassLookahead
                        )
                        let enqueueEnd = CFAbsoluteTimeGetCurrent()

                        if waitingForPrerollStart {
                            if let maxPTS = prerollMaxPTSSeconds {
                                prerollMaxPTSSeconds = max(maxPTS, ptsSeconds)
                            } else {
                                prerollMaxPTSSeconds = ptsSeconds
                            }
                            // Track video PTS separately for accurate preroll lead
                            if let maxVPTS = prerollMaxVideoPTSSeconds {
                                prerollMaxVideoPTSSeconds = max(maxVPTS, ptsSeconds)
                            } else {
                                prerollMaxVideoPTSSeconds = ptsSeconds
                            }

                            let didStartPreroll = await maybeCompletePrerollStart(ptsSeconds, false)
                            if !didStartPreroll, (videoPacketCount <= 10 || videoPacketCount % 120 == 0) {
                                let audioPrimed = await MainActor.run {
                                    renderer.isAudioPrimedForPlayback
                                }
                                let audioReliableStart = await MainActor.run {
                                    renderer.hasReliableAudioStart
                                }
                                let audioReady = !hasAudioPath || audioPrimed
                                let prerollLeadSeconds: Double = {
                                    guard let anchor = prerollAnchorPTSSeconds, let maxPTS = prerollMaxPTSSeconds else { return 0 }
                                    return max(0, maxPTS - anchor)
                                }()
                                let requiredPrerollLeadSeconds = requiresConversion ? 5.0 : 0.20
                                let waitedMs: Double = {
                                    guard let start = prerollWaitStartWall else { return 0 }
                                    return (CFAbsoluteTimeGetCurrent() - start) * 1000
                                }()
                                print(
                                    "[DirectPlayDiag] Waiting for preroll start: frame=\(videoPacketCount) " +
                                    "pts=\(String(format: "%.3f", ptsSeconds))s audioQ=\(localAudioGate?.snapshot().pending ?? -1) " +
                                    "audioPrimed=\(audioPrimed) audioReady=\(audioReady) reliableStart=\(audioReliableStart) " +
                                    "videoLead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                                    "bypass=\(prerollBypassLookahead) " +
                                    "needLead=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms " +
                                    "wait=\(String(format: "%.0f", waitedMs))ms"
                                )
                            }
                        }

                        let totalPipelineMs = (enqueueEnd - frameWallStart) * 1000
                        if totalPipelineMs > 120 {
                            slowVideoPipelineCount += 1
                            healthSlowFramesSinceReport += 1
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
                            let audioSnapshot = localAudioGate?.snapshot()
                            let audioDecodeSnapshot = localAudioDecodeGate?.snapshot()
                            let audioQueueDepth = audioSnapshot?.pending ?? -1
                            let audioQueueMaxDepth = audioSnapshot?.maxPending ?? -1
                            let audioQueueDrops = audioSnapshot?.dropped ?? -1
                            let audioDecodeQueueDepth = audioDecodeSnapshot?.pending ?? -1
                            let audioDecodeQueueMaxDepth = audioDecodeSnapshot?.maxPending ?? -1
                            let audioDecodeQueueDrops = audioDecodeSnapshot?.dropped ?? -1

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

                        // Periodic health report (every 5s wall time)
                        if nowWall - lastHealthReportWall >= healthReportInterval {
                            // Per-period wall rate (current throughput, not cumulative)
                            let periodWall = nowWall - healthLastPeriodWall
                            let periodStream = ptsSeconds - healthLastPeriodPTS
                            let wallRate = periodWall > 0 ? (periodStream / periodWall) : 1.0
                            let audioSnapshot = localAudioGate?.snapshot()
                            let audioDrops = audioSnapshot?.dropped ?? 0
                            let capturedLate = healthLateFramesSinceReport
                            let capturedDrops = healthDropsSinceReport
                            let capturedResyncs = healthResyncsSinceReport
                            let capturedSlow = healthSlowFramesSinceReport
                            let capturedDispErr = healthDisplayErrorsSinceReport

                            let isClientDecode = audioDecoder != nil
                            let healthResult = await MainActor.run { [weak self] () -> (line: String, totalPullDel: Int)? in
                                guard let self else { return nil }
                                let jitter = self.renderer.jitterStats.healthSnapshot()
                                let status = Int(self.renderer.audioRenderer.status.rawValue)
                                let isPull = self.renderer.useAudioPullMode
                                let syncTime = self.renderer.currentTime
                                let audioAhead = ptsSeconds - syncTime
                                let dispErr = (self.renderer.displayLayerError != nil ? 1 : 0) + capturedDispErr
                                let totalPullDel = self.renderer.totalAudioPullDeliveries
                                let pullDel = totalPullDel - healthLastPullDeliveries
                                let isAirPlay = PlaybackAudioSessionConfigurator.isAirPlayRouteActive()
                                let report = PlaybackHealthReport(
                                    playbackTime: ptsSeconds,
                                    fps: jitter.fps,
                                    wallRate: wallRate,
                                    lateFrames: capturedLate,
                                    droppedFrames: capturedDrops,
                                    resyncs: capturedResyncs,
                                    slowFrames: capturedSlow,
                                    audioStatus: status,
                                    audioPullMode: isPull,
                                    audioAhead: audioAhead,
                                    audioDrops: audioDrops,
                                    audioPath: isClientDecode ? .clientDecode : .passthrough,
                                    audioRoute: isAirPlay ? .airPlay : .hdmi,
                                    audioPullDeliveries: pullDel,
                                    displayErrors: dispErr,
                                    gapMaxMs: jitter.gapMaxMs,
                                    gapStdDevMs: jitter.gapStdDevMs,
                                    syncDriftPercent: jitter.syncDriftPercent
                                )
                                return (report.logLine, totalPullDel)
                            }

                            if let result = healthResult {
                                print(result.line)
                                healthLastPullDeliveries = result.totalPullDel
                            }

                            // Reset per-period counters
                            healthLateFramesSinceReport = 0
                            healthDropsSinceReport = 0
                            healthResyncsSinceReport = 0
                            healthSlowFramesSinceReport = 0
                            healthDisplayErrorsSinceReport = 0
                            healthLastPeriodPTS = ptsSeconds
                            healthLastPeriodWall = nowWall
                            lastHealthReportWall = nowWall
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
                                let reservation = localAudioDecodeGate.reserveSlot()
                                if !reservation.accepted {
                                    let dropped = reservation.dropped
                                    if dropped <= 10 || dropped % 120 == 0 {
                                        print("[DirectPlayDiag] Dropping queued compressed audio packet #\(dropped) " +
                                              "(audioDecQ=\(reservation.depth), limit=\(localAudioDecodeGate.limit))")
                                    }
                                    continue
                                }

                                localAudioDecodeContinuation.yield(packet)
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
                            if audioPacketCount == 1 {
                                let mediaType = CMFormatDescriptionGetMediaType(audioFD)
                                let mediaSubType = CMFormatDescriptionGetMediaSubType(audioFD)
                                let subTypeStr = String(format: "%c%c%c%c",
                                    (mediaSubType >> 24) & 0xFF, (mediaSubType >> 16) & 0xFF,
                                    (mediaSubType >> 8) & 0xFF, mediaSubType & 0xFF)
                                print("[DirectPlay] Audio passthrough FD: mediaType=\(mediaType) subType=\(subTypeStr)(\(mediaSubType))")
                                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFD) {
                                    let a = asbd.pointee
                                    print("[DirectPlay] Audio passthrough ASBD: rate=\(Int(a.mSampleRate)) ch=\(a.mChannelsPerFrame) " +
                                          "bitsPerCh=\(a.mBitsPerChannel) framesPerPkt=\(a.mFramesPerPacket) " +
                                          "bytesPerFrame=\(a.mBytesPerFrame) bytesPerPkt=\(a.mBytesPerPacket) " +
                                          "formatID=\(a.mFormatID) formatFlags=\(a.mFormatFlags)")
                                }
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
                            // Text subtitle (SRT, ASS embedded in MKV)
                            let rawText = String(data: packet.data, encoding: .utf8) ?? ""
                            let text = Self.cleanEmbeddedSubtitleText(rawText)
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
            let summaryAudio = localAudioGate?.snapshot()
            let summaryAudioDec = localAudioDecodeGate?.snapshot()
            let summaryMaxAudioQ = summaryAudio?.maxPending ?? -1
            let summaryAudioDrops = summaryAudio?.dropped ?? -1
            let summaryMaxAudioDecQ = summaryAudioDec?.maxPending ?? -1
            let summaryAudioDecDrops = summaryAudioDec?.dropped ?? -1
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
                renderer.onAudioPrimedForPlayback = nil
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
        if forceClientDecodeAllAudio { return true }
        if Self.codecSet(forceClientDecodeCodecs, matches: codec) {
            return true
        }
        return Self.codecSet(FFmpegAudioDecoder.supportedCodecs, matches: codec)
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
        let normalized = Self.normalizedCodecIdentifier(codec)

        let nativePrefixes = [
            "eac3", "ec3", "ac3",
            "aac", "alac", "flac",
            "mp3", "mp2", "opus", "pcm"
        ]
        return nativePrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0) })
    }

    /// Strip ASS/SSA dialogue metadata from embedded subtitle packets.
    /// FFmpeg returns embedded ASS subtitles as raw dialogue events:
    ///   "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
    /// We need to extract just the Text field (everything after the 8th comma).
    nonisolated private static func cleanEmbeddedSubtitleText(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // ASS event format: 8 metadata fields followed by the text field.
        // The text field is everything after the 8th comma (may itself contain commas).
        let assFieldCount = 8
        var commaCount = 0
        for (i, char) in text.enumerated() {
            if char == "," {
                commaCount += 1
                if commaCount == assFieldCount {
                    // Check that preceding fields look like ASS metadata
                    // (contain a style name like "Default" or digits)
                    let prefix = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: i)])
                    if prefix.contains("Default") || prefix.contains("default") ||
                       prefix.allSatisfy({ $0.isNumber || $0 == "," || $0.isWhitespace }) {
                        text = String(text[text.index(text.startIndex, offsetBy: i + 1)...])
                    }
                    break
                }
            }
        }

        // ASS line breaks
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")

        // Strip ASS override blocks: {\an8}, {\i1}, {\pos(x,y)}, etc.
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)

        // Strip HTML-like tags sometimes present in embedded subs
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nativeTrackScore(_ track: FFmpegTrackInfo) -> Int {
        let codec = Self.normalizedCodecIdentifier(track.codecName)

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

    private static func codecSet(_ candidates: Set<String>, matches codec: String) -> Bool {
        let normalized = normalizedCodecIdentifier(codec)
        return candidates.contains { candidate in
            let candidateKey = normalizedCodecIdentifier(candidate)
            return normalized == candidateKey || normalized.hasPrefix(candidateKey)
        }
    }

    private static func normalizedCodecIdentifier(_ codec: String) -> String {
        codec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
