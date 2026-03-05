//
//  RivuletPlayer.swift
//  Rivulet
//
//  Unified custom video player built on AVSampleBufferDisplayLayer + VideoToolbox.
//  Replaces MPVPlayerWrapper, AVPlayerWrapper, and DVSampleBufferPlayer with a single
//  player that handles all content types through two internal pipelines:
//
//    - DirectPlayPipeline: FFmpeg demuxes containers (MKV/MP4), VideoToolbox decodes
//    - HLSPipeline: For DTS/TrueHD (server transcodes audio) and live TV
//
//  Conforms to PlayerProtocol for seamless integration with UniversalPlayerViewModel.
//

import Foundation
import AVFoundation
import Combine
import CoreMedia

/// Unified player using AVSampleBufferDisplayLayer for all content.
@MainActor
final class RivuletPlayer: ObservableObject {

    // MARK: - Rendering Layer (public for view binding)

    let renderer = SampleBufferRenderer()

    /// The display layer for embedding in a SwiftUI view
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    // MARK: - Publishers

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private let tracksSubject = PassthroughSubject<Void, Never>()

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    var playbackRate: Float = 1.0

    // MARK: - Track Info

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var currentAudioTrackId: Int?
    private(set) var currentSubtitleTrackId: Int?

    // MARK: - Active Pipeline

    /// Which pipeline is currently handling playback
    enum ActivePipeline {
        case none
        case directPlay
        case hls
    }

    private(set) var activePipeline: ActivePipeline = .none
    private var directPlayPipeline: DirectPlayPipeline?
    private var hlsPipeline: HLSPipeline?

    // MARK: - Private State

    private var timeObserverTask: Task<Void, Never>?
    private var streamURL: URL?
    private var loadHeaders: [String: String]?

    // MARK: - Init

    init() {}

    // MARK: - Load (PlayerProtocol)

