//
//  MusicNowPlayingBridge.swift
//  Rivulet
//
//  Bridges MusicQueue state to MPNowPlayingInfoCenter and MPRemoteCommandCenter.
//  Configures system Now Playing with music-specific fields and remote commands.
//

import Foundation
import MediaPlayer
import UIKit

/// Bridges music playback state to the system Now Playing integration.
/// Handles artwork loading, remote commands (next/prev/shuffle/repeat), and metadata display.
@MainActor
final class MusicNowPlayingBridge {

    // MARK: - Private State

    private var artworkTask: Task<Void, Never>?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkThumb: String?
    private var commandTargets: [Any] = []

    // MARK: - Initialization

    init() {
        setupRemoteCommands()
    }

    // MARK: - Update Now Playing

    /// Full update when track changes
    func update(
        track: PlexMetadata,
        queue: [PlexMetadata],
        history: [PlexMetadata],
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        // Ensure audio session is active for Now Playing registration
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .default,
            owner: "MusicNowPlaying"
        )

        var info = [String: Any]()

        // Track metadata
        info[MPMediaItemPropertyTitle] = track.title ?? "Unknown Track"
        info[MPMediaItemPropertyArtist] = track.grandparentTitle ?? track.parentTitle ?? "Unknown Artist"
        info[MPMediaItemPropertyAlbumTitle] = track.parentTitle ?? ""
        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        // Timing
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Queue position
        let totalCount = history.count + 1 + queue.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = history.count
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = totalCount

        // Track number
        if let index = track.index {
            info[MPMediaItemPropertyAlbumTrackNumber] = index
        }

        // Reuse cached artwork if same thumb URL
        if let artwork = cachedArtwork, cachedArtworkThumb == track.thumb {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Load artwork async
        loadArtwork(for: track)
    }

    /// Lightweight time update (called every few seconds)
    func updateTime(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Update shuffle/repeat state display
    func updateShuffleRepeat(shuffle: Bool, repeat repeatMode: MusicRepeatMode) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clear all Now Playing info
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        artworkTask?.cancel()
        artworkTask = nil
        cachedArtwork = nil
        cachedArtworkThumb = nil
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Play/Pause
        let playTarget = center.playCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.play() }
            return .success
        }
        commandTargets.append(playTarget)

        let pauseTarget = center.pauseCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.pause() }
            return .success
        }
        commandTargets.append(pauseTarget)

        let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.togglePlayPause() }
            return .success
        }
        commandTargets.append(toggleTarget)

        // Next/Previous track
        center.nextTrackCommand.isEnabled = true
        let nextTarget = center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.skipToNext() }
            return .success
        }
        commandTargets.append(nextTarget)

        center.previousTrackCommand.isEnabled = true
        let prevTarget = center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.skipToPrevious() }
            return .success
        }
        commandTargets.append(prevTarget)

        // Seek
        center.changePlaybackPositionCommand.isEnabled = true
        let seekTarget = center.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in MusicQueue.shared.seek(to: positionEvent.positionTime) }
            return .success
        }
        commandTargets.append(seekTarget)

        // Shuffle
        center.changeShuffleModeCommand.isEnabled = true
        let shuffleTarget = center.changeShuffleModeCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.toggleShuffle() }
            return .success
        }
        commandTargets.append(shuffleTarget)

        // Repeat
        center.changeRepeatModeCommand.isEnabled = true
        let repeatTarget = center.changeRepeatModeCommand.addTarget { _ in
            Task { @MainActor in MusicQueue.shared.cycleRepeatMode() }
            return .success
        }
        commandTargets.append(repeatTarget)
    }

    // MARK: - Artwork Loading

    private func loadArtwork(for track: PlexMetadata) {
        let thumbPath = track.thumb ?? track.parentThumb
        guard let thumbPath, thumbPath != cachedArtworkThumb else { return }

        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let serverURL = PlexAuthManager.shared.selectedServerURL,
                  let token = PlexAuthManager.shared.selectedServerToken else { return }

            let urlString = "\(serverURL)\(thumbPath)?X-Plex-Token=\(token)"
            guard let url = URL(string: urlString) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                if let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                    guard !Task.isCancelled else { return }
                    self?.cachedArtwork = artwork
                    self?.cachedArtworkThumb = thumbPath

                    // Update Now Playing with artwork
                    if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                        info[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("🎵 MusicNowPlaying: Failed to load artwork: \(error)")
                }
            }
        }
    }
}
