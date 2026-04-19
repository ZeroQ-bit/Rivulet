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
