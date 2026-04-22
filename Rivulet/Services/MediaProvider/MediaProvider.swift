//
//  MediaProvider.swift
//  Rivulet
//
//  The agnostic seam every backend implements. Views talk only to this
//  protocol; backend specifics live below the boundary.
//

import Foundation

/// Per-playback-session progress reporter. Provider creates a value-typed
/// concrete reporter (e.g. `PlexTimelineReporter`) capturing whatever
/// session state it needs.
protocol ProgressReporter: Sendable {
    func start() async
    func progress(position: TimeInterval) async
    func paused(at position: TimeInterval) async
    func stopped(at position: TimeInterval) async
}

protocol MediaProvider: Sendable, Identifiable {
    var id: String { get }                       // "plex:<machineId>"
    var kind: MediaProviderKind { get }
    var displayName: String { get }
    var connectionState: ConnectionState { get }

    // MARK: - Browse
    func libraries() async throws -> [MediaLibrary]
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem>
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem]
    func search(_ query: String) async throws -> [MediaItem]

    /// Items in the same collection as the given `collectionName`. Returns
    /// items from the provider's library matching that collection tag.
    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem]

    /// Provider-curated "related/recommended like this" items.
    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem]

    /// All episodes flattened across all seasons of a show. For shows only.
    /// Plex: getAllLeaves. Jellyfin: /Shows/{id}/Episodes.
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem]

    // MARK: - Detail
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail

    // MARK: - Home rails
    func continueWatching(limit: Int) async throws -> [MediaItem]
    func recentlyAdded(limit: Int) async throws -> [MediaItem]
    /// Plex-native curated hubs. Other providers may return [] and rely on
    /// `HomeComposer` to synthesize from primitives.
    func hubs() async throws -> [MediaHub]

    // MARK: - Playback
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo
    func progressReporter(for itemRef: MediaItemRef, playSessionID: String?) -> any ProgressReporter

    // MARK: - Watch state
    func markPlayed(_ itemRef: MediaItemRef) async throws
    func markUnplayed(_ itemRef: MediaItemRef) async throws
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws

    // MARK: - Watchlist
    var supportsWatchlist: Bool { get }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool
    func addToWatchlist(_ ref: MediaItemRef) async throws
    func removeFromWatchlist(_ ref: MediaItemRef) async throws
}
