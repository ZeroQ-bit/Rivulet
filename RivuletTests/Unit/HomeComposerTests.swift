//
//  HomeComposerTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class HomeComposerTests: XCTestCase {
    func test_synthesizesHubsFromPrimitives_forNonPlexProvider() async throws {
        let stub = StubMediaProvider()
        stub.continueWatchingItems = [makeItem("a"), makeItem("b")]
        stub.recentlyAddedItems = [makeItem("c")]

        let hubs = try await HomeComposer.compose(provider: stub)
        XCTAssertEqual(hubs.count, 2)
        XCTAssertEqual(hubs[0].title, "Continue Watching")
        XCTAssertEqual(hubs[0].items.count, 2)
        XCTAssertEqual(hubs[1].title, "Recently Added")
        XCTAssertEqual(hubs[1].items.count, 1)
    }

    func test_emptyPrimitives_returnsNoHubs() async throws {
        let stub = StubMediaProvider()
        let hubs = try await HomeComposer.compose(provider: stub)
        XCTAssertTrue(hubs.isEmpty)
    }

    private func makeItem(_ id: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: .movie, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil)
        )
    }
}

/// Minimal stub provider used by HomeComposer tests.
final class StubMediaProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id = "stub"
    nonisolated let kind = MediaProviderKind.plex
    nonisolated let displayName = "Stub"
    let connectionState = ConnectionState.connected
    let supportsWatchlist = false

    var continueWatchingItems: [MediaItem] = []
    var recentlyAddedItems: [MediaItem] = []

    func libraries() async throws -> [MediaLibrary] { [] }
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] { [] }
    func search(_ query: String) async throws -> [MediaItem] { [] }
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        throw MediaProviderError.notFound
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { continueWatchingItems }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { recentlyAddedItems }
    func hubs() async throws -> [MediaHub] { [] }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        throw MediaProviderError.notFound
    }
    func progressReporter(for itemRef: MediaItemRef, playSessionID: String?) -> any ProgressReporter {
        StubReporter()
    }
    func markPlayed(_ itemRef: MediaItemRef) async throws {}
    func markUnplayed(_ itemRef: MediaItemRef) async throws {}
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {}
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {}
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {}
}

struct StubReporter: ProgressReporter {
    func start() async {}
    func progress(position: TimeInterval) async {}
    func paused(at position: TimeInterval) async {}
    func stopped(at position: TimeInterval) async {}
}
