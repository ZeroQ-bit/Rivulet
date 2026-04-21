//
//  MediaItemTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemTests: XCTestCase {

    func test_fromPlex_extractsCoreFields() {
        var meta = PlexMetadata()
        meta.ratingKey = "12345"
        meta.type = "movie"
        meta.title = "Blade Runner 2049"
        meta.year = 2017
        meta.summary = "Sequel."
        meta.duration = 2 * 60 * 60 * 1000   // 120 min in ms
        meta.rating = 8.0
        meta.thumb = "/library/metadata/12345/thumb/123"
        meta.art = "/library/metadata/12345/art/123"
        meta.Genre = [PlexTag(_id: nil, tag: "Sci-Fi"), PlexTag(_id: nil, tag: "Drama")]

        let item = MediaItem.from(plex: meta)

        XCTAssertEqual(item.id, "plex:12345")
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.source, .plex)
        XCTAssertEqual(item.title, "Blade Runner 2049")
        XCTAssertEqual(item.year, 2017)
        XCTAssertEqual(item.overview, "Sequel.")
        XCTAssertEqual(item.runtimeMinutes, 120)
        XCTAssertEqual(item.rating, 8.0)
        XCTAssertEqual(item.genres, ["Sci-Fi", "Drama"])
        XCTAssertNotNil(item.plexMetadata)
        XCTAssertNotNil(item.plexMatch)        // Plex source items always have plexMatch == self
        XCTAssertNil(item.tmdbListItem)
        XCTAssertEqual(item.cast, [])
    }

    func test_fromPlex_showKindMapping() {
        var meta = PlexMetadata()
        meta.ratingKey = "999"
        meta.type = "show"
        meta.title = "Severance"
        let item = MediaItem.from(plex: meta)
        XCTAssertEqual(item.kind, .show)
    }

    func test_fromPlex_extractsTmdbGuid() {
        var meta = PlexMetadata()
        meta.ratingKey = "1"
        meta.type = "movie"
        meta.title = "x"
        meta.Guid = [PlexGuid(id: "tmdb://603"), PlexGuid(id: "imdb://tt0133093")]
        let item = MediaItem.from(plex: meta)
        XCTAssertEqual(item.tmdbId, 603)
        XCTAssertEqual(item.imdbId, "tt0133093")
    }
}
