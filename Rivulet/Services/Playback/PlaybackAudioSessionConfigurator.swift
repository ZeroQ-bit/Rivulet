//
//  PlaybackAudioSessionConfigurator.swift
//  Rivulet
//
//  Shared audio-session setup for playback paths.
//

import AVFoundation

enum PlaybackAudioSessionConfigurator {
    /// Configure and activate a playback session optimized for long-form media.
    /// Uses long-form video routing on iOS and long-form audio on tvOS (video policy
    /// is unavailable on tvOS). Falls back to allowAirPlay when policy-based routing
    /// cannot be applied.
    static func activatePlaybackSession(mode: AVAudioSession.Mode, owner: String) {
        let session = AVAudioSession.sharedInstance()
        var usingLongFormPolicy = false
        #if os(tvOS)
        let preferredPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio
        let preferredPolicyName = "longFormAudio"
        #else
        let preferredPolicy: AVAudioSession.RouteSharingPolicy = .longFormVideo
        let preferredPolicyName = "longFormVideo"
        #endif

        do {
            try session.setCategory(.playback, mode: mode, policy: preferredPolicy, options: [])
            usingLongFormPolicy = true
            print("🎵 \(owner): Audio category set (.playback, mode: \(mode.rawValue), policy: \(preferredPolicyName))")
        } catch {
            print("🎵 \(owner): Long-form policy unavailable, falling back (\(error.localizedDescription))")
            do {
                try session.setCategory(.playback, mode: mode, options: [.allowAirPlay])
                print("🎵 \(owner): Audio category fallback set (.playback, mode: \(mode.rawValue), allowAirPlay)")
            } catch {
                print("🎵 \(owner): Could not set audio category: \(error.localizedDescription)")
            }
        }

        do {
            try session.setActive(true)
            if #available(tvOS 15.0, iOS 15.0, *) {
                do {
                    try session.setSupportsMultichannelContent(true)
                } catch {
                    print("🎵 \(owner): Could not enable multichannel content support: \(error.localizedDescription)")
                }
            }
            let routeType = session.currentRoute.outputs.first?.portType.rawValue ?? "unknown"
            print("🎵 \(owner): Audio session active (route: \(routeType), policy: \(usingLongFormPolicy ? preferredPolicyName : "default"))")
        } catch {
            print("🎵 \(owner): Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    static func isAirPlayRouteActive() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.contains(where: { $0.portType == .airPlay })
    }
}
