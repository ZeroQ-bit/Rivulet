//
//  TMDBMediaMapper.swift
//  Rivulet
//
//  TMDB DTO -> agnostic-type translations. Mirror of PlexMediaMapper for
//  the TMDB MetadataSource side.
//

import Foundation

enum TMDBMediaMapper {
    static let providerID = "tmdb"

    private static let backdropBase = "https://image.tmdb.org/t/p/original"
    private static let posterBase = "https://image.tmdb.org/t/p/w500"

    static func item(_ tmdb: TMDBListItem) -> MediaItem {
        let kind: MediaKind = (tmdb.mediaType == .movie) ? .movie : .show
        let year: Int? = {
            guard let raw = tmdb.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
            return Int(raw)
        }()
        let artwork = MediaArtwork(
            poster: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            backdrop: tmdb.backdropPath.flatMap { URL(string: "\(backdropBase)\($0)") },
            thumbnail: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            logo: nil
        )
        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: "\(tmdb.id)"),
            kind: kind,
            title: tmdb.title,
            sortTitle: nil,
            overview: tmdb.overview,
            year: year,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: artwork
        )
    }

    static func detail(_ tmdb: TMDBItemDetail) -> MediaItemDetail {
        let cast = tmdb.cast.map { credit in
            MediaPerson(
                id: "\(credit.id ?? 0)",
                name: credit.name ?? "",
                role: credit.character,
                imageURL: nil
            )
        }
        // Re-stub a TMDBListItem so we can reuse `item(_:)` for the embedded MediaItem.
        let stub = TMDBListItem(
            id: tmdb.id,
            title: tmdb.title,
            overview: tmdb.overview,
            posterPath: tmdb.posterPath,
            backdropPath: tmdb.backdropPath,
            releaseDate: tmdb.releaseDate,
            voteAverage: tmdb.voteAverage,
            mediaType: tmdb.mediaType
        )
        let runtime: TimeInterval? = tmdb.runtime.map { TimeInterval($0 * 60) }
        var embedded = item(stub)
        embedded = MediaItem(
            ref: embedded.ref,
            kind: embedded.kind,
            title: embedded.title,
            sortTitle: embedded.sortTitle,
            overview: embedded.overview,
            year: embedded.year,
            runtime: runtime,
            parentRef: embedded.parentRef,
            grandparentRef: embedded.grandparentRef,
            userState: embedded.userState,
            artwork: embedded.artwork
        )
        return MediaItemDetail(
            item: embedded,
            tagline: nil,
            genres: tmdb.genres.compactMap(\.name),
            studios: [],
            cast: cast,
            directors: [],
            writers: [],
            chapters: [],
            mediaSources: [],
            trailerURL: nil,
            contentRating: nil,
            rating: tmdb.voteAverage
        )
    }
}
