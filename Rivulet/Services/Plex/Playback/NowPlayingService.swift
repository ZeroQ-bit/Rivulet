//
//  NowPlayingService.swift
//  Rivulet
//
//  Service for integrating with system Now Playing center.
//  Updates MPNowPlayingInfoCenter and handles MPRemoteCommandCenter events.
//

import Foundation
import MediaPlayer
import AVFoundation
import Combine
import UIKit

/// Service that manages system Now Playing integration.
/// Updates the Now Playing info center and handles remote command events.
@MainActor
final class NowPlayingService: ObservableObject {

    // MARK: - Singleton

    static let shared = NowPlayingService()

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: UniversalPlayerViewModel?
    private var artworkTask: Task<Void, Never>?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkURL: String?
    private var interruptionObserver: NSObjectProtocol?
    private var inputCoordinator: PlaybackInputCoordinator?
    private var nowPlayingSession: MPNowPlayingSession?
    private var nowPlayingSessionAnchorPlayer: AVPlayer?
    private var lastHandledPlaybackState: UniversalPlaybackState?
    /// Track if we've set Now Playing info with valid duration (> 0)
    /// This prevents the system from ignoring our Now Playing registration
    private var hasValidNowPlayingInfo: Bool = false

    // MARK: - Initialization

    private init() {
        // Don't configure audio session here - do it when attaching to a player
        // Configuring at app launch causes OSStatus error -50
        setupInterruptionHandling()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session Configuration

    /// Ensure audio session is active before setting Now Playing info.
    /// This is required for tvOS to register us as the Now Playing app.
    private func ensureAudioSessionActive() {
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "NowPlaying"
        )
    }

    private func shouldUseExplicitNowPlayingSession(for playerType: PlayerType) -> Bool {
        switch playerType {
        case .avplayer:
            return false
        case .mpv, .dvSampleBuffer, .rivulet:
            return true
        }
    }

    /// Custom playback pipelines (MPV/DV sample buffer) don't have a native AVPlayer-backed
    /// now playing session, so create a lightweight anchor session to improve system discoverability.
    private func configureNowPlayingSession(for playerType: PlayerType) {
        guard shouldUseExplicitNowPlayingSession(for: playerType) else {
            deactivateNowPlayingSession()
            return
        }

        guard #available(tvOS 14.0, iOS 16.0, *) else { return }

        if nowPlayingSession == nil {
            let anchorPlayer = AVPlayer()
            let session = MPNowPlayingSession(players: [anchorPlayer])
            session.automaticallyPublishesNowPlayingInfo = false
            nowPlayingSessionAnchorPlayer = anchorPlayer
            nowPlayingSession = session
            // Configure remote commands on the session's command center
            // This is required on tvOS 14+ for commands from other Apple devices
            configureRemoteCommands(on: session.remoteCommandCenter)
        }

        nowPlayingSession?.becomeActiveIfPossible { isActive in
        }
    }

    private func deactivateNowPlayingSession() {
        guard nowPlayingSession != nil || nowPlayingSessionAnchorPlayer != nil else { return }
        nowPlayingSession = nil
        nowPlayingSessionAnchorPlayer = nil
    }

    private var infoCenters: [MPNowPlayingInfoCenter] {
        var centers: [MPNowPlayingInfoCenter] = []
        var seen = Set<ObjectIdentifier>()

        func appendUnique(_ center: MPNowPlayingInfoCenter) {
            let identifier = ObjectIdentifier(center)
            guard seen.insert(identifier).inserted else { return }
            centers.append(center)
        }

        appendUnique(MPNowPlayingInfoCenter.default())
        if #available(tvOS 14.0, iOS 16.0, *), let nowPlayingSession {
            appendUnique(nowPlayingSession.nowPlayingInfoCenter)
        }

