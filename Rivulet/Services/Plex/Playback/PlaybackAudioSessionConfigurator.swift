//
//  PlaybackAudioSessionConfigurator.swift
//  Rivulet
//
//  Shared audio-session setup for playback paths.
//

import Foundation
import AVFoundation

struct RouteAudioSnapshot: Sendable {
    let isAirPlay: Bool
    let maximumOutputChannels: Int
    let sampleRate: Double
    let supportsMultichannelContent: Bool
    let outputPortTypes: [String]
    let outputPortNames: [String]

    var isLikelyMultichannelAirPlay: Bool {
        isAirPlay && maximumOutputChannels > 2
    }
}

enum RouteAudioPolicyProfile: String, Sendable {
    case local
    case airPlayStereo
    case airPlayMultichannel
}

struct RouteAudioPolicy: Sendable, Equatable {
    let profile: RouteAudioPolicyProfile
    let useAudioPullMode: Bool
    let audioPullStartBufferDuration: TimeInterval
    let audioPullResumeBufferDuration: TimeInterval
    let targetOutputSampleRate: Int
    let preferAudioEngineForPCM: Bool
    let forceClientDecodeAllAudio: Bool
    let forceClientDecodeCodecs: Set<String>
    let enableSurroundReEncoding: Bool
    let useSignedInt16Audio: Bool
    let forceDownmixToStereo: Bool
    let audioBackpressureMaxWait: TimeInterval
}

enum PlaybackAudioSessionConfigurator {
    private static var lastActivationTimestamp: CFAbsoluteTime = 0
    private static var lastActivationModeRawValue: String = ""
    private static let minimumReactivationInterval: CFAbsoluteTime = 0.75

