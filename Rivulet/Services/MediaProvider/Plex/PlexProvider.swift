//
//  PlexProvider.swift
//  Rivulet
//
//  Plex implementation of MediaProvider. Wraps PlexNetworkManager and the
//  existing Plex* singletons; maps PlexMetadata -> agnostic types via
//  PlexMediaMapper at every boundary.
//

import Foundation

final class PlexProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .plex
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let serverURL: String
    let authToken: String
    let networkManager: PlexNetworkManager
    let dataStore: PlexDataStore
    let watchlistAPI: PlexWatchlistAPI

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        networkManager: PlexNetworkManager = .shared,
        dataStore: PlexDataStore = .shared,
        watchlistAPI: PlexWatchlistAPI = PlexWatchlistAPI()
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.networkManager = networkManager
        self.dataStore = dataStore
        self.watchlistAPI = watchlistAPI
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        try await plexCall {
            let plexLibs = try await networkManager.getLibraries(
                serverURL: serverURL, authToken: authToken
            )
            return plexLibs.map { PlexMediaMapper.library($0, providerID: id) }
        }
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: plexSortString(for: sort)
            )
            let mapped = result.items.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
            let total = result.totalSize ?? mapped.count
            let next: Page? = (page.offset + page.limit < total)
                ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
            return PagedResult(items: mapped, total: total, nextPage: next)
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return kids.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func search(_ query: String) async throws -> [MediaItem] {
        // PlexNetworkManager doesn't expose a dedicated search method as of Wave 1.
        // Plex search routes through /hubs/search via custom request shapes;
        // wiring it here without a network-layer helper would duplicate that
        // logic. Throwing rather than returning empty so callers can
        // distinguish "search not implemented" from "no results."
        // Post-Wave-1 task adds a search method to PlexNetworkManager and
        // wires it through.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex search not implemented in Wave 1"
        )
    }

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return PlexMediaMapper.detail(
                meta, providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    // Stubbed in Task 5; Task 7 implements relatedItems + allEpisodes.
    // collectionItems remains a Wave 1 stub — see Task 7's commit message.
    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem] { [] }
    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem] { [] }
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] { [] }

    // MARK: - Home rails

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            // getContinueWatching returns a single PlexHub? whose Metadata is the items.
            let hub = try await networkManager.getContinueWatching(
                serverURL: serverURL, authToken: authToken, count: limit
            )
            let metadata = hub?.Metadata ?? []
            return metadata.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            let items = try await networkManager.getRecentlyAdded(
                serverURL: serverURL, authToken: authToken, limit: limit
            )
            return items.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    /// Plex-native curated hubs. HomeComposer calls this via type-check;
    /// other providers compose hubs from primitives.
    func hubs() async throws -> [MediaHub] {
        try await plexCall {
            let plexHubs = try await networkManager.getHubs(
                serverURL: serverURL, authToken: authToken
            )
            return plexHubs.map {
                PlexMediaMapper.hub($0, providerID: id,
                                   serverURL: serverURL, authToken: authToken)
            }
        }
    }

    // MARK: - Playback

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        let detail = try await fullDetail(for: itemRef)
        let chosen: MediaSource
        if let sourceID, let match = detail.mediaSources.first(where: { $0.id == sourceID }) {
            chosen = match
        } else if let first = detail.mediaSources.first {
            chosen = first
        } else {
            throw MediaProviderError.notFound
        }
        return StreamInfo(source: chosen, playSessionID: nil, trackInfoAvailable: true)
    }

    func progressReporter(for itemRef: MediaItemRef, playSessionID: String?) -> any ProgressReporter {
        PlexTimelineReporter(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: itemRef.itemID,
            networkManager: networkManager
        )
    }

    // MARK: - Watch state

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markWatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markUnwatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await plexCall {
            try await networkManager.reportProgress(
                serverURL: serverURL, authToken: authToken,
                ratingKey: itemRef.itemID, timeMs: Int(position * 1000), state: "playing"
            )
        }
    }

    // MARK: - Watchlist

    var supportsWatchlist: Bool { true }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool {
        // The shared PlexWatchlistService maintains an observable cache of
        // watchlist GUIDs. For TMDB-rooted refs (e.g. from Discover) we can
        // answer directly. For Plex-rooted refs (library items) we'd need to
        // resolve the item's tmdb GUID first — left for Phase 3 watchlist
        // wiring once it has the MediaItem in hand.
        await MainActor.run {
            if ref.providerID == "tmdb",
               let tmdbId = Int(ref.itemID) {
                return PlexWatchlistService.shared.contains(tmdbId: tmdbId)
            }
            return false
        }
    }

    func addToWatchlist(_ ref: MediaItemRef) async throws {
        // TODO(phase-3-watchlist): resolve the item's tmdb:// guid (via
        // LibraryGUIDIndex for Plex refs, direct from ref for TMDB refs) and
        // call PlexWatchlistService.shared.add(guid:item:). Phase 3's
        // detail-view watchlist toggle and Discover-row context menu have
        // the MediaItem (with title/year/posterURL) needed to build the
        // PlexWatchlistItem stub.
        throw MediaProviderError.backendSpecific(
            underlying: "Use PlexWatchlistService.shared.add for now; provider passthrough wired in Phase 3"
        )
    }

    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        // TODO(phase-3-watchlist): mirror addToWatchlist's plumbing.
        throw MediaProviderError.backendSpecific(
            underlying: "Use PlexWatchlistService.shared.remove for now; provider passthrough wired in Phase 3"
        )
    }

    // MARK: - Helpers

    private func plexSortString(for sort: SortOption) -> String? {
        switch sort {
        case .titleAsc: return "titleSort:asc"
        case .titleDesc: return "titleSort:desc"
        case .releaseDateDesc: return "originallyAvailableAt:desc"
        case .addedAtDesc: return "addedAt:desc"
        case .ratingDesc: return "rating:desc"
        }
    }
}
