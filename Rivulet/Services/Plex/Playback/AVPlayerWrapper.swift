//
//  AVPlayerWrapper.swift
//  Rivulet
//
//  AVPlayer-based video player for Dolby Vision VOD content
//  Used when "Use AVPlayer for Dolby Vision" setting is enabled
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import Sentry

@MainActor
final class AVPlayerWrapper: NSObject, ObservableObject {

    // MARK: - AVPlayer Components

    @Published private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    // Keep a non-isolated reference for cleanup in deinit
    private nonisolated(unsafe) var _playerForCleanup: AVPlayer?

    /// Resource loader for HLS codec patching (Dolby Vision hvc1 -> dvh1)
    private var resourceLoader: HLSCodecPatchingResourceLoader?
    private let resourceLoaderQueue = DispatchQueue(label: "com.rivulet.AVPlayerResourceLoader")

    /// Local HTTP proxy for DV HLS master playlist patching
    private var dvProxyServer: DVHLSProxyServer?

    // MARK: - Track Management

    private let tracksSubject = PassthroughSubject<Void, Never>()
    private var _audioTracks: [MediaTrack] = []
    private var _subtitleTracks: [MediaTrack] = []
    private var _currentAudioTrackId: Int?
    private var _currentSubtitleTrackId: Int?

    /// Publisher that fires when tracks are updated
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    var audioTracks: [MediaTrack] { _audioTracks }
    var subtitleTracks: [MediaTrack] { _subtitleTracks }
    var currentAudioTrackId: Int? { _currentAudioTrackId }
    var currentSubtitleTrackId: Int? { _currentSubtitleTrackId }

    // MARK: - State

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var errorObservationCancellable = Set<AnyCancellable>()

    private var _duration: TimeInterval = 0
    private var _isMuted: Bool = false
    private var loadingTimeoutTask: Task<Void, Never>?
    private var videoRenderVerificationTask: Task<Void, Never>?
    private var currentStreamURL: URL?
    private var consecutive404Count: Int = 0
    private var last404Time: Date?
    private let max404CountBeforeFail = 8  // Fail after 8 consecutive 404s (increased for seek tolerance)
    private let error404ResetInterval: TimeInterval = 3.0  // Reset counter if 3s between 404s

    // Video rendering detection
    private var hasReceivedVideoFrames: Bool = false
    private var hasVerifiedVideoRendering: Bool = false  // Persists once verified - don't re-verify after seek
    private var lastVideoRect: CGRect = .zero
    private var expectedAspectRatio: CGFloat?  // Set from source metadata if available

    // MARK: - Publishers

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    var isPlaying: Bool {
        player?.rate ?? 0 > 0
    }

    var currentTime: TimeInterval {
        player?.currentTime().seconds ?? 0
    }

    var duration: TimeInterval {
        _duration
    }

    var isMuted: Bool {
        _isMuted
    }

    // MARK: - Initialization

    override init() {
        super.init()
    }

    deinit {
        // Clean up time observer synchronously in deinit
        // Other observers will be cleaned up by ARC
        if let timeObserver = timeObserver, let player = _playerForCleanup {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio Session

    /// Configure and activate the audio session before loading content.
    /// Sets .playback category required for Now Playing integration.
    private func ensureAudioSessionActive() {
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "AVPlayerWrapper"
        )
    }

    // MARK: - Playback Controls

    /// Load a URL for playback
    /// - Parameters:
    ///   - url: The URL to load
    ///   - headers: Optional HTTP headers for the request
    ///   - isLive: Whether this is a live stream (affects buffering behavior)
    ///   - isDolbyVision: Whether this is Dolby Vision content (enables codec tag patching for HLS)
    func load(url: URL, headers: [String: String]?, isLive: Bool = false, isDolbyVision: Bool = false) async throws {

        // Ensure audio session is active before loading
        ensureAudioSessionActive()

        playbackStateSubject.send(.loading)
        currentStreamURL = url
        consecutive404Count = 0  // Reset 404 counter for new load
        last404Time = nil

        // Clean up previous player
        cleanupObservers()
        player?.pause()

        // Create asset with headers if needed
        var options: [String: Any] = [:]

        // For VOD content, use precise duration/timing for accurate seeking
        // For live streams, disable to avoid byte-range requests
        options[AVURLAssetPreferPreciseDurationAndTimingKey] = !isLive

        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset: AVURLAsset

        // For Dolby Vision HLS: Plex outputs dvh1 in the CODECS string which AVPlayer rejects.
        // We run a local HTTP reverse proxy that patches only the master playlist response
        // (dvh1 → hvc1 in CODECS), while all other requests pass through to Plex unmodified.
        // This avoids file:// limitations, resource loader timeouts, and custom URL scheme issues.
        if isDolbyVision {

            // Stop any previous proxy
            dvProxyServer?.stop()

            // Best working mode: master hvc1 (AVPlayer accepts), init hvc1 (matches). Plays as HDR10.
            let proxy = DVHLSProxyServer(upstreamURL: url, headers: headers ?? [:], patchMode: .patchMasterToHVC1)
            dvProxyServer = proxy
            let proxyURL = try proxy.start()

            asset = AVURLAsset(url: proxyURL, options: options)
        } else {
            asset = AVURLAsset(url: url, options: options)
        }
        resourceLoader = nil

        // Create player item
        if isLive {
            // Live streams: don't preload keys that require byte-range requests
            playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [])
            playerItem?.preferredForwardBufferDuration = 4  // Buffer ahead for live
            playerItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        } else {
            // VOD: preload duration for accurate seeking
            playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["duration"])
            // Buffer 30 seconds ahead for high-bitrate HDR content to prevent audio stuttering
            playerItem?.preferredForwardBufferDuration = 30
            playerItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }

