//
//  PlexWatchlistService.swift
//  Rivulet
//
//  Account-level Plex Watchlist with optimistic writes and disk cache.
//

import Foundation
import Combine
import os.log

private let watchlistLog = Logger(subsystem: "com.rivulet.app", category: "PlexWatchlist")

@MainActor
final class PlexWatchlistService: ObservableObject {
    static let shared = PlexWatchlistService(
        api: PlexWatchlistAPI(),
        cache: FileWatchlistCache(),
        // Watchlist lives on metadata.provider.plex.tv (the account-wide
        // Discover API), so it requires the owner's authToken — NOT the
        // server-specific selectedServerToken.
        tokenProvider: { PlexAuthManager.shared.authToken }
    )

    @Published private(set) var watchlistItems: [PlexWatchlistItem] = []
    @Published private(set) var watchlistGUIDs: Set<String> = []
    /// Carousel-bound projection of `watchlistItems` as `[MediaItem]`. Built
    /// by `rebuildMediaItems()` after any mutation; consumers that drive the
    /// unified preview carousel (WatchlistHubRow) read from here.
    @Published private(set) var mediaItems: [MediaItem] = []
    @Published private(set) var lastFetchError: Error?

    /// A user-facing message surfaced when the most recent write optimistically
    /// reverted. Views observe this to show a transient toast; setter auto-clears
    /// after a short delay so consumers don't need to manage the lifecycle.
    @Published private(set) var transientWriteError: String?

    private let api: PlexWatchlistAPIProtocol
    private let cache: WatchlistCacheProtocol
    private let tokenProvider: @MainActor () -> String?
    private var lastFetched: Date?

    // 60s balances responsiveness with network traffic — fresh enough that
    // changes made on another Plex client appear quickly on Home, but not so
    // aggressive that idle screens hammer the API.
    private let staleAfter: TimeInterval = 60
    private let transientErrorDuration: TimeInterval = 3

    init(
        api: PlexWatchlistAPIProtocol,
        cache: WatchlistCacheProtocol,
        tokenProvider: @escaping @MainActor () -> String? = { "test-token" }
    ) {
        self.api = api
        self.cache = cache
        self.tokenProvider = tokenProvider

        if let cached = cache.load() {
            watchlistItems = cached
            watchlistGUIDs = Set(cached.flatMap(\.guids))
            // Cache load happens during init; rebuild the MediaItem projection
            // off the main work so the synchronous init returns quickly.
            Task { [weak self] in
                await self?.rebuildMediaItems()
            }
        }
    }

    func fetchWatchlist(force: Bool = false) async {
        if !force, let lastFetched, Date().timeIntervalSince(lastFetched) < staleAfter {
            watchlistLog.debug("fetchWatchlist skipped: cache age <\(self.staleAfter)s")
            return
        }
        guard let token = tokenProvider() else {
            watchlistLog.warning("fetchWatchlist aborted: no Plex token")
            return
        }
        do {
            let items = try await api.fetchAll(token: token)
            watchlistItems = items
            watchlistGUIDs = Set(items.flatMap(\.guids))
            cache.save(items)
            lastFetched = Date()
            lastFetchError = nil
            await rebuildMediaItems()
            watchlistLog.info("fetchWatchlist success: \(items.count) items")
        } catch {
            lastFetchError = error
            watchlistLog.error("fetchWatchlist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(guid: String, item: PlexWatchlistItem) async {
        guard let token = tokenProvider() else {
            surface("Sign in to use Watchlist")
            return
        }

        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // Optimistic update
        watchlistItems.insert(item, at: 0)
        watchlistGUIDs.formUnion(item.guids)
        await rebuildMediaItems()

        do {
            try await api.add(guids: [guid], token: token)
            cache.save(watchlistItems)
            watchlistLog.info("add succeeded: \(guid, privacy: .public)")
        } catch {
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            await rebuildMediaItems()
            lastFetchError = error
            watchlistLog.error("add failed for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            surface("Couldn't update Watchlist")
        }
    }

    func remove(guid: String) async {
        guard let token = tokenProvider() else {
            surface("Sign in to use Watchlist")
            return
        }

        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // Optimistic update: remove matching items and ALL their associated GUIDs
        let removedItems = watchlistItems.filter { $0.guids.contains(guid) }
        let removedGuids = Set(removedItems.flatMap(\.guids))
        watchlistItems.removeAll { $0.guids.contains(guid) }
        watchlistGUIDs.subtract(removedGuids)
        await rebuildMediaItems()

        do {
            try await api.remove(guid: guid, token: token)
            cache.save(watchlistItems)
            watchlistLog.info("remove succeeded: \(guid, privacy: .public)")
        } catch {
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            await rebuildMediaItems()
            lastFetchError = error
            watchlistLog.error("remove failed for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            surface("Couldn't update Watchlist")
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
        mediaItems = []
        lastFetched = nil
        cache.clear()
    }

    /// Rebuilds the `mediaItems` projection from `watchlistItems`. Synthesizes
    /// a `TMDBListItem` stub so the existing `MediaItem.from(tmdb:)` path
    /// (which also resolves any in-library Plex match) drives the conversion;
    /// then preserves the watchlist row's absolute posterURL via `with(posterOverride:)`
    /// since the synthesized stub has no posterPath.
    private func rebuildMediaItems() async {
        var built: [MediaItem] = []
        for wl in watchlistItems {
            guard let tmdbId = wl.tmdbId else { continue }
            let mediaType: TMDBMediaType = (wl.type == .movie) ? .movie : .tv
            let stub = TMDBListItem(
                id: tmdbId,
                title: wl.title,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: wl.year.map { "\($0)" },
                voteAverage: nil,
                mediaType: mediaType
            )
            let item = await MediaItem.from(tmdb: stub)
            built.append(item.with(posterOverride: wl.posterURL))
        }
        mediaItems = built
    }

    private func surface(_ message: String) {
        transientWriteError = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(transientErrorDuration))
            guard let self else { return }
            if self.transientWriteError == message {
                self.transientWriteError = nil
            }
        }
    }
}
