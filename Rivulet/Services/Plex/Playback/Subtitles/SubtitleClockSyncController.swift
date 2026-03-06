//
//  SubtitleClockSyncController.swift
//  Rivulet
//
//  Drives subtitle updates from the active playback clock (render synchronizer time)
//  instead of low-frequency UI time updates.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SubtitleClockSyncController: NSObject {

    typealias TimeProvider = @MainActor () -> TimeInterval
    typealias PlaybackStateProvider = @MainActor () -> Bool

    private weak var subtitleManager: SubtitleManager?
    private var timeProvider: TimeProvider?
    private var isPlayingProvider: PlaybackStateProvider?
    private var owner = "unknown"
    private var lastPlaybackTime: TimeInterval = -1
    private var tickCount = 0

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #endif

    func start(
        owner: String,
        subtitleManager: SubtitleManager,
        timeProvider: @escaping TimeProvider,
        isPlayingProvider: @escaping PlaybackStateProvider
    ) {
        stop()

        self.owner = owner
        self.subtitleManager = subtitleManager
        self.timeProvider = timeProvider
        self.isPlayingProvider = isPlayingProvider
        self.lastPlaybackTime = -1
        self.tickCount = 0

        #if canImport(UIKit)
        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayTick))
        displayLink.preferredFramesPerSecond = 30
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        #endif

        // print("🎬 [Subtitles] Clock sync started (\(owner))")
    }

    func stop() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif

        timeProvider = nil
        isPlayingProvider = nil
        subtitleManager = nil
        lastPlaybackTime = -1
        tickCount = 0
    }

    func didSeek() {
        subtitleManager?.didSeek()
        lastPlaybackTime = -1
    }

    #if canImport(UIKit)
    @objc
    private func handleDisplayTick() {
        guard let subtitleManager, let timeProvider, let isPlayingProvider else { return }

        let playbackTime = timeProvider()
        guard playbackTime.isFinite, playbackTime >= 0 else { return }

        subtitleManager.update(time: playbackTime)
        tickCount += 1

        // Lightweight diagnostics: detect jumps or regressions in playback clock updates.
        if subtitleManager.diagnosticsEnabled, isPlayingProvider(), lastPlaybackTime >= 0 {
            let delta = playbackTime - lastPlaybackTime
            // if delta < -0.35 || delta > 0.8 {
            //     print(
            //         "🎬 [Subtitles] Clock jump (\(owner)) prev=\(String(format: "%.3f", lastPlaybackTime)) " +
            //         "now=\(String(format: "%.3f", playbackTime)) Δ=\(String(format: "%.3f", delta))"
            //     )
            // } else if tickCount % 300 == 0 {
            //     print(
            //         "🎬 [Subtitles] Clock heartbeat (\(owner)) t=\(String(format: "%.3f", playbackTime)) " +
            //         "activeCues=\(subtitleManager.currentCues.count)"
            //     )
            // }
        }

        lastPlaybackTime = playbackTime
    }
    #endif
}
