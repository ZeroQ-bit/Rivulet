//
//  DiscoverRecommendationService.swift
//  Rivulet
//
//  Personalized "For You" row on the Discover page. Reuses WatchProfileBuilder
//  to produce a FeatureProfile from watch history, then queries TMDB /discover
//  using the top genres/keywords. Filters out items already in the library.
//

import Foundation

protocol DiscoverFetching: Sendable {
    func discover(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) async -> [TMDBListItem]
}

extension TMDBDiscoverService: DiscoverFetching {}

actor DiscoverRecommendationService {
    static let shared = DiscoverRecommendationService(
        fetcher: TMDBDiscoverService.shared,
        libraryIndex: LibraryGUIDIndex.shared
    )

    private let fetcher: DiscoverFetching
    private let libraryIndex: LibraryGUIDIndex
    private let coldStartGenreThreshold = 3
    private let maxItems = 20

    // TMDB genre name → ID for both movies and TV.
    private static let genreNameToId: [String: Int] = [
        "action": 28, "adventure": 12, "animation": 16, "comedy": 35, "crime": 80,
        "documentary": 99, "drama": 18, "family": 10751, "fantasy": 14, "history": 36,
        "horror": 27, "music": 10402, "mystery": 9648, "romance": 10749,
        "science fiction": 878, "tv movie": 10770, "thriller": 53, "war": 10752,
        "western": 37, "kids": 10762, "news": 10763, "reality": 10764,
        "soap": 10766, "talk": 10767, "war & politics": 10768
    ]

    init(fetcher: DiscoverFetching, libraryIndex: LibraryGUIDIndex) {
        self.fetcher = fetcher
        self.libraryIndex = libraryIndex
    }

    /// Returns 0–20 TMDB items not already in the library, ordered by raw fetch order.
    func forYouRow(profile: FeatureProfile) async -> [TMDBListItem] {
        let topGenres = profile.topGenres(3)
        guard topGenres.count >= coldStartGenreThreshold else { return [] }

        let genreIds = topGenres.compactMap { Self.genreNameToId[$0] }
        // Keywords in our profile are TMDB keyword names, not IDs.
        // Without a name→ID map we omit keyword filters for v1.
        let movies = await fetcher.discover(type: .movie, withGenres: genreIds, withKeywords: [])
        let tvShows = await fetcher.discover(type: .tv, withGenres: genreIds, withKeywords: [])

        let combined = movies + tvShows
        var filtered: [TMDBListItem] = []
        for item in combined {
            if await libraryIndex.lookup(tmdbId: item.id, type: item.mediaType) == nil {
                filtered.append(item)
            }
            if filtered.count >= maxItems { break }
        }
        return filtered
    }
}
