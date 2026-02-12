//
//  MPVPlayerView.swift
//  Rivulet
//
//  SwiftUI wrapper for MPVMetalViewController
//

import Foundation
import SwiftUI

struct MPVPlayerView: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]?
    let startTime: Double?
    let delegate: MPVPlayerDelegate?
    var isLiveStream: Bool = false
    var containerSize: CGSize = .zero  // Explicit size from parent (for multi-stream)

    @Binding var playerController: MPVMetalViewController?

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        // Try to claim a pre-warmed controller for faster startup
        if let prewarmed = MPVPrewarmService.shared.claimPrewarmedController(isLiveStream: isLiveStream) {
            print("🔥 [MPVPlayerView] Using pre-warmed controller")
            prewarmed.delegate = delegate
            prewarmed.prepareForPresentation()

            // Set explicit size if provided (for multi-stream layout)
            if containerSize != .zero {
                prewarmed.setExplicitSize(containerSize)
            }

            DispatchQueue.main.async {
                self.playerController = prewarmed
            }

            return prewarmed
        }

        // Fallback: create new controller (cold start path)
        print("🔥 [MPVPlayerView] Cold start - creating new controller")
        let controller = MPVMetalViewController()
        // Playback load is owned by MPVPlayerWrapper to avoid duplicate loadfile commands.
        controller.delegate = delegate
        controller.isLiveStreamMode = isLiveStream

        // Set explicit size if provided (for multi-stream layout)
        if containerSize != .zero {
            controller.setExplicitSize(containerSize)
        }

        DispatchQueue.main.async {
            self.playerController = controller
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: MPVMetalViewController, context: Context) {
        // Update explicit size when container size changes
        // Pass .zero to disable transform scaling (reverts to normal frame-based sizing)
        uiViewController.setExplicitSize(containerSize)
    }
}
