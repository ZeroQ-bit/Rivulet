//
//  PlexWatchlistAPI.swift
//  Rivulet
//
//  HTTP layer for metadata.provider.plex.tv watchlist endpoints.
//

import Foundation

protocol PlexWatchlistAPIProtocol: Sendable {
    func fetchAll() async throws -> [PlexWatchlistItem]
    func add(guids: [String]) async throws
    func remove(guid: String) async throws
}

protocol WatchlistCacheProtocol: Sendable {
    func load() -> [PlexWatchlistItem]?
    func save(_ items: [PlexWatchlistItem])
    func clear()
}

final class PlexWatchlistAPI: PlexWatchlistAPIProtocol, @unchecked Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://metadata.provider.plex.tv")!

    private let tokenProvider: @Sendable () -> String?

    init(session: URLSession = .shared, tokenProvider: @escaping @Sendable () -> String?) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func fetchAll() async throws -> [PlexWatchlistItem] {
        guard let token = tokenProvider() else { return [] }
        let url = baseURL.appendingPathComponent("library/sections/watchlist/all")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "200")
        ]

        var request = URLRequest(url: components.url!)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
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
            let posterURL: URL? = raw.thumb.flatMap {
                URL(string: "\(baseURL.absoluteString)\($0)?X-Plex-Token=\(token)")
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

    func add(guids: [String]) async throws {
        guard let token = tokenProvider() else { throw URLError(.userAuthenticationRequired) }
        for guid in guids {
            try await mutate(guid: guid, action: "addToWatchlist", token: token)
        }
    }

    func remove(guid: String) async throws {
        guard let token = tokenProvider() else { throw URLError(.userAuthenticationRequired) }
        try await mutate(guid: guid, action: "removeFromWatchlist", token: token)
    }

    private func mutate(guid: String, action: String, token: String) async throws {
        let url = baseURL.appendingPathComponent("actions/\(action)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "guid", value: guid),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

final class FileWatchlistCache: WatchlistCacheProtocol, @unchecked Sendable {
    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = caches.appendingPathComponent("PlexWatchlist.json")
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
