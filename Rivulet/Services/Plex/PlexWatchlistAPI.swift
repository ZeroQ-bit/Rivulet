//
//  PlexWatchlistAPI.swift
//  Rivulet
//
//  HTTP layer for the Plex Discover Watchlist.
//
//  Two host families are involved:
//
//  - `discover.provider.plex.tv` serves the watchlist itself
//    (`/library/sections/watchlist/all`) AND the actions
//    (`/actions/addToWatchlist`, `/actions/removeFromWatchlist`).
//    Container pagination headers are NOT accepted on the watchlist endpoint.
//
//  - `metadata.provider.plex.tv` serves the discover-side metadata, including
//    the matches lookup needed to resolve an external GUID (tmdb://, imdb://,
//    tvdb://) to a Plex Discover ratingKey. The action endpoints want THAT
//    ratingKey, not the external GUID.
//

import Foundation
import os.log

private let watchlistAPILog = Logger(subsystem: "com.rivulet.app", category: "PlexWatchlistAPI")

/// Custom error so the caller can tell why a watchlist request failed.
struct PlexWatchlistHTTPError: Error, LocalizedError {
    let statusCode: Int
    let bodySnippet: String?
    var errorDescription: String? {
        if let bodySnippet, !bodySnippet.isEmpty {
            return "HTTP \(statusCode): \(bodySnippet)"
        }
        return "HTTP \(statusCode)"
    }
}

protocol PlexWatchlistAPIProtocol: Sendable {
    func fetchAll(token: String) async throws -> [PlexWatchlistItem]
    func add(guids: [String], token: String) async throws
    func remove(guid: String, token: String) async throws
}

protocol WatchlistCacheProtocol: Sendable {
    func load() -> [PlexWatchlistItem]?
    func save(_ items: [PlexWatchlistItem])
    func clear()
}

final class PlexWatchlistAPI: PlexWatchlistAPIProtocol, Sendable {
    private let session: URLSession
    private let discoverHost = URL(string: "https://discover.provider.plex.tv")!
    private let metadataHost = URL(string: "https://metadata.provider.plex.tv")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAll(token: String) async throws -> [PlexWatchlistItem] {
        let url = discoverHost.appendingPathComponent("library/sections/watchlist/all")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        // Plex Discover rejects X-Plex-Container-Size on this endpoint with a
        // 400 ("Invalid value provided for x-plex-container-size!"). The
        // watchlist is small in practice, so the default response is fine.
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        var request = URLRequest(url: components.url!)
        addPlexHeaders(to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        watchlistAPILog.info("fetchAll URL=\(request.url?.absoluteString ?? "?", privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            watchlistAPILog.error("fetchAll HTTP \(http.statusCode) body=\(snippet ?? "(non-utf8)", privacy: .public)")
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }

        struct Container: Decodable {
            struct MediaContainer: Decodable {
                let Metadata: [Raw]?
            }
            let MediaContainer: MediaContainer
        }
        struct Raw: Decodable {
            let ratingKey: String?
            let title: String?
            let year: Int?
            let type: String?
            let thumb: String?
            let Guid: [GuidRef]?
        }
        struct GuidRef: Decodable { let id: String }

        let decoded = try JSONDecoder().decode(Container.self, from: data)
        let raws = decoded.MediaContainer.Metadata ?? []

        return raws.compactMap { raw -> PlexWatchlistItem? in
            guard let title = raw.title, let id = raw.ratingKey else { return nil }
            let watchType: PlexWatchlistItem.WatchlistType
            switch raw.type {
            case "movie": watchType = .movie
            case "show": watchType = .show
            default: return nil
            }
            let guids = (raw.Guid ?? []).map(\.id)
            // Discover serves thumbs as fully-qualified URLs to public CDNs
            // (metadata-static.plex.tv, image.tmdb.org). Use them as-is; only
            // build a host-relative URL with the token when the thumb is a
            // relative path.
            let posterURL: URL? = raw.thumb.flatMap { thumb in
                if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
                    return URL(string: thumb)
                }
                return URL(string: "\(self.discoverHost.absoluteString)\(thumb)?X-Plex-Token=\(token)")
            }
            return PlexWatchlistItem(
                id: id,
                title: title,
                year: raw.year,
                type: watchType,
                posterURL: posterURL,
                guids: guids
            )
        }
    }

