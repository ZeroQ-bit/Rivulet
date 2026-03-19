//
//  NativePlayerViewController.swift
//  Rivulet
//
//  Barebones AVPlayerViewController wrapper.
//  Uses UniversalPlayerViewModel only for route/URL selection,
//  then hands the AVPlayer to the system player UI.
//
//  AVPlayerViewController handles everything natively:
//  - Transport controls (scrub bar, play/pause, skip)
//  - Now Playing / MPRemoteCommandCenter
//  - AirPlay A/V sync
//  - Audio session management
//

import AVKit
import Combine

class NativePlayerViewController: AVPlayerViewController {

    private let viewModel: UniversalPlayerViewModel
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?
    private var lastReportedTime: TimeInterval = -1
    var onDismiss: (() -> Void)?

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Observe when the VM creates its AVPlayer and hand it to the native UI
        viewModel.$player
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.player = avPlayer
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Pause hub polling while playing
        NotificationCenter.default.post(name: .plexPlaybackStarted, object: nil)

        // Do NOT attach NowPlayingService — AVPlayerViewController handles
        // Now Playing, remote commands, and audio session natively.

        Task { @MainActor in
            await viewModel.startPlayback()
        }

        // Report progress to Plex every 10 seconds
        startProgressReporting()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isBeingDismissed || isMovingFromParent {
            stopProgressReporting()
            reportFinalProgress()
            NotificationCenter.default.post(name: .plexPlaybackStopped, object: nil)
            viewModel.stopPlayback()
            onDismiss?()
        }
    }

    // MARK: - Plex Progress Reporting

    private func startProgressReporting() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reportCurrentProgress()
        }
    }

    private func stopProgressReporting() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func reportCurrentProgress() {
        let time = viewModel.currentTime
        guard abs(time - lastReportedTime) >= 5 else { return }
        lastReportedTime = time

        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let duration = viewModel.duration
        let state = viewModel.isPlaying ? "playing" : "paused"

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: state
            )
        }
    }

    private func reportFinalProgress() {
        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let time = viewModel.currentTime
        let duration = viewModel.duration

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: "stopped",
                forceReport: true
            )

            if duration > 0 && time / duration > 0.9 {
                await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey)
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            await MainActor.run {
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            }
        }
    }
}
