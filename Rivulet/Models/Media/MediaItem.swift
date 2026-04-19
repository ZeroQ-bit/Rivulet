//
//  MediaItem.swift
//  Rivulet
//
//  Unified value type that bridges Plex library items, Plex Watchlist entries,
//  and TMDB Discover results into a single shape consumed by MediaDetailView
//  and the carousel preview path. Keeps the original source object around
//  (`plexMetadata`, `tmdbListItem`) for code paths that still need the raw
//  shape, but exposes a flat surface for the unified detail UI.
//

import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String                    // "plex:<ratingKey>" or "tmdb:<id>"
    let kind: Kind
    let source: Source

    let title: String
    let year: Int?
    let overview: String?
    let runtimeMinutes: Int?
    let genres: [String]
    let rating: Double?
    let backdropURL: URL?
    let posterURL: URL?
    let logoURL: URL?

    let tmdbId: Int?
    let imdbId: String?
    let plexMatch: PlexMetadata?

    let plexMetadata: PlexMetadata?
    let tmdbListItem: TMDBListItem?
    let cast: [CastMember]

    enum Kind: String, Sendable { case movie, show, episode, unknown }
    enum Source: String, Sendable { case plex, tmdb }
}

extension MediaItem {
    /// Sync — Plex items always have a plexMatch (themselves).
    static func from(plex: PlexMetadata) -> MediaItem {
        let kind: Kind = {
            switch plex.type {
            case "movie": return .movie
            case "show": return .show
            case "episode": return .episode
            default: return .unknown
            }
        }()

        let runtime: Int? = plex.duration.map { $0 / 60_000 }   // ms → min

        let tmdbId: Int? = plex.Guid?
            .compactMap { $0.id }
            .first(where: { $0.hasPrefix("tmdb://") })
            .flatMap { Int($0.dropFirst("tmdb://".count)) }

        let imdbId: String? = plex.Guid?
            .compactMap { $0.id }
            .first(where: { $0.hasPrefix("imdb://") })
            .map { String($0.dropFirst("imdb://".count)) }

        return MediaItem(
            id: "plex:\(plex.ratingKey ?? UUID().uuidString)",
            kind: kind,
            source: .plex,
            title: plex.title ?? "",
            year: plex.year,
            overview: plex.summary,
            runtimeMinutes: runtime,
            genres: plex.Genre?.compactMap(\.tag) ?? [],
            rating: plex.rating,
            backdropURL: nil,         // Plex backdrop URL needs serverURL/token; resolved at render
            posterURL: nil,           // Same
            logoURL: nil,             // Resolved at render via HeroBackdropResolver
            tmdbId: tmdbId,
            imdbId: imdbId,
            plexMatch: plex,
            plexMetadata: plex,
            tmdbListItem: nil,
            cast: []
        )
    }
}

extension MediaItem {
    private static let tmdbBackdropBase = "https://image.tmdb.org/t/p/original"
    private static let tmdbPosterBase = "https://image.tmdb.org/t/p/w500"

    /// Async — resolves plexMatch via LibraryGUIDIndex so the action button
    /// is correct the moment the card scrolls into view.
    static func from(tmdb: TMDBListItem) async -> MediaItem {
        let kind: Kind = (tmdb.mediaType == .movie) ? .movie : .show

        let year: Int? = {
            guard let raw = tmdb.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
            return Int(raw)
        }()

        let backdropURL = tmdb.backdropPath.flatMap { URL(string: "\(tmdbBackdropBase)\($0)") }
        let posterURL = tmdb.posterPath.flatMap { URL(string: "\(tmdbPosterBase)\($0)") }

        let plexMatch = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdb.id, type: tmdb.mediaType)

        return MediaItem(
            id: "tmdb:\(tmdb.id)",
            kind: kind,
            source: .tmdb,
            title: tmdb.title,
            year: year,
            overview: tmdb.overview,
            runtimeMinutes: nil,         // populated by prefetch ring via TMDB detail fetch
            genres: [],                  // populated by prefetch ring
            rating: tmdb.voteAverage,
            backdropURL: backdropURL,
            posterURL: posterURL,
            logoURL: nil,
            tmdbId: tmdb.id,
            imdbId: nil,
            plexMatch: plexMatch,
            plexMetadata: plexMatch,     // alias when matched
            tmdbListItem: tmdb,
            cast: []
        )
    }
}

extension MediaItem {
    func with(cast: [CastMember]) -> MediaItem {
        MediaItem(
            id: id, kind: kind, source: source,
            title: title, year: year, overview: overview,
            runtimeMinutes: runtimeMinutes, genres: genres, rating: rating,
            backdropURL: backdropURL, posterURL: posterURL, logoURL: logoURL,
            tmdbId: tmdbId, imdbId: imdbId,
            plexMatch: plexMatch, plexMetadata: plexMetadata,
            tmdbListItem: tmdbListItem,
            cast: cast
        )
    }

    func with(runtimeMinutes: Int?, genres: [String]) -> MediaItem {
        MediaItem(
            id: id, kind: kind, source: source,
            title: title, year: year, overview: overview,
            runtimeMinutes: runtimeMinutes, genres: genres, rating: rating,
            backdropURL: backdropURL, posterURL: posterURL, logoURL: logoURL,
            tmdbId: tmdbId, imdbId: imdbId,
            plexMatch: plexMatch, plexMetadata: plexMetadata,
            tmdbListItem: tmdbListItem,
            cast: cast
        )
    }

    /// Builder used by Watchlist projection: TMDB stubs synthesized from
    /// PlexWatchlistItem don't carry a backdropPath/posterPath, but the
    /// PlexWatchlistItem already has an absolute posterURL. This preserves it
    /// so watchlist tiles render their poster art.
    func with(posterOverride: URL?) -> MediaItem {
        guard let posterOverride else { return self }
        return MediaItem(
            id: id, kind: kind, source: source,
            title: title, year: year, overview: overview,
            runtimeMinutes: runtimeMinutes, genres: genres, rating: rating,
            backdropURL: backdropURL, posterURL: posterOverride, logoURL: logoURL,
            tmdbId: tmdbId, imdbId: imdbId,
            plexMatch: plexMatch, plexMetadata: plexMetadata,
            tmdbListItem: tmdbListItem,
            cast: cast
        )
    }
}