    /// Load a URL for playback. This is the simple PlayerProtocol entry point.
    /// For routed playback (direct play vs HLS), use `load(route:...)` instead.
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        print("[RivuletPlayer] load(url:) → HLS path: \(url.lastPathComponent)")
        try await loadHLS(url: url, headers: headers, startTime: startTime)
    }

    /// Load an HLS URL with optional DV profile conversion.
    /// Used when the ViewModel knows the content needs RPU conversion (P7/P8.6).
    func loadHLSWithConversion(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool) async throws {
        print("[RivuletPlayer] loadHLS: \(url.lastPathComponent) profileConversion=\(requiresProfileConversion)")
        playbackStateSubject.send(.loading)
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "[RivuletPlayer]"
        )
        try await loadHLS(url: url, headers: headers, startTime: startTime, requiresProfileConversion: requiresProfileConversion)
    }

    // MARK: - Routed Load

    /// Load using a content routing decision.
    /// - Parameters:
    ///   - route: The routing decision (directPlay or hls)
    ///   - startTime: Optional resume position
    ///   - isDolbyVision: Whether Plex metadata confirms DV content (forces dvh1 tagging)
    ///   - enableDVConversion: Enable DV P7/P8.6 → P8.1 conversion
    func load(route: PlaybackRoute, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool = false) async throws {
        playbackStateSubject.send(.loading)

        // Configure audio session
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "[RivuletPlayer]"
        )

        switch route {
        case .directPlay(let url, let headers):
            print("[RivuletPlayer] load(route:) → DirectPlay: \(url.lastPathComponent) DV=\(isDolbyVision)")
            try await loadDirectPlay(url: url, headers: headers, startTime: startTime, isDolbyVision: isDolbyVision, enableDVConversion: enableDVConversion)

        case .hls(let url, let headers):
            print("[RivuletPlayer] load(route:) → HLS: \(url.lastPathComponent)")
            try await loadHLS(url: url, headers: headers, startTime: startTime, requiresProfileConversion: enableDVConversion)
        }
    }

    // MARK: - Private: Load Implementations

    private func loadDirectPlay(url: URL, headers: [String: String]?, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool) async throws {
        cleanupPipelines()

        let pipeline = DirectPlayPipeline(renderer: renderer)
        self.directPlayPipeline = pipeline
        self.activePipeline = .directPlay
        self.streamURL = url
        self.loadHeaders = headers

        // Wire callbacks
        pipeline.onStateChange = { [weak self] state in
            self?.handlePipelineStateChange(state)
        }
        pipeline.onError = { [weak self] error in
            self?.handlePipelineError(error)
        }
        pipeline.onEndOfStream = { [weak self] in
            self?.handleEndOfStream()
        }

        try await pipeline.load(url: url, headers: headers, startTime: startTime, isDolbyVision: isDolbyVision, enableDVConversion: enableDVConversion)

        // Update state from pipeline
        self.duration = pipeline.duration
        self.audioTracks = pipeline.audioTracks
        self.subtitleTracks = pipeline.subtitleTracks
        if let firstAudio = audioTracks.first {
            currentAudioTrackId = firstAudio.id
        }
        tracksSubject.send()

        // Don't send .ready — keep .loading visible until play() sends .playing.
        // This prevents a brief black flash between loading screen hide and first video frame.
        startTimeObserver()
    }

    private func loadHLS(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool = false) async throws {
        cleanupPipelines()

        let pipeline = HLSPipeline(renderer: renderer)
        self.hlsPipeline = pipeline
        self.activePipeline = .hls
        self.streamURL = url

        // Wire callbacks
        pipeline.onStateChange = { [weak self] state in
            self?.handlePipelineStateChange(state)
        }
        pipeline.onError = { [weak self] error in
            self?.handlePipelineError(error)
        }
        pipeline.onEndOfStream = { [weak self] in
            self?.handleEndOfStream()
        }

        try await pipeline.load(url: url, headers: headers, startTime: startTime, requiresProfileConversion: requiresProfileConversion)

        // Update state from pipeline
        self.duration = pipeline.duration
        self.audioTracks = pipeline.audioTracks
        self.subtitleTracks = pipeline.subtitleTracks
        if let firstAudio = audioTracks.first {
            currentAudioTrackId = firstAudio.id
        }
        tracksSubject.send()

        playbackStateSubject.send(.ready)
        startTimeObserver()
    }

    // MARK: - Playback Controls

    func play() {
        guard !isPlaying else {
            print("[RivuletPlayer] play() called but already playing — ignoring")
            return
        }
        isPlaying = true
        print("[RivuletPlayer] play() → \(activePipeline)")

        switch activePipeline {
        case .directPlay:
            directPlayPipeline?.start(rate: playbackRate)
        case .hls:
            hlsPipeline?.start(rate: playbackRate)
        case .none:
            break
        }

        playbackStateSubject.send(.playing)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false

        switch activePipeline {
        case .directPlay:
            directPlayPipeline?.pause()
        case .hls:
            hlsPipeline?.pause()
        case .none:
            break
        }

        playbackStateSubject.send(.paused)
    }

    func stop() {
        let pipelineName: String = switch activePipeline {
        case .directPlay: "directPlay"
        case .hls: "hls"
        case .none: "none"
        }
        print("[RivuletPlayer] stop() pipeline=\(pipelineName)")
        isPlaying = false
        timeObserverTask?.cancel()
        timeObserverTask = nil

        switch activePipeline {
        case .directPlay:
            directPlayPipeline?.stop()
        case .hls:
            hlsPipeline?.stop()
        case .none:
            break
        }

        renderer.flush()
        renderer.setRate(0)

        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        let wasPlaying = isPlaying
        playbackStateSubject.send(.buffering)

        do {
            switch activePipeline {
            case .directPlay:
                try await directPlayPipeline?.seek(to: time, isPlaying: wasPlaying)
            case .hls:
                await hlsPipeline?.seek(to: time, isPlaying: wasPlaying)
            case .none:
                break
            }
        } catch {
            print("[RivuletPlayer] Seek error: \(error)")
        }

        // Ensure UI exits buffering even if pipeline doesn't emit an immediate post-seek state.
        playbackStateSubject.send(wasPlaying ? .playing : .paused)

        // Update current time immediately for UI responsiveness
        currentTime = time
        timeSubject.send(time)
    }

    func seekRelative(by seconds: TimeInterval) async {
        let newTime = max(0, min(currentTime + seconds, duration))
        await seek(to: newTime)
    }

    // MARK: - Track Selection

    func selectAudioTrack(id: Int) {
        currentAudioTrackId = id
        // Note: For DirectPlay, use selectAudioTrack(plexTrackId:plexAudioTracks:) instead
        // to correctly map Plex IDs to FFmpeg stream indices.
        // This bare method is kept for PlayerProtocol conformance and HLS use.
    }

    /// Select audio track by Plex track ID, mapping to FFmpeg stream index by position.
    /// - Parameters:
    ///   - plexTrackId: The Plex stream ID (e.g., 209431)
    ///   - plexAudioTracks: The Plex audio track list from the ViewModel (for position mapping)
    func selectAudioTrack(plexTrackId: Int, plexAudioTracks: [MediaTrack]) {
        currentAudioTrackId = plexTrackId

        if activePipeline == .directPlay, let pipeline = directPlayPipeline {
            let ffmpegAudio = ffmpegAudioTracks

            guard let plexIndex = plexAudioTracks.firstIndex(where: { $0.id == plexTrackId }),
                  plexIndex < ffmpegAudio.count else {
                print("[RivuletPlayer] Cannot map Plex audio track \(plexTrackId) to FFmpeg index " +
                      "(plex tracks=\(plexAudioTracks.count), ffmpeg tracks=\(ffmpegAudio.count))")
                return
            }

            let ffmpegStreamIndex = ffmpegAudio[plexIndex].streamIndex
            print("[RivuletPlayer] Mapped Plex audio \(plexTrackId) → FFmpeg stream \(ffmpegStreamIndex)")
            Task {
                do {
                    try await pipeline.selectAudioTrack(streamIndex: ffmpegStreamIndex)
                } catch {
                    print("[RivuletPlayer] ❌ Audio track switch failed: \(error)")
                }
            }
        }
        // For HLS, audio track switching requires a new HLS stream from Plex
        // with audioStreamID parameter — handled by UniversalPlayerViewModel
    }

    func selectSubtitleTrack(id: Int?) {
        currentSubtitleTrackId = id
    }

    func disableSubtitles() {
        currentSubtitleTrackId = nil
    }

    // MARK: - Embedded Subtitle Selection

    /// The FFmpeg audio track list from the demuxer (for mapping Plex IDs → FFmpeg indices)
    var ffmpegAudioTracks: [FFmpegTrackInfo] {
        directPlayPipeline?.demuxer.audioTracks ?? []
    }

    /// The FFmpeg subtitle track list from the demuxer (for mapping Plex IDs → FFmpeg indices)
    var ffmpegSubtitleTracks: [FFmpegTrackInfo] {
        directPlayPipeline?.demuxer.subtitleTracks ?? []
    }

    /// Set a callback for embedded subtitle cues delivered from the read loop.
    var onSubtitleCue: ((String, TimeInterval, TimeInterval) -> Void)? {
        didSet {
            directPlayPipeline?.onSubtitleCue = onSubtitleCue
        }
    }

    /// Set a callback for bitmap subtitle cues (PGS, DVB-SUB) from the read loop.
    var onBitmapSubtitleCue: ((BitmapSubtitleCue) -> Void)? {
        didSet {
            directPlayPipeline?.onBitmapSubtitleCue = onBitmapSubtitleCue
        }
    }

    /// Enable embedded subtitle extraction for a Plex track ID.
    /// Matches to FFmpeg stream by codec type to handle Plex lists that include
    /// external/sidecar subs not present in the container.
    /// Returns `true` if an embedded FFmpeg match was found, `false` if the track
    /// is likely external and should be fetched via Plex URL instead.
    @discardableResult
    func selectEmbeddedSubtitle(plexTrackId: Int, plexSubtitleTracks: [MediaTrack]) -> Bool {
        guard activePipeline == .directPlay, let pipeline = directPlayPipeline else { return false }

        let ffmpegSubs = ffmpegSubtitleTracks
        guard let plexTrack = plexSubtitleTracks.first(where: { $0.id == plexTrackId }) else { return false }

        let plexCodec = Self.normalizeSubCodec(plexTrack.codec)

        // Count how many Plex subs with the same codec appear before the selected one.
        // This gives us the "Nth track of this codec" position.
        var sameCodecPosition = 0
        for plex in plexSubtitleTracks {
            if plex.id == plexTrackId { break }
            if Self.normalizeSubCodec(plex.codec) == plexCodec {
                sameCodecPosition += 1
            }
        }

        // Find the Nth FFmpeg sub with matching codec
        var matchCount = 0
        for ffmpeg in ffmpegSubs {
            if Self.normalizeSubCodec(ffmpeg.codecName) == plexCodec {
                if matchCount == sameCodecPosition {
                    print("[RivuletPlayer] Mapped Plex subtitle \(plexTrackId) → FFmpeg stream \(ffmpeg.streamIndex) (\(ffmpeg.codecName))")
                    pipeline.selectSubtitleStream(ffmpegStreamIndex: ffmpeg.streamIndex)
                    return true
                }
                matchCount += 1
            }
        }

        // No match — likely an external/sidecar subtitle not in the container
        print("[RivuletPlayer] No FFmpeg match for Plex subtitle \(plexTrackId) " +
              "(\(plexTrack.codec ?? "unknown") \(plexTrack.language ?? "")) — falling back to Plex URL")
        return false
    }

    /// Normalize subtitle codec names between Plex and FFmpeg naming conventions.
    private static func normalizeSubCodec(_ codec: String?) -> String {
        guard let codec = codec?.lowercased() else { return "unknown" }
        switch codec {
        case "subrip", "srt": return "srt"
        case "ass", "ssa": return "ass"
        case "pgs", "hdmv_pgs_subtitle", "pgssub": return "pgs"
        case "dvdsub", "dvd_subtitle": return "dvdsub"
        case "mov_text", "tx3g": return "mov_text"
        case "webvtt", "vtt": return "webvtt"
        default: return codec
        }
    }

    /// Disable embedded subtitle reading.
    func deselectEmbeddedSubtitle() {
        directPlayPipeline?.deselectSubtitleStream()
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        cleanupPipelines()
        currentTime = 0
        duration = 0
        bufferedTime = 0
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackId = nil
        currentSubtitleTrackId = nil
    }

    // MARK: - Private: Pipeline Management

    private func cleanupPipelines() {
        directPlayPipeline?.stop()
        directPlayPipeline = nil
        hlsPipeline?.stop()
        hlsPipeline = nil
        activePipeline = .none

        // Flush the shared renderer so the display layer and audio renderer
        // don't have stale data from a previous pipeline.
        renderer.flush()
        renderer.setRate(0)
    }

    // MARK: - Private: Pipeline Callbacks

    private func handlePipelineStateChange(_ state: PipelineState) {
        switch state {
        case .idle:
            playbackStateSubject.send(.idle)
        case .loading:
            // Only show buffering if we're already playing (mid-stream buffer underrun).
            // During initial load, RivuletPlayer.load() already set .loading.
            if isPlaying {
                playbackStateSubject.send(.buffering)
            }
        case .ready:
            // Suppress during initial load — play() will transition to .playing.
            break
        case .running:
            if isPlaying {
                playbackStateSubject.send(.playing)
            }
        case .paused:
            playbackStateSubject.send(.paused)
        case .seeking:
            playbackStateSubject.send(.buffering)
        case .ended:
            break // Handled by onEndOfStream
        case .failed:
            break // Handled by onError
        }
    }

    private func handlePipelineError(_ error: Error) {
        let playerError: PlayerError
        if let ffmpegError = error as? FFmpegError {
            playerError = .loadFailed(ffmpegError.localizedDescription)
        } else {
            playerError = .networkError(error.localizedDescription)
        }

        isPlaying = false
        playbackStateSubject.send(.failed(playerError))
        errorSubject.send(playerError)
    }

    private func handleEndOfStream() {
        isPlaying = false
        playbackStateSubject.send(.ended)
    }

    // MARK: - Private: Time Observer

    private func startTimeObserver() {
        timeObserverTask?.cancel()

        timeObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

                guard let self = self, !Task.isCancelled else { return }

                let time = self.renderer.currentTime
                let rate = self.renderer.renderSynchronizer.rate
                let playing = self.isPlaying

                if time >= 0 {
                    await MainActor.run {
                        self.currentTime = time
                        self.timeSubject.send(time)
                        self.renderer.jitterStats.recordSynchronizerTime(time, isPlaying: playing, rate: rate)
                        _ = self.renderer.jitterStats.reportIfNeeded()
                    }
                }

                // Update buffered time from active pipeline
                await MainActor.run {
                    switch self.activePipeline {
                    case .directPlay:
                        self.bufferedTime = self.directPlayPipeline?.bufferedTime ?? 0
                    case .hls:
                        self.bufferedTime = self.hlsPipeline?.bufferedTime ?? 0
                    case .none:
                        break
                    }
                }
            }
        }
    }
}

// MARK: - PlayerProtocol Conformance

extension RivuletPlayer: PlayerProtocol {}
