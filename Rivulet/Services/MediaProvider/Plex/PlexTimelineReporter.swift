//
//  PlexTimelineReporter.swift
//  Rivulet
//
//  Plex implementation of the agnostic ProgressReporter protocol. Wraps
//  PlexNetworkManager's /:/timeline endpoint with the right state strings
//  and ms time conversion.
//
//  Note: distinct from `PlexProgressReporter` (the throttled actor in
//  Services/Plex/Playback/) which is the existing playback-side reporter
//  used by player view models. This is the protocol-conforming value type
//  exposed via MediaProvider.progressReporter(for:playSessionID:).
//

import Foundation

struct PlexTimelineReporter: ProgressReporter {
    let serverURL: String
    let authToken: String
    let ratingKey: String
    let networkManager: PlexNetworkManager

    func start() async {
        // Plex doesn't have a separate "start" call — first progress doubles as start.
    }

    func progress(position: TimeInterval) async {
        try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "playing"
        )
    }

    func paused(at position: TimeInterval) async {
        try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "paused"
        )
    }

    func stopped(at position: TimeInterval) async {
        try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "stopped"
        )
    }
}
