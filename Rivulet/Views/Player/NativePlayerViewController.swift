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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isBeingDismissed || isMovingFromParent {
            NotificationCenter.default.post(name: .plexPlaybackStopped, object: nil)
            viewModel.stopPlayback()
            onDismiss?()
        }
    }
}
