//
//  LibraryGUIDIndexTests.swift
//  RivuletTests

import XCTest
@testable import Rivulet

final class LibraryGUIDIndexTests: XCTestCase {

    func testParsesTMDBImdbTvdbGUIDs() async {
        var item = PlexMetadata(
            ratingKey: "1",
            type: "movie",
            title: "Foo",
            guid: "plex://movie/abc"
        )
        item.Guid = [
            PlexGuid(id: "tmdb://12345"),
            PlexGuid(id: "imdb://tt7654321"),
            PlexGuid(id: "tvdb://999")
        ]

        let index = LibraryGUIDIndex()
        await index.replace(with: [item])

        let byTmdb = await index.lookup(tmdbId: 12345, type: .movie)
        XCTAssertEqual(byTmdb?.ratingKey, "1")

        let byTmdbGuid = await index.lookup(guid: "tmdb://12345")
        XCTAssertEqual(byTmdbGuid?.ratingKey, "1")

        let byImdb = await index.lookup(guid: "imdb://tt7654321")
        XCTAssertEqual(byImdb?.ratingKey, "1")

        let byTvdb = await index.lookup(guid: "tvdb://999")
        XCTAssertEqual(byTvdb?.ratingKey, "1")
    }

    func testIgnoresItemsWithoutExternalGUIDs() async {
        let item = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo", guid: "plex://movie/abc")
        let index = LibraryGUIDIndex()
        await index.replace(with: [item])

        let result = await index.lookup(tmdbId: 1, type: .movie)
        XCTAssertNil(result)
    }

    func testTypeAwareLookupSegregatesMovieFromTV() async {
        var movie = PlexMetadata(ratingKey: "1", type: "movie", title: "Foo")
        movie.Guid = [PlexGuid(id: "tmdb://100")]

        var show = PlexMetadata(ratingKey: "2", type: "show", title: "Bar")
        show.Guid = [PlexGuid(id: "tmdb://100")]

        let index = LibraryGUIDIndex()
        await index.replace(with: [movie, show])

        XCTAssertEqual(await index.lookup(tmdbId: 100, type: .movie)?.ratingKey, "1")
        XCTAssertEqual(await index.lookup(tmdbId: 100, type: .tv)?.ratingKey, "2")
    }

    func testReplaceClearsPreviousState() async {
        var item1 = PlexMetadata(ratingKey: "1", type: "movie", title: "A")
        item1.Guid = [PlexGuid(id: "tmdb://1")]

        var item2 = PlexMetadata(ratingKey: "2", type: "movie", title: "B")
        item2.Guid = [PlexGuid(id: "tmdb://2")]

        let index = LibraryGUIDIndex()
        await index.replace(with: [item1])
        await index.replace(with: [item2])

        XCTAssertNil(await index.lookup(tmdbId: 1, type: .movie))
        XCTAssertEqual(await index.lookup(tmdbId: 2, type: .movie)?.ratingKey, "2")
    }

    func testIgnoresNonMovieNonShowItems() async {
        var episode = PlexMetadata(ratingKey: "1", type: "episode", title: "Ep1")
        episode.Guid = [PlexGuid(id: "tmdb://500")]

        let index = LibraryGUIDIndex()
        await index.replace(with: [episode])

        // Episodes shouldn't be indexed by tmdbId — that index is movie/show only.
        XCTAssertNil(await index.lookup(tmdbId: 500, type: .movie))
        XCTAssertNil(await index.lookup(tmdbId: 500, type: .tv))
    }
}
