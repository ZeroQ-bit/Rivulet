//
//  PlexWatchlistService.swift
//  Rivulet
//
//  Account-level Plex Watchlist with optimistic writes and disk cache.
//

import Foundation
import Combine

@MainActor
final class PlexWatchlistService: ObservableObject {
    static let shared = PlexWatchlistService(
        api: PlexWatchlistAPI(tokenProvider: { PlexAuthManager.shared.selectedServerToken }),
        cache: FileWatchlistCache()
    )

    @Published private(set) var watchlistItems: [PlexWatchlistItem] = []
    @Published private(set) var watchlistGUIDs: Set<String> = []
    @Published private(set) var lastFetchError: Error?

    private let api: PlexWatchlistAPIProtocol
    private let cache: WatchlistCacheProtocol
    private var lastFetched: Date?
    private let staleAfter: TimeInterval = 60

    init(api: PlexWatchlistAPIProtocol, cache: WatchlistCacheProtocol) {
        self.api = api
        self.cache = cache

        if let cached = cache.load() {
            watchlistItems = cached
            watchlistGUIDs = Set(cached.flatMap(\.guids))
        }
    }

    func fetchWatchlist(force: Bool = false) async {
        if !force, let lastFetched, Date().timeIntervalSince(lastFetched) < staleAfter {
            return
        }
        do {
            let items = try await api.fetchAll()
            watchlistItems = items
            watchlistGUIDs = Set(items.flatMap(\.guids))
            cache.save(items)
            lastFetched = Date()
            lastFetchError = nil
        } catch {
            lastFetchError = error
        }
    }

    func add(guid: String, item: PlexWatchlistItem) async {
        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // Optimistic update
        watchlistItems.insert(item, at: 0)
        watchlistGUIDs.formUnion(item.guids)

        do {
            try await api.add(guids: [guid])
            cache.save(watchlistItems)
        } catch {
            // Revert
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            lastFetchError = error
        }
    }

    func remove(guid: String) async {
        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // Optimistic update
        watchlistItems.removeAll { $0.guids.contains(guid) }
        watchlistGUIDs.subtract([guid])

        do {
            try await api.remove(guid: guid)
            cache.save(watchlistItems)
        } catch {
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            lastFetchError = error
        }
    }

    func contains(guid: String) -> Bool {
        watchlistGUIDs.contains(guid)
    }

    func contains(tmdbId: Int) -> Bool {
        watchlistGUIDs.contains("tmdb://\(tmdbId)")
    }

    func reset() {
        watchlistItems = []
        watchlistGUIDs = []
        lastFetched = nil
        cache.clear()
    }
}
