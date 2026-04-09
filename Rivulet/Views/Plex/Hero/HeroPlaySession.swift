//
//  HeroPlaySession.swift
//  Rivulet
//
//  Resolves "play immediately" targets for hero-carousel items.
//  Movies and episodes play directly; shows/seasons resolve to the OnDeck
//  episode, falling back to the first episode of the first season.
//

import Foundation
import os.log

private let heroPlayLog = Logger(subsystem: "com.rivulet.app", category: "HeroPlay")

enum HeroPlaySession {
    /// Returns a metadata item that is ready to play.
    ///
    /// - For movies and episodes, the input is returned unchanged.
    /// - For shows and seasons, the resolver calls `getFullMetadata(includeOnDeck=1)`
    ///   and prefers `OnDeck.Metadata.first`. When no OnDeck episode exists it
    ///   walks to the first season's first episode.
    /// - On any error, the original item is returned so the caller can fall
    ///   back to the standard detail-view flow.
    static func resolvePlaybackTarget(
        for item: PlexMetadata,
        serverURL: String,
        authToken: String
    ) async -> PlexMetadata {
        guard let type = item.type, type == "show" || type == "season",
              let ratingKey = item.ratingKey
        else {
            return item
        }

        let network = PlexNetworkManager.shared
        do {
            let full = try await network.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            if let onDeckItem = full.OnDeck?.Metadata?.first {
                heroPlayLog.info("[HeroPlay] Resolved show=\(ratingKey, privacy: .public) → OnDeck ep \(onDeckItem.ratingKey ?? "?", privacy: .public)")
                return await fetchFullIfPossible(
                    onDeckItem,
                    serverURL: serverURL,
                    authToken: authToken
                )
            }

            // Walk the hierarchy: show → first season → first episode
            let children = try await network.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            if type == "season" {
                // Already a season — children are the episodes
                if let firstEpisode = children.first {
                    heroPlayLog.info("[HeroPlay] Season \(ratingKey, privacy: .public) → first ep \(firstEpisode.ratingKey ?? "?", privacy: .public)")
                    return await fetchFullIfPossible(
                        firstEpisode,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                }
            } else {
                guard let firstSeasonKey = children.first?.ratingKey else { return item }
                let episodes = try await network.getChildren(
                    serverURL: serverURL,
                    authToken: authToken,
                    ratingKey: firstSeasonKey
                )
                if let firstEpisode = episodes.first {
                    heroPlayLog.info("[HeroPlay] Show \(ratingKey, privacy: .public) → S1E1 \(firstEpisode.ratingKey ?? "?", privacy: .public)")
                    return await fetchFullIfPossible(
                        firstEpisode,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                }
            }
        } catch {
            heroPlayLog.error("[HeroPlay] Resolution failed for \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return item
    }

    /// Upgrade a hub-derived episode stub to a fully-loaded metadata blob so the
    /// player has stream info. Returns the original item on failure.
    private static func fetchFullIfPossible(
        _ item: PlexMetadata,
        serverURL: String,
        authToken: String
    ) async -> PlexMetadata {
        guard let key = item.ratingKey else { return item }
        do {
            return try await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: key
            )
        } catch {
            return item
        }
    }
}
