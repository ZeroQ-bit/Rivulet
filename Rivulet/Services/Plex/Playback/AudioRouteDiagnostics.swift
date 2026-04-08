//
//  AudioRouteDiagnostics.swift
//  Rivulet
//
//  Shared AVAudioSession route diagnostics for HomePod/AirPlay troubleshooting.
//

import Foundation
import AVFoundation

final class AudioRouteDiagnostics {
    static let shared = AudioRouteDiagnostics()

    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var recentLogByKey: [String: CFAbsoluteTime] = [:]
    private let duplicateLogSuppressionWindow: CFAbsoluteTime = 1.0

    private init() {}

    func start(owner: String) {
        if routeObserver == nil {
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        }

        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        }

        if mediaServicesResetObserver == nil {
            mediaServicesResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                self?.logCurrentRoute(owner: "AudioRouteDiagnostics", reason: "media_services_reset")
            }
        }

        logCurrentRoute(owner: owner, reason: "diagnostics_started")
    }

    func logCurrentRoute(owner: String, reason: String) {
        let key = "\(owner)|\(reason)"
        let now = CFAbsoluteTimeGetCurrent()
        if let lastLogTime = recentLogByKey[key], now - lastLogTime < duplicateLogSuppressionWindow {
            return
        }
        recentLogByKey[key] = now

        let session = AVAudioSession.sharedInstance()
        let outputs = routeSummary(for: session.currentRoute.outputs)
        let inputs = routeSummary(for: session.currentRoute.inputs)
        let isAirPlay = session.currentRoute.outputs.contains(where: { $0.portType == .airPlay })

        playerDebugLog(
            "🎵 [AudioRoute] owner=\(owner) reason=\(reason) " +
            "outputs=[\(outputs)] inputs=[\(inputs)] " +
            "sampleRate=\(String(format: "%.0f", session.sampleRate))Hz " +
            "preferredSampleRate=\(String(format: "%.0f", session.preferredSampleRate))Hz " +
            "ioBuffer=\(String(format: "%.4f", session.ioBufferDuration))s " +
            "category=\(session.category.rawValue) mode=\(session.mode.rawValue) " +
            "airPlay=\(isAirPlay)"
        )
    }

    private func handleRouteChange(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            .map(routeReasonDescription)
            ?? "unknown"

        if let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            playerDebugLog("🎵 [AudioRoute] previousOutputs=[\(routeSummary(for: previousRoute.outputs))]")
        }

        logCurrentRoute(owner: "AudioRouteDiagnostics", reason: "route_change:\(reason)")
    }

    private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            logCurrentRoute(owner: "AudioRouteDiagnostics", reason: "interruption_began")
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            logCurrentRoute(
                owner: "AudioRouteDiagnostics",
                reason: "interruption_ended:shouldResume=\(shouldResume)"
            )
        @unknown default:
            logCurrentRoute(owner: "AudioRouteDiagnostics", reason: "interruption_unknown")
        }
    }

    private func routeSummary(for ports: [AVAudioSessionPortDescription]) -> String {
        if ports.isEmpty { return "none" }
        return ports.map { port in
            let channels = port.channels?.count ?? 0
            return "\(port.portType.rawValue){name=\(port.portName),uid=\(port.uid),ch=\(channels)}"
        }.joined(separator: ", ")
    }

    private func routeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "new_device_available"
        case .oldDeviceUnavailable: return "old_device_unavailable"
        case .categoryChange: return "category_change"
        case .override: return "override"
        case .wakeFromSleep: return "wake_from_sleep"
        case .noSuitableRouteForCategory: return "no_suitable_route"
        case .routeConfigurationChange: return "route_config_change"
        case .unknown: return "unknown"
        @unknown default: return "unknown_default"
        }
    }
}
