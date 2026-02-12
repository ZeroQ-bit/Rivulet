//
//  AVPlayerView.swift
//  Rivulet
//
//  SwiftUI wrapper for AVPlayer-based video playback
//  Used for Live TV streams for better resource efficiency
//

import SwiftUI
import AVFoundation
import AVKit
import Combine

/// A SwiftUI view that displays video content using AVPlayer
struct AVPlayerView: UIViewRepresentable {
    @ObservedObject var playerWrapper: AVPlayerWrapper

    func makeUIView(context: Context) -> AVPlayerUIView {
        let view = AVPlayerUIView()

        // Wire up rendering status callback
        view.onRenderingStatusChanged = { [weak playerWrapper] isReady, videoRect in
            playerWrapper?.handleRenderingStatusChanged(isReady: isReady, videoRect: videoRect)
        }

        // Attach player immediately if available
        if let player = playerWrapper.player {
            view.player = player
        }
        return view
    }

    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {
        // Ensure callback is always set to current wrapper
        uiView.onRenderingStatusChanged = { [weak playerWrapper] isReady, videoRect in
            playerWrapper?.handleRenderingStatusChanged(isReady: isReady, videoRect: videoRect)
        }

        // Attach the player when it becomes available
        if let player = playerWrapper.player, uiView.player !== player {
            uiView.player = player
        }
    }
}

/// UIView subclass that hosts an AVPlayerLayer for video rendering
final class AVPlayerUIView: UIView {

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    /// Callback when video rendering status changes
    var onRenderingStatusChanged: ((Bool, CGRect) -> Void)?

    private var readyForDisplayObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?

    /// Track last reported videoRect to avoid duplicate callbacks
    private var lastReportedVideoRect: CGRect = .zero

    /// Note: Display criteria is managed by DisplayCriteriaManager, not this view

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard playerLayer.player !== newValue else { return }
            playerLayer.player = newValue

            // Stop observing old player
            readyForDisplayObservation?.invalidate()
            playerItemStatusObservation?.invalidate()

            // Reset tracking for new player
            lastReportedVideoRect = .zero

            // Debug: Log video track info (async to avoid blocking main thread on XPC)
            if let currentItem = newValue?.currentItem {
                let asset = currentItem.asset
                Task {
                    do {
                        let videoTracks = try await asset.loadTracks(withMediaType: .video)
                        for (i, track) in videoTracks.enumerated() {
                            let naturalSize = try await track.load(.naturalSize)
                            let isEnabled = try await track.load(.isEnabled)
                        }
                    } catch {
                        print("🎬 AVPlayerUIView: Failed to load track info: \(error)")
                    }
                }

                // Note: Display criteria (HDR/DV mode switching) is handled by
                // DisplayCriteriaManager in UniversalPlayerViewModel before loading.
                // We intentionally do NOT derive criteria from the asset here because
                // for DV content the proxy patches dvh1→hvc1 in the HLS manifest,
                // which would cause asset-derived criteria to report HDR10 instead of DV.
            }

            // Start observing isReadyForDisplay to detect when video actually renders
            if newValue != nil {
                readyForDisplayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new, .old]) { [weak self] layer, change in
                    guard let self else { return }
                    let isReady = layer.isReadyForDisplay
                    let videoRect = layer.videoRect
                    // Track reported rect to avoid duplicates from layoutSubviews
                    if videoRect.width > 10 && videoRect.height > 10 {
                        self.lastReportedVideoRect = videoRect
                    }
                    self.onRenderingStatusChanged?(isReady, videoRect)
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // AVPlayerLayer automatically resizes with the view
        let videoRect = playerLayer.videoRect
        let isReady = playerLayer.isReadyForDisplay

        // If we have a valid videoRect that differs from last reported, call the callback
        // This catches the case where videoRect becomes valid AFTER isReadyForDisplay fires
        if isReady && videoRect.width > 10 && videoRect.height > 10 {
            // Only report if rect changed significantly (avoid duplicate callbacks)
            let rectChanged = abs(videoRect.width - lastReportedVideoRect.width) > 1 ||
                              abs(videoRect.height - lastReportedVideoRect.height) > 1
            if rectChanged {
                lastReportedVideoRect = videoRect
                onRenderingStatusChanged?(isReady, videoRect)
            }
        }
    }

    deinit {
        readyForDisplayObservation?.invalidate()
        playerItemStatusObservation?.invalidate()
    }
}

#Preview {
    AVPlayerView(playerWrapper: AVPlayerWrapper())
        .frame(width: 400, height: 300)
        .background(Color.black)
}