    /// Configure and activate a playback session optimized for long-form media.
    /// Uses long-form video routing on iOS and long-form audio on tvOS (video policy
    /// is unavailable on tvOS). Falls back to allowAirPlay when policy-based routing
    /// cannot be applied.
    static func activatePlaybackSession(mode: AVAudioSession.Mode, owner: String) {
        let session = AVAudioSession.sharedInstance()
        let now = CFAbsoluteTimeGetCurrent()

        // Multiple playback components may request activation back-to-back (NowPlaying + player).
        // Skip duplicate re-activation bursts to reduce route churn and log noise.
        if now - lastActivationTimestamp < minimumReactivationInterval &&
            lastActivationModeRawValue == mode.rawValue {
            Task { @MainActor in
                AudioRouteDiagnostics.shared.start(owner: owner)
                AudioRouteDiagnostics.shared.logCurrentRoute(owner: owner, reason: "activate_playback_session_reused")
            }
            return
        }

        var usingLongFormPolicy = false
        let preferredPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio
        let preferredPolicyName = "longFormAudio"

        do {
            try session.setCategory(.playback, mode: mode, policy: preferredPolicy, options: [])
            usingLongFormPolicy = true
        } catch {
            do {
                try session.setCategory(.playback, mode: mode, options: [.allowAirPlay])
                print("🎵 \(owner): Audio category fallback set (.playback, mode: \(mode.rawValue), allowAirPlay)")
            } catch {
                print("🎵 \(owner): Could not set audio category: \(error.localizedDescription)")
            }
        }

        do {
            try session.setActive(true)
            lastActivationTimestamp = now
            lastActivationModeRawValue = mode.rawValue
            do {
                try session.setPreferredSampleRate(48_000)
            } catch {
                print("🎵 \(owner): Could not set preferred sample rate: \(error.localizedDescription)")
            }
            if #available(tvOS 15.0, iOS 15.0, *) {
                do {
                    try session.setSupportsMultichannelContent(true)
                } catch {
                    print("🎵 \(owner): Could not enable multichannel content support: \(error.localizedDescription)")
                }
            }
            let routeType = session.currentRoute.outputs.first?.portType.rawValue ?? "unknown"
            print("🎵 \(owner): Audio session active (route: \(routeType), policy: \(usingLongFormPolicy ? preferredPolicyName : "default"))")
            Task { @MainActor in
                AudioRouteDiagnostics.shared.start(owner: owner)
                AudioRouteDiagnostics.shared.logCurrentRoute(owner: owner, reason: "activate_playback_session")
            }
        } catch {
            print("🎵 \(owner): Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    static func isAirPlayRouteActive() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.contains(where: { $0.portType == .airPlay })
    }

    static func recommendedAudioPolicy(for snapshot: RouteAudioSnapshot) -> RouteAudioPolicy {
        guard snapshot.isAirPlay else {
            return RouteAudioPolicy(
                profile: .local,
                useAudioPullMode: true,
                audioPullStartBufferDuration: 0,
                audioPullResumeBufferDuration: 0,
                targetOutputSampleRate: 0,
                preferAudioEngineForPCM: false,
                forceClientDecodeAllAudio: false,
                forceClientDecodeCodecs: [],
                enableSurroundReEncoding: false,
                useSignedInt16Audio: false,
                forceDownmixToStereo: false,
                audioBackpressureMaxWait: 0.75
            )
        }

        if snapshot.isLikelyMultichannelAirPlay {
            return RouteAudioPolicy(
                profile: .airPlayMultichannel,
                useAudioPullMode: true,
                audioPullStartBufferDuration: 1.0,
                audioPullResumeBufferDuration: 0.3,
                targetOutputSampleRate: 0,
                preferAudioEngineForPCM: false,
                forceClientDecodeAllAudio: true,
                forceClientDecodeCodecs: [],
                enableSurroundReEncoding: true,
                useSignedInt16Audio: true,
                forceDownmixToStereo: false,
                audioBackpressureMaxWait: 1.0
            )
        }

        return RouteAudioPolicy(
            profile: .airPlayStereo,
            useAudioPullMode: true,
            audioPullStartBufferDuration: 1.0,
            audioPullResumeBufferDuration: 0.3,
            targetOutputSampleRate: 0,
            preferAudioEngineForPCM: false,
            forceClientDecodeAllAudio: true,
            forceClientDecodeCodecs: [],
            enableSurroundReEncoding: false,
            useSignedInt16Audio: true,
            forceDownmixToStereo: true,
            audioBackpressureMaxWait: 2.0
        )
    }

    /// Conservative stereo PCM fallback used after repeated AirPlay instability events.
    /// This intentionally trades surround preservation for the same decode/buffer shape
    /// that is already used on stereo AirPlay/HomePod routes.
    static func stabilityFallbackAudioPolicy(for snapshot: RouteAudioSnapshot) -> RouteAudioPolicy {
        guard snapshot.isAirPlay else {
            return recommendedAudioPolicy(for: snapshot)
        }

        return RouteAudioPolicy(
            profile: .airPlayStereo,
            useAudioPullMode: true,
            audioPullStartBufferDuration: 1.0,
            audioPullResumeBufferDuration: 0.3,
            targetOutputSampleRate: 0,
            preferAudioEngineForPCM: false,
            forceClientDecodeAllAudio: true,
            forceClientDecodeCodecs: [],
            enableSurroundReEncoding: false,
            useSignedInt16Audio: true,
            forceDownmixToStereo: true,
            audioBackpressureMaxWait: 2.0
        )
    }

    static func policyDecisionReason(for snapshot: RouteAudioSnapshot) -> String {
        if !snapshot.isAirPlay { return "local_output" }

        if snapshot.supportsMultichannelContent && snapshot.maximumOutputChannels <= 2 {
            return "airplay_stereo_forced_by_max_output_channels"
        }
        if snapshot.supportsMultichannelContent {
            return "airplay_supports_multichannel_content"
        }
        if snapshot.maximumOutputChannels > 2 {
            return "airplay_max_output_channels_\(snapshot.maximumOutputChannels)"
        }
        return "airplay_stereo_only"
    }

    static func currentRouteAudioSnapshot(owner: String, reason: String) -> RouteAudioSnapshot {
        let session = AVAudioSession.sharedInstance()
        let outputTypes = session.currentRoute.outputs.map(\.portType.rawValue)
        let outputNames = session.currentRoute.outputs.map(\.portName)
        let supportsMultichannel: Bool
        if #available(tvOS 15.0, iOS 15.0, *) {
            supportsMultichannel = session.supportsMultichannelContent
        } else {
            supportsMultichannel = false
        }

        let snapshot = RouteAudioSnapshot(
            isAirPlay: session.currentRoute.outputs.contains(where: { $0.portType == .airPlay }),
            maximumOutputChannels: session.maximumOutputNumberOfChannels,
            sampleRate: session.sampleRate,
            supportsMultichannelContent: supportsMultichannel,
            outputPortTypes: outputTypes,
            outputPortNames: outputNames
        )

        print(
            "🎵 [RouteSnapshot] owner=\(owner) reason=\(reason) " +
            "airPlay=\(snapshot.isAirPlay) maxOutCh=\(snapshot.maximumOutputChannels) " +
            "sampleRate=\(String(format: "%.0f", snapshot.sampleRate)) " +
            "supportsMultichannel=\(snapshot.supportsMultichannelContent) " +
            "policyReason=\(policyDecisionReason(for: snapshot)) " +
            "outputs=\(snapshot.outputPortTypes.joined(separator: ",")) " +
            "names=\(snapshot.outputPortNames.joined(separator: ","))"
        )
        return snapshot
    }
}
