//
//  MusicPlayer.swift
//  Rivulet
//
//  Audio-only player using AVQueuePlayer for music playback.
//  Handles gapless transitions, sweet fades, and audio session.
//

import Foundation
import AVFoundation
import Combine

/// Internal state for the music player
enum MusicPlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case ended
}

/// Audio-only player backed by AVQueuePlayer.
/// Handles gapless playback, volume fading, and audio session management.
@MainActor
final class MusicPlayer: ObservableObject {

    // MARK: - Published State

    @Published var state: MusicPlayerState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    // MARK: - Private State

    private var player: AVQueuePlayer?
    private var currentItem: AVPlayerItem?
    private var nextItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var fadeTimer: Timer?

    /// Sweet fade duration for pause/resume
    private let sweetFadeDuration: TimeInterval = 0.3

    // MARK: - Initialization

    init() {}

    deinit {
        // Clean up on dealloc
        Task { @MainActor [weak self] in
            self?.cleanUp()
        }
    }

    // MARK: - Playback Controls

    /// Load and play an audio URL
    func load(url: URL, headers: [String: String]) {
        cleanUp()

        // Configure audio session
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .default,
            owner: "MusicPlayer"
        )

        // Create asset with headers
        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        currentItem = item

        let queuePlayer = AVQueuePlayer(items: [item])
        queuePlayer.actionAtItemEnd = .advance
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        self.player = queuePlayer

        state = .loading

        // Observe item status
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isNaN ? 0 : item.duration.seconds
                    self.state = .playing
                    self.player?.play()
                case .failed:
                    print("🎵 MusicPlayer: Item failed: \(item.error?.localizedDescription ?? "unknown")")
                    self.state = .idle
                default:
                    break
                }
            }
        }

        // Observe playback end
        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndOfTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only handle if it's our current item (not the queued next item becoming current)
                if item == self.currentItem {
                    self.state = .ended
                }
            }
        }

        // Time observer for progress tracking
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = queuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                }
            }
        }
    }

    /// Prepare the next track for gapless playback
    func prepareNext(url: URL, headers: [String: String]) {
        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        nextItem = item

        // Insert into queue for gapless transition
        if let player, player.canInsert(item, after: nil) {
            player.insert(item, after: nil)
        }
    }

    func play() {
        guard let player else { return }
        // Sweet fade in
        player.volume = 0
        player.play()
        state = .playing
        fadeVolume(to: 1.0)
    }

    func pause() {
        guard let player else { return }
        // Sweet fade out then pause
        fadeVolume(to: 0) { [weak self] in
            player.pause()
            Task { @MainActor [weak self] in
                self?.state = .paused
            }
        }
    }

    func stop() {
        player?.pause()
        cleanUp()
        state = .idle
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Volume Fading

    private func fadeVolume(to target: Float, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()

        guard let player else {
            completion?()
            return
        }

        let startVolume = player.volume
        let steps = 15
        let stepDuration = sweetFadeDuration / Double(steps)
        let volumeStep = (target - startVolume) / Float(steps)
        var currentStep = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak player] timer in
            currentStep += 1
            if currentStep >= steps {
                player?.volume = target
                timer.invalidate()
                completion?()
            } else {
                player?.volume = startVolume + volumeStep * Float(currentStep)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        fadeTimer?.invalidate()
        fadeTimer = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        statusObserver?.invalidate()
        statusObserver = nil

        if let observer = didPlayToEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        didPlayToEndObserver = nil

        player?.removeAllItems()
        player = nil
        currentItem = nil
        nextItem = nil
        currentTime = 0
        duration = 0
    }
}
