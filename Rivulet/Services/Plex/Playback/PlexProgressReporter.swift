//
//  PlexProgressReporter.swift
//  Rivulet
//
//  Reports playback progress to Plex server for timeline tracking
//

import Foundation

/// Reports playback progress and watch status to Plex server
actor PlexProgressReporter {
    static let shared = PlexProgressReporter()

    private var lastReportedTimes: [String: TimeInterval] = [:]

    private init() {}

    // MARK: - Progress Reporting

    /// Reports current playback position to Plex
    /// - Parameters:
    ///   - ratingKey: The Plex rating key for the media item
    ///   - time: Current playback time in seconds
    ///   - duration: Total duration in seconds
    ///   - state: Playback state ("playing", "paused", "stopped")
    ///   - forceReport: If true, bypasses throttle to report immediately (for state changes)
    func reportProgress(
        ratingKey: String,
        time: TimeInterval,
        duration: TimeInterval,
        state: String,
        forceReport: Bool = false
    ) async {
        guard !ratingKey.isEmpty else { return }

        // Throttle reports - only report if time changed significantly (unless forced)
        if !forceReport, let lastTime = lastReportedTimes[ratingKey], abs(time - lastTime) < 5 {
            return
        }
        lastReportedTimes[ratingKey] = time

        guard let server = await getServer() else { return }

        let timeMs = Int(time * 1000)
        let durationMs = Int(duration * 1000)

        // Get Plex client identifiers on MainActor
        let clientInfo = await MainActor.run {
            (
                clientId: PlexAPI.clientIdentifier,
                platform: PlexAPI.platform,
                device: PlexAPI.deviceName,
                product: PlexAPI.productName
            )
        }

        // Build timeline URL with all required parameters
        var components = URLComponents(string: "\(server.address)/:/timeline")
        components?.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientInfo.clientId),
            URLQueryItem(name: "X-Plex-Platform", value: clientInfo.platform),
            URLQueryItem(name: "X-Plex-Device", value: clientInfo.device),
            URLQueryItem(name: "X-Plex-Product", value: clientInfo.product)
        ]

        guard let url = components?.url else { return }

        do {
            _ = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token]
            )
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to report progress: \(error)")
        }
    }

    /// Marks an item as fully watched (scrobble)
    /// - Parameter ratingKey: The Plex rating key for the media item
    func markAsWatched(ratingKey: String) async {
        guard !ratingKey.isEmpty else { return }
        guard let server = await getServer() else { return }

        let urlString = "\(server.address)/:/scrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"

        guard let url = URL(string: urlString) else { return }

        do {
            _ = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token]
            )
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to mark as watched: \(error)")
        }
    }

    /// Marks an item as unwatched
    /// - Parameter ratingKey: The Plex rating key for the media item
    func markAsUnwatched(ratingKey: String) async {
        guard !ratingKey.isEmpty else { return }
        guard let server = await getServer() else { return }

        let urlString = "\(server.address)/:/unscrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"

        guard let url = URL(string: urlString) else { return }

        do {
            _ = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token]
            )
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to mark as unwatched: \(error)")
        }
    }

    // MARK: - Helpers

    private func getServer() async -> (address: String, token: String)? {
        await MainActor.run {
            let authManager = PlexAuthManager.shared
            guard let address = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else {
                return nil
            }
            return (address, token)
        }
    }
}
