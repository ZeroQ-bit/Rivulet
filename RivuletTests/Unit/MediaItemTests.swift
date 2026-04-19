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

extension MediaItemTests {
    func test_fromTmdb_movie_noLibraryMatch() async {
        let tmdb = TMDBListItem(
            id: 603, title: "The Matrix",
            overview: "Neo learns the truth.",
            posterPath: "/p.jpg", backdropPath: "/b.jpg",
            releaseDate: "1999-03-31",
            voteAverage: 8.7, mediaType: .movie
        )
        // LibraryGUIDIndex is a singleton actor populated from libraries; in
        // a test environment with no libraries loaded, lookup returns nil.
        let item = await MediaItem.from(tmdb: tmdb)

        XCTAssertEqual(item.id, "tmdb:603")
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.source, .tmdb)
        XCTAssertEqual(item.title, "The Matrix")
        XCTAssertEqual(item.year, 1999)
        XCTAssertEqual(item.overview, "Neo learns the truth.")
        XCTAssertEqual(item.tmdbId, 603)
        XCTAssertNil(item.plexMatch)             // No library match in test env
        XCTAssertNil(item.plexMetadata)
        XCTAssertEqual(item.tmdbListItem?.id, 603)
        XCTAssertEqual(item.backdropURL?.absoluteString,
                       "https://image.tmdb.org/t/p/original/b.jpg")
        XCTAssertEqual(item.posterURL?.absoluteString,
                       "https://image.tmdb.org/t/p/w500/p.jpg")
    }

    func test_fromTmdb_tv_yearParsing() async {
        let tmdb = TMDBListItem(
            id: 1, title: "Show",
            overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: "2024-01-15",
            voteAverage: nil, mediaType: .tv
        )
        let item = await MediaItem.from(tmdb: tmdb)
        XCTAssertEqual(item.kind, .show)
        XCTAssertEqual(item.year, 2024)
    }

    func test_fromTmdb_emptyReleaseDateYieldsNilYear() async {
        let tmdb = TMDBListItem(
            id: 2, title: "x",
            overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: "",
            voteAverage: nil, mediaType: .movie
        )
        let item = await MediaItem.from(tmdb: tmdb)
        XCTAssertNil(item.year)
    }
}

extension MediaItemTests {
    func test_withCast_replacesCastPreservingOtherFields() async {
        let tmdb = TMDBListItem(
            id: 7, title: "Inception",
            overview: "Dream", posterPath: nil, backdropPath: nil,
            releaseDate: "2010-07-16", voteAverage: 8.4, mediaType: .movie
        )
        let item = await MediaItem.from(tmdb: tmdb)
        let cast = [CastMember(name: "Leo", role: "Cobb", profileImageURL: nil)]
        let updated = item.with(cast: cast)

        XCTAssertEqual(updated.cast, cast)
        XCTAssertEqual(updated.id, item.id)
        XCTAssertEqual(updated.title, item.title)
        XCTAssertEqual(updated.year, item.year)
    }

    func test_withTmdbDetail_fillsRuntimeAndGenres() async {
        let tmdb = TMDBListItem(
            id: 8, title: "x",
            overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: nil, voteAverage: nil, mediaType: .movie
        )
        let item = await MediaItem.from(tmdb: tmdb)
        let updated = item.with(runtimeMinutes: 120, genres: ["Drama", "Sci-Fi"])
        XCTAssertEqual(updated.runtimeMinutes, 120)
        XCTAssertEqual(updated.genres, ["Drama", "Sci-Fi"])
    }
}
