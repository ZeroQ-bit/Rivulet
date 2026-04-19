//
//  MediaItemDetailCacheTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemDetailCacheTests: XCTestCase {
    func test_storeAndRetrieve() async {
        let cache = MediaItemDetailCache()
        let cast = [CastMember(name: "A", role: "B", profileImageURL: nil)]
        await cache.store(id: "tmdb:1", cast: cast, runtimeMinutes: 100, genres: ["Drama"])

        let result = await cache.detail(for: "tmdb:1")
        XCTAssertEqual(result?.cast, cast)
        XCTAssertEqual(result?.runtimeMinutes, 100)
        XCTAssertEqual(result?.genres, ["Drama"])
    }

    func test_unknownIdReturnsNil() async {
        let cache = MediaItemDetailCache()
        let result = await cache.detail(for: "tmdb:999")
        XCTAssertNil(result)
    }

    func test_storeOverwrites() async {
        let cache = MediaItemDetailCache()
        await cache.store(id: "tmdb:1", cast: [], runtimeMinutes: 100, genres: ["A"])
        await cache.store(id: "tmdb:1", cast: [], runtimeMinutes: 120, genres: ["B"])
        let result = await cache.detail(for: "tmdb:1")
        XCTAssertEqual(result?.runtimeMinutes, 120)
        XCTAssertEqual(result?.genres, ["B"])
    }
}
