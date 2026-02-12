//
//  MPVPrewarmService.swift
//  Rivulet
//
//  Pre-warms MPV context to reduce player startup latency.
//  Mirrors the StreamURLCache pattern - pre-initialize while user views PlexDetailView.
//

import Foundation
import UIKit

/// Singleton service that pre-warms an MPV context for faster player startup.
/// Pre-warming MPV (mpv_create + mpv_initialize + Vulkan/MoltenVK init) takes ~300-500ms.
/// By doing this while the user views PlexDetailView, we can reduce perceived startup time.
@MainActor
final class MPVPrewarmService {
    static let shared = MPVPrewarmService()

    /// Current state of the pre-warm service
    enum State: Equatable, CustomStringConvertible {
        case cold           // No pre-warmed controller
        case warming        // Currently initializing controller
        case ready          // Controller is ready to be claimed
        case inUse          // Controller has been claimed by a player

        var description: String {
            switch self {
            case .cold: return "cold"
            case .warming: return "warming"
            case .ready: return "ready"
            case .inUse: return "inUse"
            }
        }
    }

    /// Current state of the service
    private(set) var state: State = .cold

    /// The pre-warmed controller (if any)
    private var prewarmedController: MPVMetalViewController?

    /// Whether the pre-warmed controller was configured for live stream mode
    private var prewarmedForLiveStream: Bool = false

    /// Timer for auto-releasing unused pre-warmed controller
    private var releaseTimer: Timer?

    /// Time after which an unused pre-warmed controller is released (5 minutes)
    private let releaseTimeout: TimeInterval = 300

    /// Memory warning observer
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        setupMemoryWarningObserver()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseTimer?.invalidate()
    }

    // MARK: - Public API

    /// Pre-warm an MPV controller if we don't already have one ready.
    /// Call this from PlexDetailView when loading full metadata for movies/episodes.
    ///
    /// - Parameter forLiveStream: Whether to configure for live stream mode (different GPU settings)
    func prewarmIfNeeded(forLiveStream: Bool = false) {
        // Don't pre-warm if already ready or in use
        guard state == .cold else {
            print("🔥 [MPVPrewarm] Skipping pre-warm, state=\(state)")
            return
        }

        state = .warming
        prewarmedForLiveStream = forLiveStream
        print("🔥 [MPVPrewarm] Starting pre-warm for \(forLiveStream ? "live" : "VOD") mode")

        // Create controller on main thread (UIKit requirement)
        let controller = MPVMetalViewController()
        controller.isLiveStreamMode = forLiveStream

        // The controller will initialize MPV in viewDidLoad when added to view hierarchy.
        // We need to briefly add it to trigger initialization, then remove it.
        // Use a hidden window to avoid any visual artifacts.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        window.isHidden = true
        window.rootViewController = controller
        window.makeKeyAndVisible()

        // After a brief moment for initialization, store the controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.state == .warming else { return }

            // Remove from temporary window but keep controller alive
            window.rootViewController = nil
            window.isHidden = true

            self.prewarmedController = controller
            self.state = .ready
            self.startReleaseTimer()
            print("🔥 [MPVPrewarm] Pre-warm complete, controller ready")
        }
    }

    /// Attempt to claim the pre-warmed controller for use in a player.
    /// Returns nil if no suitable controller is available (falls back to cold start).
    ///
    /// - Parameter isLiveStream: Whether the player needs live stream configuration
    /// - Returns: The pre-warmed controller if available and compatible, nil otherwise
    func claimPrewarmedController(isLiveStream: Bool) -> MPVMetalViewController? {
        guard state == .ready, let controller = prewarmedController else {
            print("🔥 [MPVPrewarm] No controller available to claim, state=\(state)")
            return nil
        }

        // Check if the pre-warmed configuration matches what's needed
        if prewarmedForLiveStream != isLiveStream {
            print("🔥 [MPVPrewarm] Config mismatch: prewarmed=\(prewarmedForLiveStream ? "live" : "VOD"), needed=\(isLiveStream ? "live" : "VOD")")
            // Release the mismatched controller and fall back to cold start
            releasePrewarmedController()
            return nil
        }

        // Claim the controller
        releaseTimer?.invalidate()
        releaseTimer = nil
        prewarmedController = nil
        state = .inUse
        print("🔥 [MPVPrewarm] Controller claimed for \(isLiveStream ? "live" : "VOD") playback")

        return controller
    }

    /// Called when the player is dismissed to indicate the service can prepare for next use.
    /// This doesn't immediately pre-warm; it just transitions state back to cold.
    func releaseController() {
        guard state == .inUse else { return }
        state = .cold
        print("🔥 [MPVPrewarm] Controller released, state=cold")
    }

    /// Force release any pre-warmed controller (e.g., on memory warning)
    func releasePrewarmedController() {
        releaseTimer?.invalidate()
        releaseTimer = nil

        if let controller = prewarmedController {
            // The controller will clean up MPV resources in its deinit
            prewarmedController = nil
            print("🔥 [MPVPrewarm] Force-released pre-warmed controller")

            // Ensure controller is fully released by removing any strong references
            _ = controller
        }

        state = .cold
    }

    // MARK: - Private

    private func setupMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("🔥 [MPVPrewarm] Memory warning received, releasing pre-warmed controller")
            self?.releasePrewarmedController()
        }
    }

    private func startReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: releaseTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                print("🔥 [MPVPrewarm] Release timeout reached, releasing unused controller")
                self?.releasePrewarmedController()
            }
        }
    }
}