        return centers
    }

    private func setNowPlayingInfoOnAllCenters(_ nowPlayingInfo: [String: Any]?) {
        for center in infoCenters {
            center.nowPlayingInfo = nowPlayingInfo
        }
    }

    private func withNowPlayingInfoOnAllCenters(_ update: (inout [String: Any]) -> Void) {
        for center in infoCenters {
            var nowPlayingInfo = center.nowPlayingInfo ?? [:]
            update(&nowPlayingInfo)
            center.nowPlayingInfo = nowPlayingInfo
        }
    }

    private func firstAvailableNowPlayingInfo() -> [String: Any]? {
        for center in infoCenters {
            if let info = center.nowPlayingInfo, !info.isEmpty {
                return info
            }
        }
        return nil
    }

    // MARK: - Audio Session Interruption Handling

    /// Set up observer for audio session interruptions (e.g., phone calls, other apps)
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
    }

    /// Handle audio session interruptions
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began - system is pausing our audio
            // Don't explicitly pause the player - let the system handle it
            // This prevents the "video pauses when opening Control Center" issue
            break

        case .ended:
            // Interruption ended - check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    viewModel?.resume()
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Public API

    /// Initialize the Now Playing service early at app launch.
    /// This ensures the singleton is created and audio session category is configured.
    func initialize() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // Audio session is configured when attach() is called
    }

    /// Attach to a player view model to sync Now Playing state
    func attach(to viewModel: UniversalPlayerViewModel, inputCoordinator: PlaybackInputCoordinator? = nil) {
        // Detach from previous if any
        detach()

        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator

        // CRITICAL: Ensure audio session is active BEFORE setting Now Playing info
        // This is required for tvOS to register us as the Now Playing app
        ensureAudioSessionActive()
        configureNowPlayingSession(for: viewModel.playerType)

        // CRITICAL: Set preliminary Now Playing info BEFORE playback starts
        // tvOS only registers apps as "Now Playing" if info is set before play() is called
        setPreliminaryNowPlayingInfo(
            metadata: viewModel.metadata,
            serverURL: viewModel.serverURL,
            authToken: viewModel.authToken
        )

        // Track whether we've updated with actual duration from player
        hasValidNowPlayingInfo = false

        // Subscribe to playback state changes
        viewModel.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] state in
                guard let self, let viewModel else { return }
                if self.lastHandledPlaybackState == state {
                    return
                }
                self.lastHandledPlaybackState = state

                switch state {
                case .playing:
                    // Reassert audio session/now-playing session when active playback starts.
                    // Custom playback pipelines can invalidate this state while initializing.
                    self.ensureAudioSessionActive()
                    self.configureNowPlayingSession(for: viewModel.playerType)

                    // ALWAYS update rate and state immediately when playing starts
                    // This is critical for Control Center to show the correct state
                    self.updatePlaybackRateAndState(isPlaying: true)

                    // If we have valid duration, update full info with actual duration
                    if viewModel.duration > 0 {
                        self.updateNowPlayingInfo(
                            metadata: viewModel.metadata,
                            currentTime: viewModel.currentTime,
                            duration: viewModel.duration,
                            isPlaying: true,
                            serverURL: viewModel.serverURL,
                            authToken: viewModel.authToken
                        )
                        self.hasValidNowPlayingInfo = true
                    }

                case .paused:
                    // Ensure audio session stays active during pause - required for Now Playing visibility
                    self.ensureAudioSessionActive()
                    // Update rate and state for paused (also re-asserts session)
                    self.updatePlaybackRateAndState(isPlaying: false)

                case .loading, .buffering:
                    // Don't update rate for loading/buffering - keep previous state
                    break

                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Subscribe to player type updates so fallback transitions (AVPlayer <-> MPV) keep
        // now-playing registration in sync with the active playback engine.
        viewModel.$playerType
            .receive(on: RunLoop.main)
            .sink { [weak self] playerType in
                self?.configureNowPlayingSession(for: playerType)
            }
            .store(in: &cancellables)

        // Subscribe to time updates
        viewModel.$currentTime
            .receive(on: RunLoop.main)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak viewModel] time in
                guard let self, let viewModel else { return }
                self.updateElapsedTime(time, duration: viewModel.duration)
            }
            .store(in: &cancellables)

        // Subscribe to duration updates
        viewModel.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] duration in
                guard let self, let viewModel else { return }

                // If we haven't set valid Now Playing info yet and now have valid duration while playing,
                // set the full Now Playing info now
                if !self.hasValidNowPlayingInfo && duration > 0 && viewModel.playbackState == .playing {
                    self.updateNowPlayingInfo(
                        metadata: viewModel.metadata,
                        currentTime: viewModel.currentTime,
                        duration: duration,
                        isPlaying: true,
                        serverURL: viewModel.serverURL,
                        authToken: viewModel.authToken
                    )
                    self.hasValidNowPlayingInfo = true
                } else {
                    self.updateDuration(duration, currentTime: viewModel.currentTime)
                }
            }
            .store(in: &cancellables)

    }

    /// Detach from the current view model and clear Now Playing
    /// Note: We intentionally do NOT deactivate the audio session here.
    /// Per WWDC17 guidance, the session should remain active while the app could receive remote commands.
    func detach() {
        cancellables.removeAll()
        viewModel = nil
        inputCoordinator = nil
        artworkTask?.cancel()
        artworkTask = nil
        hasValidNowPlayingInfo = false
        lastHandledPlaybackState = nil
        clearNowPlayingInfo()
        deactivateNowPlayingSession()
    }

    // MARK: - Remote Command Center Setup

    /// Configure remote commands on a given command center.
    /// Called for both the shared command center and the session's command center (tvOS 14+).
    private func configureRemoteCommands(on commandCenter: MPRemoteCommandCenter) {
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.play)
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.pause)
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.playPause)
            return .success
        }

        // Skip forward (10 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekSeconds)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekRelative(seconds: skipEvent.interval))
            return .success
        }

        // Skip backward (10 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekSeconds)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekRelative(seconds: -skipEvent.interval))
            return .success
        }

        // Change playback position (scrubbing/seeking)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekAbsolute(positionEvent.positionTime))
            return .success
        }

        // Seek forward (IR remote FF button)
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                self?.dispatchInputAction(.scrubNudge(forward: true))
            case .endSeeking:
                break
            @unknown default:
                break
            }
            return .success
        }

        // Seek backward (IR remote RW button)
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                self?.dispatchInputAction(.scrubNudge(forward: false))
            case .endSeeking:
                break
            @unknown default:
                break
            }
            return .success
        }

        // Disable commands we don't support
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
    }

    private func setupRemoteCommandCenter() {
        configureRemoteCommands(on: MPRemoteCommandCenter.shared())
    }

    private func dispatchInputAction(_ action: PlaybackInputAction) {
        switch action {
        case .seekAbsolute(let time):
            print("🎵 NowPlaying: remote seek absolute → \(String(format: "%.3f", time))s")
        case .seekRelative(let seconds):
            print("🎵 NowPlaying: remote seek relative → \(String(format: "%.3f", seconds))s")
        case .play, .pause, .playPause:
            break
        default:
            break
        }

        if let inputCoordinator {
            inputCoordinator.handle(action: action, source: .mpRemoteCommand)
            return
        }

        guard let viewModel else { return }

        switch action {
        case .play:
            viewModel.resume()
        case .pause:
            viewModel.pause()
        case .playPause:
            if viewModel.isScrubbing {
                Task { await viewModel.commitScrub() }
            } else {
                viewModel.togglePlayPause()
            }
        case .seekRelative(let seconds):
            Task { await viewModel.seekRelative(by: seconds) }
        case .seekAbsolute(let time):
            Task { await viewModel.seek(to: time) }
        case .scrubNudge(let forward):
            viewModel.scrubInDirection(forward: forward)
        case .scrubCommit:
            Task { await viewModel.commitScrub() }
        case .scrubCancel:
            viewModel.cancelScrub()
        default:
            break
        }
    }

    // MARK: - Now Playing Info Updates

    private func updateNowPlayingInfo(
        metadata: PlexMetadata,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        serverURL: String,
        authToken: String
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Duration and elapsed time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

        // Load artwork asynchronously
        loadArtwork(for: metadata, serverURL: serverURL, authToken: authToken)

    }

    /// Legacy method - prefer updatePlaybackRateAndState() for state changes
    private func updatePlaybackRate(isPlaying: Bool) {
        // Only update rate if we already have Now Playing info set
        guard var nowPlayingInfo = firstAvailableNowPlayingInfo(), !nowPlayingInfo.isEmpty else {
            return
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        setNowPlayingInfoOnAllCenters(nowPlayingInfo)
    }

    private func updateElapsedTime(_ time: TimeInterval, duration: TimeInterval) {
        withNowPlayingInfoOnAllCenters { nowPlayingInfo in
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
    }

    private func updateDuration(_ duration: TimeInterval, currentTime: TimeInterval) {
        withNowPlayingInfoOnAllCenters { nowPlayingInfo in
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
    }

    private func clearNowPlayingInfo() {
        setNowPlayingInfoOnAllCenters(nil)
    }

    /// Set Now Playing info BEFORE playback starts - critical for tvOS.
    /// This registers us as the "Now Playing app" before play() is called.
    /// Uses estimated duration from Plex metadata; will be updated when actual duration is available.
    private func setPreliminaryNowPlayingInfo(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Use Plex metadata duration (milliseconds -> seconds) as estimate
        // Will be updated with actual duration when player reports it
        let estimatedDuration = Double(metadata.duration ?? 0) / 1000.0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

        // Load artwork asynchronously
        loadArtwork(for: metadata, serverURL: serverURL, authToken: authToken)
    }

    /// Update playback rate in Now Playing info AND set explicit playback state.
    /// This should be called whenever play/pause state changes.
    /// Also updates elapsed time to "anchor" the position when rate changes.
    private func updatePlaybackRateAndState(isPlaying: Bool) {
        guard var nowPlayingInfo = firstAvailableNowPlayingInfo() else {
            print("🎵 NowPlaying: Cannot update rate/state - no info set")
            return
        }

        // Update rate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // CRITICAL: When rate changes, also update elapsed time to "anchor" the position.
        // This tells the system the exact position at the moment playback state changed.
        // Without this, the system may lose track of position or clear the Now Playing info.
        if let viewModel = viewModel {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = viewModel.currentTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = viewModel.duration
        }

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

        // Re-assert the session as active when changing playback state
        // This helps maintain visibility on other devices during pause/resume
        if #available(tvOS 14.0, iOS 16.0, *) {
            nowPlayingSession?.becomeActiveIfPossible { isActive in
                if !isActive {
                    print("🎵 NowPlaying: Warning - session could not become active")
                }
            }
        }

    }

    // MARK: - Artwork Loading

    private func loadArtwork(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        // Determine artwork URL based on content type
        // For episodes: prefer season poster (parentThumb), fall back to show poster (grandparentThumb)
        // For movies/other: use the item's own thumb or art
        let artworkPath: String?
        if metadata.type == "episode" {
            artworkPath = metadata.parentThumb ?? metadata.grandparentThumb ?? metadata.thumb
        } else {
            artworkPath = metadata.thumb ?? metadata.art
        }
        guard let artworkPath else { return }

        // Check if we already have this artwork cached
        let fullURL = "\(serverURL)\(artworkPath)?X-Plex-Token=\(authToken)"
        if fullURL == cachedArtworkURL, let cachedArtwork {
            withNowPlayingInfoOnAllCenters { nowPlayingInfo in
                nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
            }
            return
        }

        // Cancel any existing artwork load
        artworkTask?.cancel()

        artworkTask = Task {
            guard let url = URL(string: fullURL) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                guard !Task.isCancelled else { return }

                guard let image = UIImage(data: data) else { return }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                // Cache the artwork
                self.cachedArtwork = artwork
                self.cachedArtworkURL = fullURL

                // Update Now Playing info with artwork
                self.withNowPlayingInfoOnAllCenters { nowPlayingInfo in
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                }

            } catch {
                if !Task.isCancelled {
                    print("🎵 NowPlaying: Artwork load failed - \(error.localizedDescription)")
                }
            }
        }
    }
}
