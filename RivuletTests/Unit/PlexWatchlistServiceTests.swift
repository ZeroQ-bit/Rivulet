//
//  PlexWatchlistServiceTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexWatchlistServiceTests: XCTestCase {

    func testOptimisticAddRevertsOnFailure() async {
        let api = StubWatchlistAPI()
        api.shouldFailWrites = true

        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        // After failure, the GUID should not be in the set.
        XCTAssertFalse(service.watchlistGUIDs.contains("tmdb://1"))
    }

    func testOptimisticAddPersistsOnSuccess() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://1"))
        XCTAssertEqual(service.watchlistItems.count, 1)
    }

    func testOptimisticRemovePutsItBackOnFailure() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        api.shouldFailWrites = true
        await service.remove(guid: "tmdb://1")

        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://1"))
        XCTAssertEqual(service.watchlistItems.count, 1)
    }

    func testFetchWatchlistPopulatesState() async {
        let api = StubWatchlistAPI()
        api.fetchResult = [makeItem(id: "9", guid: "tmdb://9")]

        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.fetchWatchlist()

        XCTAssertEqual(service.watchlistItems.count, 1)
        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://9"))
    }

    func testContainsTmdbIdMatchesGuid() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://42", item: makeItem(id: "42", guid: "tmdb://42"))

        XCTAssertTrue(service.contains(tmdbId: 42))
        XCTAssertFalse(service.contains(tmdbId: 43))
    }

    func testResetClearsState() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        service.reset()

        XCTAssertTrue(service.watchlistItems.isEmpty)
        XCTAssertTrue(service.watchlistGUIDs.isEmpty)
    }

    func testRemoveClearsAllGuidsForItem() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        let multiGuidItem = PlexWatchlistItem(
            id: "1",
            title: "Multi",
            year: 2024,
            type: .movie,
            posterURL: nil,
            guids: ["tmdb://42", "imdb://tt123", "tvdb://999"]
        )
        await service.add(guid: "tmdb://42", item: multiGuidItem)
        XCTAssertTrue(service.watchlistGUIDs.contains("imdb://tt123"))

        await service.remove(guid: "tmdb://42")

        XCTAssertFalse(service.watchlistGUIDs.contains("tmdb://42"))
        XCTAssertFalse(service.watchlistGUIDs.contains("imdb://tt123"))
        XCTAssertFalse(service.watchlistGUIDs.contains("tvdb://999"))
        XCTAssertTrue(service.watchlistItems.isEmpty)
    }

    private func makeItem(id: String, guid: String = "tmdb://1") -> PlexWatchlistItem {
        PlexWatchlistItem(
            id: id,
            title: "Test",
            year: 2024,
            type: .movie,
            posterURL: nil,
            guids: [guid]
        )
    }
}

// MARK: - Stubs

final class StubWatchlistAPI: PlexWatchlistAPIProtocol {
    var shouldFailWrites = false
    var fetchResult: [PlexWatchlistItem] = []

    func fetchAll() async throws -> [PlexWatchlistItem] { fetchResult }

    func add(guids: [String]) async throws {
        if shouldFailWrites { throw URLError(.notConnectedToInternet) }
    }

    func remove(guid: String) async throws {
        if shouldFailWrites { throw URLError(.notConnectedToInternet) }
    }
}

final class NullWatchlistCache: WatchlistCacheProtocol {
    func load() -> [PlexWatchlistItem]? { nil }
    func save(_ items: [PlexWatchlistItem]) {}
    func clear() {}
}