        // Enable per-frame HDR display metadata for proper HDR10/HDR10+/DV rendering
        playerItem?.appliesPerFrameHDRDisplayMetadata = true

        // Create or reuse player
        if player == nil {
            let newPlayer = AVPlayer(playerItem: playerItem)
            // For live streams, don't wait - just start playing
            // For VOD, let it buffer appropriately to minimize stalling
            newPlayer.automaticallyWaitsToMinimizeStalling = !isLive
            player = newPlayer
            _playerForCleanup = newPlayer
        } else {
            player?.automaticallyWaitsToMinimizeStalling = !isLive
            player?.replaceCurrentItem(with: playerItem)
        }

        // Apply mute state
        player?.isMuted = _isMuted

        // Setup observers
        setupObservers()

        if isLive {
            // Start playback immediately for live streams
            player?.play()
        } else {
            // For VOD, don't auto-play - let caller control
        }

        // Start loading timeout - if we don't get playback within 10 seconds, fail
        startLoadingTimeout()
    }

    private func startLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }

            // Check if we're still loading after timeout
            if case .loading = self.playbackStateSubject.value {
                print("🎬 AVPlayerWrapper: Loading timeout - stream may be incompatible")

                // Check error log for any clues
                if let errorLog = self.playerItem?.errorLog(),
                   let lastEvent = errorLog.events.last,
                   lastEvent.errorStatusCode != 0 {
                    print("🎬 AVPlayerWrapper: Found error in log: \(lastEvent.errorStatusCode)")

                    // Log to Sentry
                    let timeoutError = NSError(domain: "AVPlayerWrapper", code: lastEvent.errorStatusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Loading timeout with error in log"
                    ])
                    self.logStreamFailureToSentry(
                        error: timeoutError,
                        errorCode: lastEvent.errorStatusCode,
                        errorDomain: lastEvent.errorDomain,
                        isCompatibilityError: true
                    )

                    let message = self.buildCompatibilityErrorMessage()
                    self.playbackStateSubject.send(.failed(.codecUnsupported(message)))
                    self.errorSubject.send(.codecUnsupported(message))
                } else {
                    // Log timeout without specific error
                    let timeoutError = NSError(domain: "AVPlayerWrapper", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Loading timeout - no playback started"
                    ])
                    self.logStreamFailureToSentry(
                        error: timeoutError,
                        errorCode: -1,
                        errorDomain: "AVPlayerWrapper",
                        isCompatibilityError: false
                    )

                    let message = "Stream failed to load. The format may be incompatible with AVPlayer."
                    self.playbackStateSubject.send(.failed(.loadFailed(message)))
                    self.errorSubject.send(.loadFailed(message))
                }
            }
        }
    }

    private func cancelLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
    }

    func play() {
        // Ensure audio session is active before playing
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        // Mute immediately to stop audio (buffer would otherwise drain briefly)
        player?.isMuted = true
        cleanupObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        playerItem = nil
        resourceLoader = nil
        dvProxyServer?.stop()
        dvProxyServer = nil
        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        // Reset 404 counter when seeking - transient 404s are expected while server prepares segments
        consecutive404Count = 0

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        await player?.seek(to: cmTime)
        timeSubject.send(time)
    }

    // MARK: - Audio Control

    func setMuted(_ muted: Bool) {
        _isMuted = muted
        player?.isMuted = muted
    }

    // MARK: - Observers

    private func setupObservers() {
        guard let player = player, let playerItem = playerItem else { return }

        // Observe player rate (playing/paused)
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let rate = player.rate
            let currentState = self.playbackStateSubject.value
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Don't change state if we're already in a terminal state (failed/ended)
                if case .failed = self.playbackStateSubject.value { return }
                if case .ended = self.playbackStateSubject.value { return }

                if rate > 0 {
                    // Playback started - cancel loading timeout
                    self.cancelLoadingTimeout()
                    self.playbackStateSubject.send(.playing)
                    // Start video rendering verification (only on first play, not after seek)
                    if !self.hasVerifiedVideoRendering {
                        self.startVideoRenderVerification()
                    }
                } else if currentState == .playing {
                    self.playbackStateSubject.send(.paused)
                }
            }
        }

        // Observe timeControlStatus for buffering detection
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Don't change state if we're in a terminal state
                if case .failed = self.playbackStateSubject.value { return }
                if case .ended = self.playbackStateSubject.value { return }

                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    let reasonStr = reason?.rawValue ?? "unknown"
                    self.playbackStateSubject.send(.buffering)
                case .playing:
                    // Only transition to playing if we were buffering
                    if case .buffering = self.playbackStateSubject.value {
                        self.playbackStateSubject.send(.playing)
                    }
                case .paused:
                    // Handled by rate observer
                    break
                @unknown default:
                    break
                }
            }
        }

        // Observe player item status
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let status = item.status
            let duration = item.duration.seconds
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self._duration = duration.isFinite ? duration : 0
                    // Log track details for debugging (async to avoid blocking main thread on XPC)
                    let asset = item.asset
                    Task {
                        do {
                            let videoTracks = try await asset.loadTracks(withMediaType: .video)
                            for (index, track) in videoTracks.enumerated() {
                                let formatDescriptions = try await track.load(.formatDescriptions) as? [CMFormatDescription] ?? []
                                let codecType = formatDescriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
                                let codecString = codecType.map { self.fourCCToString($0) } ?? "unknown"
                                let naturalSize = try await track.load(.naturalSize)
                                let nominalFrameRate = try await track.load(.nominalFrameRate)
                                // Cache video codec for error messages (avoids sync XPC call during error handling)
                                if index == 0, let codecType {
                                    self.cachedVideoCodec = self.mapVideoCodecToReadableName(codecType)
                                }
                            }
                        } catch {
                            print("🎬 AVPlayerWrapper: Failed to load video track info: \(error)")
                        }
                    }
                    // Enumerate available audio/subtitle tracks
                    await self.enumerateTracks(for: item)
                    // Don't set playing here - let rate observation handle it
                case .failed:
                    self.cancelLoadingTimeout()
                    let message = error?.localizedDescription ?? "Unknown playback error"
                    print("🎬 AVPlayerWrapper: Playback failed - \(message)")

                    // Check if it's a format/compatibility issue
                    if let nsError = error as? NSError {
                        print("🎬 AVPlayerWrapper: Error domain: \(nsError.domain), code: \(nsError.code)")
                        // -12939 = byte-range not supported
                        // -11850 = operation interrupted
                        // -11819/-11821 = cannot decode
                        // Only treat specific codes as compatibility errors; generic CoreMedia errors are usually transient
                        let isCompatibilityError = nsError.code == -12939 || nsError.code == -11850 || nsError.code == -11819 || nsError.code == -11821

                        // Log to Sentry
                        self.logStreamFailureToSentry(
                            error: nsError,
                            errorCode: nsError.code,
                            errorDomain: nsError.domain,
                            isCompatibilityError: isCompatibilityError
                        )

                        if isCompatibilityError {
                            let compatMessage = self.buildCompatibilityErrorMessage()
                            self.playbackStateSubject.send(.failed(.codecUnsupported(compatMessage)))
                            self.errorSubject.send(.codecUnsupported(compatMessage))
                            return
                        }

                        // Categorize as loadFailed for stream/server errors
                        let playerError: PlayerError = if nsError.domain == "CoreMediaErrorDomain" || nsError.domain == "NSURLErrorDomain" {
                            .loadFailed(message)
                        } else {
                            .unknown(message)
                        }
                        self.playbackStateSubject.send(.failed(playerError))
                        self.errorSubject.send(playerError)
                        return
                    }
                    self.playbackStateSubject.send(.failed(.loadFailed(message)))
                    self.errorSubject.send(.loadFailed(message))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Also observe the player item's error property directly for immediate errors
        playerItem.publisher(for: \.error)
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                print("🎬 AVPlayerWrapper: Player item error observed - \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cancelLoadingTimeout()

                    // Handle error regardless of current state (error can occur after playback starts)
                    // Skip if already in failed state
                    if case .failed = self.playbackStateSubject.value { return }

                    let nsError = error as NSError
                    print("🎬 AVPlayerWrapper: Error details - domain: \(nsError.domain), code: \(nsError.code)")

                    // Non-fatal quirks: bandwidth variance, init segment variance, and remote XPC notices
                    if nsError.domain == "CoreMediaErrorDomain" &&
                        (nsError.code == -12318 || nsError.code == 1852797029 || nsError.code == -50) {
                        print("🎬 AVPlayerWrapper: Non-fatal CoreMedia warning (bandwidth/variant/init segment) - continuing playback")
                        return
                    }
                    if nsError.domain == "NSOSStatusErrorDomain" && nsError.code == -12860 {
                        print("🎬 AVPlayerWrapper: Non-fatal PlayerRemoteXPC warning - continuing playback")
                        return
                    }

                    // Check for compatibility/format errors
                    // Only treat specific known codes as compatibility issues
                    // -12939 = byte-range not supported
                    // -11850 = operation interrupted (often due to format issues)
                    // -11819/-11821 = cannot decode
                    let isCompatibilityError = nsError.code == -12939 || nsError.code == -11850 || nsError.code == -11819 || nsError.code == -11821

                    // Log to Sentry
                    self.logStreamFailureToSentry(
                        error: error,
                        errorCode: nsError.code,
                        errorDomain: nsError.domain,
                        isCompatibilityError: isCompatibilityError
                    )

                    if isCompatibilityError {
                        let message = self.buildCompatibilityErrorMessage()
                        print("🎬 AVPlayerWrapper: Setting state to FAILED (codec unsupported) - \(message)")
                        self.playbackStateSubject.send(.failed(.codecUnsupported(message)))
                        self.errorSubject.send(.codecUnsupported(message))
                    } else {
                        let playerError: PlayerError = if nsError.domain == "CoreMediaErrorDomain" || nsError.domain == "NSURLErrorDomain" {
                            .loadFailed(error.localizedDescription)
                        } else {
                            .unknown(error.localizedDescription)
                        }
                        print("🎬 AVPlayerWrapper: Setting state to FAILED (\(playerError))")
                        self.playbackStateSubject.send(.failed(playerError))
                        self.errorSubject.send(playerError)
                    }
                }
            }
            .store(in: &errorObservationCancellable)

        // Observe time updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.timeSubject.send(seconds)
            }
        }

        // Observe buffering
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemPlaybackStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidPlayToEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem
        )

        // Observe error log entries (captures HTTP errors like -12939)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemNewErrorLogEntry),
            name: .AVPlayerItemNewErrorLogEntry,
            object: playerItem
        )

        // Observe access log for debugging
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemNewAccessLogEntry),
            name: .AVPlayerItemNewAccessLogEntry,
            object: playerItem
        )
    }

    private func cleanupObservers() {
        cancelLoadingTimeout()
        cancelVideoRenderVerification()

        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        statusObservation?.invalidate()
        statusObservation = nil

        rateObservation?.invalidate()
        rateObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        errorObservationCancellable.removeAll()

        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    @objc private func playerItemPlaybackStalled() {
        playbackStateSubject.send(.buffering)
    }

    @objc private func playerItemDidPlayToEnd() {
        playbackStateSubject.send(.ended)
    }

    @objc private func playerItemFailedToPlayToEnd(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("🎬 AVPlayerWrapper: Failed to play to end: \(error.localizedDescription)")
            let nsError = error as NSError

            // Ignore known non-fatal bandwidth/variant warnings so playback can continue
            if nsError.domain == "CoreMediaErrorDomain" &&
                (nsError.code == -12318 || nsError.code == 1852797029 || nsError.code == -50) {
                print("🎬 AVPlayerWrapper: Ignoring CoreMedia bandwidth/variant warning on end notification")
                return
            }
            if nsError.domain == "NSOSStatusErrorDomain" && nsError.code == -12860 {
                print("🎬 AVPlayerWrapper: Ignoring PlayerRemoteXPC warning on end notification")
                return
            }

            playbackStateSubject.send(.failed(.unknown(error.localizedDescription)))
            errorSubject.send(.unknown(error.localizedDescription))
        }
    }

    @objc private func playerItemNewErrorLogEntry(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let errorLog = playerItem.errorLog(),
              let lastEvent = errorLog.events.last else { return }

        let errorCode = lastEvent.errorStatusCode
        let errorDomain = lastEvent.errorDomain
        let errorComment = lastEvent.errorComment ?? "No details"

        print("🎬 AVPlayerWrapper: Error log entry - Code: \(errorCode), Domain: \(errorDomain), Comment: \(errorComment)")

        // Check for fatal HTTP errors
        // -12939 = byte-range not supported (common with IPTV proxies)
        // -12938 = content not found
        // -12937 = connection failed
        if errorCode == -12939 {
            let message = "Stream format is incompatible with AVPlayer."
            playbackStateSubject.send(.failed(.codecUnsupported(message)))
            errorSubject.send(.codecUnsupported(message))
        } else if errorCode == -12938 {
            // Content-not-found (HTTP 404) - track consecutive occurrences
            // A few 404s can be transient (especially after seeking), but many rapid consecutive ones
            // indicate the transcode isn't working

            // Reset counter if it's been a while since the last 404 (not a burst)
            let now = Date()
            if let lastTime = last404Time, now.timeIntervalSince(lastTime) > error404ResetInterval {
                consecutive404Count = 0
            }
            last404Time = now

            consecutive404Count += 1
            if consecutive404Count >= max404CountBeforeFail {
                print("🎬 AVPlayerWrapper: Too many consecutive 404 errors (\(consecutive404Count)) - transcode failed")
                let message = "HLS transcode failed - segments not available"
                playbackStateSubject.send(.failed(.loadFailed(message)))
                errorSubject.send(.loadFailed(message))
            } else {
                print("🎬 AVPlayerWrapper: Warning - content-not-found (\(consecutive404Count)/\(max404CountBeforeFail))")
            }
        } else if errorCode == -12318 {
            // Segment reported higher bandwidth than variant; warn but don't fail playback
            print("🎬 AVPlayerWrapper: Warning - segment exceeds declared variant bandwidth (continuing)")
        } else if errorCode < 0 && errorCode > -13000 {
            // Other HTTP/network errors in this range
            let message = "Stream error: \(errorComment) (code \(errorCode))"
            playbackStateSubject.send(.failed(.networkError(message)))
            errorSubject.send(.networkError(message))
        }
    }

    @objc private func playerItemNewAccessLogEntry(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let accessLog = playerItem.accessLog(),
              let lastEvent = accessLog.events.last else { return }

        // Log successful connection for debugging
        if lastEvent.numberOfBytesTransferred > 0 {
            // Reset 404 counter on successful data transfer
            if consecutive404Count > 0 {
                consecutive404Count = 0
                last404Time = nil
            }
        }
    }

    // MARK: - Video Rendering Detection

    /// Called by AVPlayerUIView when rendering status changes
    func handleRenderingStatusChanged(isReady: Bool, videoRect: CGRect) {
        lastVideoRect = videoRect

        if isReady {
            // Check if we actually have video rendering (non-zero video rect)
            let hasValidVideoRect = videoRect.width > 10 && videoRect.height > 10
            if hasValidVideoRect {
                let renderedAspectRatio = videoRect.width / videoRect.height

                // Check for aspect ratio mismatch which indicates decoder failure
                // Most modern video content (movies/TV) has aspect ratio >= 1.5 (3:2)
                // A 4:3 (1.33) aspect ratio for DV content is almost certainly wrong
                if let expected = expectedAspectRatio {
                    let aspectDiff = abs(renderedAspectRatio - expected) / expected
                    if aspectDiff > 0.25 {  // More than 25% difference
                        print("🎬 AVPlayerWrapper: ASPECT RATIO MISMATCH - rendered=\(String(format: "%.2f", renderedAspectRatio)), expected=\(String(format: "%.2f", expected))")
                        print("🎬 AVPlayerWrapper: This indicates decoder failure - frames may be blank")
                        // Don't confirm rendering - let verification timeout trigger fallback
                        return
                    }
                }

                // Additional heuristic: if aspect ratio is suspiciously narrow (< 1.5) for video content
                // This catches cases where we don't have expected aspect ratio but the output looks wrong
                // 4:3 = 1.33 which is unusual for modern DV content
                if renderedAspectRatio < 1.4 {
                    print("🎬 AVPlayerWrapper: WARNING - Suspiciously narrow aspect ratio \(String(format: "%.2f", renderedAspectRatio)) - may indicate decoder issues")
                    // Don't confirm rendering for narrow aspect ratio - let timeout handle it
                    return
                }

                hasReceivedVideoFrames = true
                hasVerifiedVideoRendering = true  // Persist - don't re-verify after seek
                // Cancel verification timeout since video is rendering
                videoRenderVerificationTask?.cancel()
                videoRenderVerificationTask = nil
            } else {
                // isReadyForDisplay=true but videoRect is empty/invalid - suspicious
                print("🎬 AVPlayerWrapper: WARNING - isReadyForDisplay=true but videoRect is invalid: \(videoRect)")
            }
        }
    }

    /// Set expected aspect ratio from source video metadata
    func setExpectedAspectRatio(width: Int, height: Int) {
        guard height > 0 else { return }
        expectedAspectRatio = CGFloat(width) / CGFloat(height)
    }

    /// Start verification that video is actually rendering after playback starts
    private func startVideoRenderVerification() {
        videoRenderVerificationTask?.cancel()
        hasReceivedVideoFrames = false

        videoRenderVerificationTask = Task { [weak self] in
            // Wait 3 seconds for video to start rendering
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }

            // Check if we're playing but haven't received video frames
            if case .playing = self.playbackStateSubject.value {
                if !self.hasReceivedVideoFrames {
                    print("🎬 AVPlayerWrapper: Video rendering verification FAILED - playback active but no video frames after 3 seconds")

                    // Check the last known video rect
                    if self.lastVideoRect.width < 10 || self.lastVideoRect.height < 10 {
                        print("🎬 AVPlayerWrapper: Video rect is empty/invalid: \(self.lastVideoRect)")
                    }

                    // Gather additional diagnostics for Sentry (Fixes RIVULET-1K)
                    let diagnostics = await self.gatherRenderFailureDiagnostics()

                    // Log to Sentry with enhanced diagnostics
                    let renderError = NSError(domain: "AVPlayerWrapper", code: -1001, userInfo: [
                        NSLocalizedDescriptionKey: "Video rendering verification failed - no video frames"
                    ])
                    self.logRenderFailureToSentry(
                        error: renderError,
                        diagnostics: diagnostics
                    )

                    // Report as codec/rendering failure to trigger fallback
                    let message = "AVPlayer failed to render video frames. This Dolby Vision content may require MPV."
                    self.playbackStateSubject.send(.failed(.codecUnsupported(message)))
                    self.errorSubject.send(.codecUnsupported(message))
                }
            }
        }
    }

    /// Gather diagnostic info when video fails to render (for RIVULET-1K)
    private func gatherRenderFailureDiagnostics() async -> [String: Any] {
        var diagnostics: [String: Any] = [
            "video_rect": "\(lastVideoRect)",
            "has_received_frames": hasReceivedVideoFrames,
            "cached_video_codec": cachedVideoCodec ?? "unknown"
        ]

        if let item = playerItem {
            diagnostics["player_item_status"] = item.status.rawValue
            diagnostics["player_item_duration"] = item.duration.seconds
            diagnostics["player_item_current_time"] = item.currentTime().seconds

            // Check video tracks
            let asset = item.asset
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                diagnostics["video_track_count"] = videoTracks.count

                if let firstTrack = videoTracks.first {
                    let size = try await firstTrack.load(.naturalSize)
                    diagnostics["video_natural_size"] = "\(Int(size.width))x\(Int(size.height))"

                    let formatDescs = try await firstTrack.load(.formatDescriptions) as? [CMFormatDescription] ?? []
                    if let desc = formatDescs.first {
                        let codecType = CMFormatDescriptionGetMediaSubType(desc)
                        diagnostics["video_codec_fourcc"] = fourCCToString(codecType)
                    }
                }
            } catch {
                diagnostics["track_load_error"] = error.localizedDescription
            }

            // Check if there are audio tracks (stream might be audio-only)
            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                diagnostics["audio_track_count"] = audioTracks.count
            } catch {
                diagnostics["audio_track_error"] = error.localizedDescription
            }
        }

        if let url = currentStreamURL {
            diagnostics["stream_host"] = url.host ?? "unknown"
            diagnostics["stream_path"] = url.path
            diagnostics["is_transcode"] = url.path.contains("transcode")
        }

        return diagnostics
    }

    /// Log render failure with enhanced diagnostics
    private func logRenderFailureToSentry(error: Error, diagnostics: [String: Any]) {
        let event = Event(level: .error)

        var messageParts: [String] = ["AVPlayer stream failed"]
        messageParts.append("Error: \(error.localizedDescription)")
        messageParts.append("Code: -1001")
        if let codec = diagnostics["video_codec_fourcc"] as? String {
            messageParts.append("Codec: \(codec)")
        }
        if let host = diagnostics["stream_host"] as? String {
            messageParts.append("Host: \(host)")
        }
        messageParts.append("(Compatibility issue)")

        event.message = SentryMessage(formatted: messageParts.joined(separator: " | "))

        event.tags = [
            "component": "avplayer",
            "error_code": "-1001",
            "error_domain": "AVPlayerWrapper",
            "is_compatibility_error": "true"
        ]

        // Add codec tag if available
        if let codec = diagnostics["video_codec_fourcc"] as? String {
            event.tags?["video_codec"] = codec
        }

        // Add track count tag for filtering
        if let trackCount = diagnostics["video_track_count"] as? Int {
            event.tags?["video_track_count"] = String(trackCount)
        }

        event.fingerprint = ["avplayer", "no-video-frames"]
        event.extra = diagnostics

        SentrySDK.capture(event: event)
    }

    private func cancelVideoRenderVerification() {
        videoRenderVerificationTask?.cancel()
        videoRenderVerificationTask = nil
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        _duration = 0
        _isMuted = false
        currentStreamURL = nil
        consecutive404Count = 0
        last404Time = nil
        hasReceivedVideoFrames = false
        hasVerifiedVideoRendering = false
        lastVideoRect = .zero
        expectedAspectRatio = nil
        _audioTracks = []
        _subtitleTracks = []
        _currentAudioTrackId = nil
        _currentSubtitleTrackId = nil
        playbackStateSubject.send(.idle)
        timeSubject.send(0)
    }

    // MARK: - Track Management

    /// Enumerate audio and subtitle tracks from AVMediaSelectionGroup
    private func enumerateTracks(for item: AVPlayerItem) async {
        let asset = item.asset

        // Cache audio format info from asset tracks (codec FourCC, channels) before building MediaTracks
        await cacheAudioFormatInfo(from: asset)

        // Get audio tracks (use async API to avoid blocking main thread on XPC)
        do {
            let audioGroup = try await asset.loadMediaSelectionGroup(for: .audible)
            if let audioGroup {
                // Log raw AVMediaSelectionOption details for audio diagnostics

                // Log audio track format descriptions from AVAssetTrack (has codec details)
                let audioAssetTracks = try await asset.loadTracks(withMediaType: .audio)
                for (i, track) in audioAssetTracks.enumerated() {
                    let formatDescriptions = try await track.load(.formatDescriptions) as? [CMFormatDescription] ?? []
                    for desc in formatDescriptions {
                        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                        let fourCC = fourCCToString(mediaSubType)
                        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                            let bd = asbd.pointee
                        }
                        var layoutSize: Int = 0
                        if let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &layoutSize) {
                            let tag = layout.pointee.mChannelLayoutTag
                            let channelCount = AudioChannelLayoutTag_GetNumberOfChannels(tag)
                        }
                    }
                }

                _audioTracks = audioGroup.options.enumerated().compactMap { index, option in
                    mediaTrack(from: option, id: index, isAudio: true)
                }

                // Determine currently selected audio track
                if let selectedOption = item.currentMediaSelection.selectedMediaOption(in: audioGroup),
                   let index = audioGroup.options.firstIndex(of: selectedOption) {
                    _currentAudioTrackId = index
                } else if !_audioTracks.isEmpty {
                    _currentAudioTrackId = 0  // Default to first track
                }

            } else {
            }
        } catch {
            print("🔊 [Audio] Failed to load audio tracks: \(error)")
        }

        // Get subtitle/legible tracks
        do {
            let subtitleGroup = try await asset.loadMediaSelectionGroup(for: .legible)
            if let subtitleGroup {
                _subtitleTracks = subtitleGroup.options.enumerated().compactMap { index, option in
                    // Filter out closed captions if they're duplicates (AVPlayer often includes both)
                    mediaTrack(from: option, id: index, isAudio: false)
                }

                // Determine currently selected subtitle track
                if let selectedOption = item.currentMediaSelection.selectedMediaOption(in: subtitleGroup),
                   let index = subtitleGroup.options.firstIndex(of: selectedOption) {
                    _currentSubtitleTrackId = index
                } else {
                    _currentSubtitleTrackId = nil  // Subtitles off by default
                }

            }
        } catch {
            print("🎬 AVPlayerWrapper: Failed to load subtitle tracks: \(error)")
        }

        // Notify subscribers that tracks are available
        tracksSubject.send()
    }

    /// Convert AVMediaSelectionOption to MediaTrack
    private func mediaTrack(from option: AVMediaSelectionOption, id: Int, isAudio: Bool) -> MediaTrack? {
        let locale = option.locale
        let languageCode = locale?.language.languageCode?.identifier
        let language = locale.flatMap { Locale.current.localizedString(forLanguageCode: $0.language.languageCode?.identifier ?? "") }

        // Get display name
        let displayName = option.displayName

        // Determine codec from media type
        let codec: String?
        if isAudio {
            // Try to get codec from format descriptions
            codec = extractAudioCodec(from: option)
        } else {
            codec = extractSubtitleCodec(from: option)
        }

        // Check characteristics for subtitle flags
        let isForced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        let isHearingImpaired = option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)

        // Get channel count for audio
        let channels: Int? = isAudio ? extractChannelCount(from: option) : nil

        return MediaTrack(
            id: id,
            name: displayName,
            language: language,
            languageCode: languageCode,
            codec: codec,
            isDefault: false,  // AVPlayer doesn't expose this directly
            isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            channels: channels
        )
    }

    /// Extract audio codec from AVMediaSelectionOption
    /// Uses cached format info from asset tracks when available, falls back to display name
    private func extractAudioCodec(from option: AVMediaSelectionOption) -> String? {
        // Check cached codec from asset track format descriptions (set in enumerateTracks)
        if let cached = cachedAudioCodec {
            return cached
        }

        // Fallback: infer from display name
        let displayName = option.displayName.lowercased()
        if displayName.contains("dolby") || displayName.contains("atmos") {
            return "eac3"
        } else if displayName.contains("dts") {
            return "dts"
        } else if displayName.contains("ac3") || displayName.contains("ac-3") {
            return "ac3"
        } else if displayName.contains("stereo") || displayName.contains("aac") {
            return "aac"
        }

        return option.mediaType == .audio ? "aac" : nil
    }

    /// Cached audio codec and channel count extracted from AVAssetTrack format descriptions
    private var cachedAudioCodec: String?
    private var cachedAudioChannels: Int?
    /// Cached video codec for error messages (avoids sync XPC call during error handling)
    private var cachedVideoCodec: String?

    /// Extract audio codec and channel info from AVAssetTrack format descriptions
    /// Call this before building MediaTrack objects
    private func cacheAudioFormatInfo(from asset: AVAsset) async {
        cachedAudioCodec = nil
        cachedAudioChannels = nil

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = audioTracks.first else { return }
            let formatDescriptions = try await track.load(.formatDescriptions) as? [CMFormatDescription]
            guard let desc = formatDescriptions?.first else { return }

            let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)

            // Map FourCC to codec name
            switch mediaSubType {
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                 kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
                cachedAudioCodec = "aac"
            case kAudioFormatAC3:
                cachedAudioCodec = "ac3"
            case kAudioFormatEnhancedAC3:
                cachedAudioCodec = "eac3"
            case kAudioFormatAppleLossless:
                cachedAudioCodec = "alac"
            case kAudioFormatLinearPCM:
                cachedAudioCodec = "pcm"
            case kAudioFormatFLAC:
                cachedAudioCodec = "flac"
            case kAudioFormatOpus:
                cachedAudioCodec = "opus"
            default:
                let fourCC = fourCCToString(mediaSubType)
            }

            // Extract channel count from ASBD
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                let channels = Int(asbd.pointee.mChannelsPerFrame)
                if channels > 0 {
                    cachedAudioChannels = channels
                }
            }

        } catch {
            print("🔊 [Audio] Failed to cache audio format info: \(error)")
        }
    }

    /// Extract subtitle codec from AVMediaSelectionOption
    private func extractSubtitleCodec(from option: AVMediaSelectionOption) -> String? {
        let displayName = option.displayName.lowercased()

        if displayName.contains("cc") || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) {
            return "cc_dec"
        } else if displayName.contains("sdh") {
            return "subrip"
        }

        // Default subtitle type
        return "subrip"
    }

    /// Extract channel count from AVMediaSelectionOption
    private func extractChannelCount(from option: AVMediaSelectionOption) -> Int? {
        // Use cached channel count from asset track format descriptions
        if let cached = cachedAudioChannels {
            return cached
        }

        // Fallback: parse from display name
        let displayName = option.displayName.lowercased()
        if displayName.contains("7.1") || displayName.contains("atmos") {
            return 8
        } else if displayName.contains("5.1") {
            return 6
        } else if displayName.contains("stereo") || displayName.contains("2.0") {
            return 2
        } else if displayName.contains("mono") {
            return 1
        }

        return nil
    }

    /// Select an audio track by ID
    func selectAudioTrack(id: Int) {
        guard let playerItem = playerItem,
              let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              id >= 0 && id < audioGroup.options.count else {
            print("🎬 AVPlayerWrapper: Invalid audio track ID: \(id)")
            return
        }

        let option = audioGroup.options[id]
        playerItem.select(option, in: audioGroup)
        _currentAudioTrackId = id
    }

    /// Select a subtitle track by ID, or nil to disable subtitles
    func selectSubtitleTrack(id: Int?) {
        guard let playerItem = playerItem,
              let subtitleGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            print("🎬 AVPlayerWrapper: No subtitle group available")
            return
        }

        if let id = id, id >= 0 && id < subtitleGroup.options.count {
            let option = subtitleGroup.options[id]
            playerItem.select(option, in: subtitleGroup)
            _currentSubtitleTrackId = id
        } else {
            // Disable subtitles
            playerItem.select(nil, in: subtitleGroup)
            _currentSubtitleTrackId = nil
        }
    }

    /// Disable subtitles
    func disableSubtitles() {
        selectSubtitleTrack(id: nil)
    }

    // MARK: - Codec Detection

    /// Maps a video codec FourCC to a human-readable name
    private func mapVideoCodecToReadableName(_ codecType: FourCharCode) -> String {
        switch codecType {
        case kCMVideoCodecType_H264:
            return "H.264/AVC"
        case kCMVideoCodecType_HEVC:
            return "H.265/HEVC"
        case kCMVideoCodecType_MPEG4Video:
            return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video:
            return "MPEG-2"
        case kCMVideoCodecType_VP9:
            return "VP9"
        default:
            return fourCCToString(codecType)
        }
    }

    /// Returns cached codec info (populated async during readyToPlay)
    /// This avoids blocking the main thread on XPC calls during error handling
    private func detectCodecInfo() -> String? {
        return cachedVideoCodec
    }

    /// Converts a FourCC code to a readable string
    private func fourCCToString(_ code: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// Builds error message with codec info if available
    private func buildCompatibilityErrorMessage() -> String {
        if let codec = detectCodecInfo() {
            return "Codec '\(codec)' is incompatible with AVPlayer. Disable 'Use AVPlayer for Dolby Vision' in Settings."
        } else {
            return "This format is incompatible with AVPlayer. Disable 'Use AVPlayer for Dolby Vision' in Settings."
        }
    }

    // MARK: - Sentry Logging

    private func logStreamFailureToSentry(error: Error, errorCode: Int, errorDomain: String, isCompatibilityError: Bool) {
        let event = Event(level: .error)

        // Build a more informative message
        var messageParts: [String] = ["AVPlayer stream failed"]
        messageParts.append("Error: \(error.localizedDescription)")
        messageParts.append("Code: \(errorCode)")
        if let codec = detectCodecInfo() {
            messageParts.append("Codec: \(codec)")
        }
        if let host = currentStreamURL?.host {
            messageParts.append("Host: \(host)")
        }
        if isCompatibilityError {
            messageParts.append("(Compatibility issue)")
        }

        event.message = SentryMessage(formatted: messageParts.joined(separator: " | "))

        // Add tags
        event.tags = [
            "component": "avplayer",
            "error_code": String(errorCode),
            "error_domain": errorDomain,
            "is_compatibility_error": String(isCompatibilityError)
        ]

        // Fingerprint by error category so different AVPlayer errors create separate issues
        let errorCategory = categorizeAVPlayerError(errorCode: errorCode, errorDomain: errorDomain)
        event.fingerprint = ["avplayer", errorCategory]

        // Add extra context
        var extras: [String: Any] = [
            "error_description": error.localizedDescription,
            "error_code": errorCode,
            "error_domain": errorDomain
        ]

        // Add detected codec info
        if let codec = detectCodecInfo() {
            extras["detected_codec"] = codec
            event.tags?["codec"] = codec
        }

        if let url = currentStreamURL {
            // Redact the full URL but keep useful parts
            extras["stream_host"] = url.host ?? "unknown"
            extras["stream_path"] = url.path
            extras["stream_scheme"] = url.scheme ?? "unknown"
        }

        // Add player item info if available
        if let item = playerItem {
            extras["player_item_status"] = String(describing: item.status.rawValue)
            if let asset = item.asset as? AVURLAsset {
                extras["asset_url_scheme"] = asset.url.scheme ?? "unknown"
            }
        }

        event.extra = extras

        SentrySDK.capture(event: event)
    }

    /// Categorizes AVPlayer errors for Sentry fingerprinting
    private func categorizeAVPlayerError(errorCode: Int, errorDomain: String) -> String {
        // Network/URL errors (NSURLErrorDomain)
        if errorDomain == "NSURLErrorDomain" || errorDomain.contains("NSURLError") {
            switch errorCode {
            case -1008: return "resource-unavailable"
            case -1009: return "no-internet"
            case -1001: return "timeout"
            case -1200, -1201, -1202, -1203, -1204, -1205, -1206: return "ssl-error"
            case -999: return "cancelled"
            default: return "network-\(errorCode)"
            }
        }

        // CoreMedia errors
        if errorDomain == "CoreMediaErrorDomain" || errorDomain.contains("CoreMedia") {
            switch errorCode {
            case -12939: return "byte-range-unsupported"
            case -12938: return "content-not-found"
            case -12937: return "connection-failed"
            case -12927: return "format-unsupported"
            case -12318: return "bandwidth-exceeded"
            case -50: return "invalid-parameter"
            default: return "coremedia-\(errorCode)"
            }
        }

        // AVFoundation errors
        if errorDomain == "AVFoundationErrorDomain" {
            switch errorCode {
            case -11800: return "unknown-avfoundation"
            case -11819, -11821: return "cannot-decode"
            case -11828: return "cannot-open"
            case -11829: return "content-not-playable"
            case -11839: return "content-not-authorized"
            case -11850: return "operation-interrupted"
            case -11868: return "cannot-open-file"
            default: return "avfoundation-\(errorCode)"
            }
        }

        // Fallback for unknown domains
        return "\(errorDomain)-\(errorCode)"
    }
}