    func add(guids: [String], token: String) async throws {
        for guid in guids {
            try await mutate(externalGuid: guid, action: "addToWatchlist", token: token)
        }
    }

    func remove(guid: String, token: String) async throws {
        try await mutate(externalGuid: guid, action: "removeFromWatchlist", token: token)
    }

    /// Resolve an external GUID (tmdb://, imdb://, tvdb://) to the Plex Discover
    /// ratingKey, then issue the action.
    private func mutate(externalGuid: String, action: String, token: String) async throws {
        let plexRatingKey = try await resolveDiscoverRatingKey(forGuid: externalGuid, token: token)

        let url = discoverHost.appendingPathComponent("actions/\(action)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "ratingKey", value: plexRatingKey),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        addPlexHeaders(to: &request)
        watchlistAPILog.info("mutate \(action, privacy: .public) URL=\(request.url?.absoluteString ?? "?", privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            watchlistAPILog.error("mutate \(action, privacy: .public) HTTP \(http.statusCode) body=\(snippet ?? "(non-utf8)", privacy: .public)")
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }
    }

    /// Hits Plex's metadata matches endpoint and returns the discover ratingKey
    /// (e.g. "5d7768daad5437001f75108e") for an external GUID.
    private func resolveDiscoverRatingKey(forGuid externalGuid: String, token: String) async throws -> String {
        // The matches endpoint expects a Plex media `type` integer:
        //   1 = movie, 2 = show. We infer from the guid prefix when possible.
        // For tmdb://, both could apply; the Plex matcher accepts the wrong
        // type as a 0-result response, so we let the caller pre-classify if
        // needed. Default to movie and fall back to show on empty result.
        if let ratingKey = try await matches(type: 1, externalGuid: externalGuid, token: token) {
            return ratingKey
        }
        if let ratingKey = try await matches(type: 2, externalGuid: externalGuid, token: token) {
            return ratingKey
        }
        watchlistAPILog.error("resolveDiscoverRatingKey: no match for \(externalGuid, privacy: .public)")
        throw PlexWatchlistHTTPError(
            statusCode: 404,
            bodySnippet: "No Plex Discover match for \(externalGuid)"
        )
    }

    private func matches(type: Int, externalGuid: String, token: String) async throws -> String? {
        let url = metadataHost.appendingPathComponent("library/metadata/matches")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "\(type)"),
            URLQueryItem(name: "guid", value: externalGuid),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        var request = URLRequest(url: components.url!)
        addPlexHeaders(to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        watchlistAPILog.info("matches type=\(type) URL=\(request.url?.absoluteString ?? "?", privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }

        struct Container: Decodable {
            struct MediaContainer: Decodable {
                let Metadata: [Raw]?
            }
            let MediaContainer: MediaContainer
        }
        struct Raw: Decodable { let ratingKey: String? }

        let decoded = try JSONDecoder().decode(Container.self, from: data)
        return decoded.MediaContainer.Metadata?.first?.ratingKey
    }

    private func addPlexHeaders(to request: inout URLRequest) {
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.addValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.addValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
    }
}

final class FileWatchlistCache: WatchlistCacheProtocol, @unchecked Sendable {
    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Bump filename when the on-disk schema changes (e.g. poster URL fix
        // 2026-04-15) so stale cached items don't persist after an update.
        url = caches.appendingPathComponent("PlexWatchlist.v2.json")
        // Best-effort cleanup of older versions.
        let stale = caches.appendingPathComponent("PlexWatchlist.json")
        try? FileManager.default.removeItem(at: stale)
    }

    func load() -> [PlexWatchlistItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PlexWatchlistItem].self, from: data)
    }

    func save(_ items: [PlexWatchlistItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
