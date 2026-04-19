//
//  DiscoverRecommendationServiceTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DiscoverRecommendationServiceTests: XCTestCase {

    func testFiltersOutItemsAlreadyInLibrary() async {
        var owned = PlexMetadata(ratingKey: "1", type: "movie", title: "Owned")
        owned.Guid = [PlexGuid(id: "tmdb://100")]

        let index = LibraryGUIDIndex()
        await index.replace(with: [owned])

        let stub = StubDiscoverFetcher()
        stub.movies = [
            TMDBListItem(id: 100, title: "Owned", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .movie),
            TMDBListItem(id: 200, title: "New",   overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .movie)
        ]

        let service = DiscoverRecommendationService(fetcher: stub, libraryIndex: index)
        let items = await service.forYouRow(profile: testProfile())

        XCTAssertEqual(items.map(\.id), [200])
    }

    func testReturnsEmptyForColdStartProfile() async {
        let stub = StubDiscoverFetcher()
        let service = DiscoverRecommendationService(fetcher: stub, libraryIndex: LibraryGUIDIndex())
        let items = await service.forYouRow(profile: FeatureProfile())
        XCTAssertTrue(items.isEmpty)
    }

    func testIncludesTVResultsAlongsideMovies() async {
        let stub = StubDiscoverFetcher()
        stub.movies = [
            TMDBListItem(id: 1, title: "M1", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .movie)
        ]
        stub.shows = [
            TMDBListItem(id: 2, title: "S1", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .tv)
        ]
        let service = DiscoverRecommendationService(fetcher: stub, libraryIndex: LibraryGUIDIndex())
        let items = await service.forYouRow(profile: testProfile())
        XCTAssertEqual(Set(items.map(\.id)), [1, 2])
    }

    func testReturnsEmptyWhenTopGenresHaveNoKnownTMDBIds() async {
        var profile = FeatureProfile()
        profile.add(features: TMDBItemFeatures(
            keywords: [],
            cast: [], directors: [],
            genres: ["unknown-genre-a", "unknown-genre-b", "unknown-genre-c"],
            voteAverage: nil, voteCount: nil
        ), weight: 1.0)

        let stub = StubDiscoverFetcher()
        stub.movies = [
            TMDBListItem(id: 1, title: "Should not appear", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .movie)
        ]

        let service = DiscoverRecommendationService(fetcher: stub, libraryIndex: LibraryGUIDIndex())
        let items = await service.forYouRow(profile: profile)
        XCTAssertTrue(items.isEmpty)
    }

    func testCapsAtMaxItems() async {
        let stub = StubDiscoverFetcher()
        stub.movies = (0..<30).map { i in
            TMDBListItem(id: i, title: "M\(i)", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil, voteAverage: nil, mediaType: .movie)
        }
        let service = DiscoverRecommendationService(fetcher: stub, libraryIndex: LibraryGUIDIndex())
        let items = await service.forYouRow(profile: testProfile())
        XCTAssertLessThanOrEqual(items.count, 20)
    }

    private func testProfile() -> FeatureProfile {
        var p = FeatureProfile()
        p.add(features: TMDBItemFeatures(
            keywords: ["k1", "k2", "k3"],
            cast: [], directors: [],
            genres: ["action", "thriller", "science fiction"],
            voteAverage: nil, voteCount: nil
        ), weight: 1.0)
        return p
    }
}

final class StubDiscoverFetcher: DiscoverFetching, @unchecked Sendable {
    var movies: [TMDBListItem] = []
    var shows: [TMDBListItem] = []
    func discover(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) async -> [TMDBListItem] {
        type == .movie ? movies : shows
    }
}

extension DiscoverRecommendationServiceTests {
    func test_recommendationsForItem_tmdbItem_usesGenresFromCache() async {
        let stub = StubDiscoverFetcher()
        stub.movies = [
            TMDBListItem(id: 200, title: "Rec1", overview: nil,
                         posterPath: nil, backdropPath: nil,
                         releaseDate: "2024", voteAverage: nil, mediaType: .movie)
        ]
        let service = DiscoverRecommendationService(
            fetcher: stub,
            libraryIndex: LibraryGUIDIndex.shared
        )

        let tmdb = TMDBListItem(
            id: 1, title: "Inception",
            overview: nil, posterPath: nil, backdropPath: nil,
            releaseDate: "2010", voteAverage: nil, mediaType: .movie
        )
        var seed = await MediaItem.from(tmdb: tmdb)
        seed = seed.with(runtimeMinutes: nil, genres: ["Sci-Fi", "Action"])

        let recs = await service.recommendationsForItem(seed, limit: 5)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.id, "tmdb:200")
        XCTAssertEqual(recs.first?.source, .tmdb)
    }

    func test_recommendationsForItem_emptyGenresReturnsEmpty() async {
        let stub = StubDiscoverFetcher()
        let service = DiscoverRecommendationService(
            fetcher: stub,
            libraryIndex: LibraryGUIDIndex.shared
        )
        let tmdb = TMDBListItem(
            id: 1, title: "x", overview: nil,
            posterPath: nil, backdropPath: nil,
            releaseDate: nil, voteAverage: nil, mediaType: .movie
        )
        let seed = await MediaItem.from(tmdb: tmdb)   // genres == []

        let recs = await service.recommendationsForItem(seed, limit: 5)
        XCTAssertEqual(recs, [])
    }
}
