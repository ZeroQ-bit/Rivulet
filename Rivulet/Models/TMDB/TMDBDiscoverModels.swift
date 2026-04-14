//
//  TMDBDiscoverModels.swift
//  Rivulet
//
//  Models for TMDB list/discover endpoints used by the Discover page.
//

import Foundation

enum TMDBDiscoverSection: String, CaseIterable, Identifiable, Sendable {
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    var id: String { rawValue }

    var mediaType: TMDBMediaType {
        switch self {
        case .moviePopular, .movieNowPlaying, .movieUpcoming, .movieTopRated: return .movie
        case .tvPopular, .tvAiringToday, .tvOnTheAir, .tvTopRated: return .tv
        }
    }

    var title: String {
        switch self {
        case .moviePopular: return "Popular Movies"
        case .movieNowPlaying: return "Now Playing"
        case .movieUpcoming: return "Upcoming"
        case .movieTopRated: return "Top Rated Movies"
        case .tvPopular: return "Popular TV"
        case .tvAiringToday: return "Airing Today"
        case .tvOnTheAir: return "On The Air"
        case .tvTopRated: return "Top Rated TV"
        }
    }

    /// Path segment forwarded to the proxy after `/tmdb/list/`.
    var proxyPath: String {
        switch self {
        case .moviePopular, .tvPopular: return "popular"
        case .movieNowPlaying: return "now_playing"
        case .movieUpcoming: return "upcoming"
        case .movieTopRated, .tvTopRated: return "top_rated"
        case .tvAiringToday: return "airing_today"
        case .tvOnTheAir: return "on_the_air"
        }
    }
}

struct TMDBListItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let mediaType: TMDBMediaType

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }

    init(id: Int, title: String, overview: String?, posterPath: String?, backdropPath: String?, releaseDate: String?, voteAverage: Double?, mediaType: TMDBMediaType) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name))
            ?? ""
        overview = try? c.decode(String.self, forKey: .overview)
        posterPath = try? c.decode(String.self, forKey: .posterPath)
        backdropPath = try? c.decode(String.self, forKey: .backdropPath)
        releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
            ?? (try? c.decode(String.self, forKey: .firstAirDate))
        voteAverage = try? c.decode(Double.self, forKey: .voteAverage)
        if let raw = try? c.decode(String.self, forKey: .mediaType),
           let parsed = TMDBMediaType(rawValue: raw) {
            mediaType = parsed
        } else {
            // Caller sets mediaType when decoding from a typed list endpoint.
            mediaType = .movie
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try c.encode(mediaType.rawValue, forKey: .mediaType)
    }
}

struct TMDBItemDetail: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let genres: [TMDBGenre]
    let voteAverage: Double?
    let cast: [TMDBCredit]
    let mediaType: TMDBMediaType
}
