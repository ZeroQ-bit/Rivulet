//
//  MetadataSource.swift
//  Rivulet
//
//  Read-only catalog backend (TMDB today, IMDB/TVDB/Trakt later).
//  Distinct from MediaProvider — sources can't play, don't have user state,
//  don't have libraries. They produce MediaItems that drop into the same
//  carousels and detail views.
//

import Foundation

protocol MetadataSource: Sendable {
    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem]
    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail
    func search(_ query: String) async throws -> [MediaItem]
    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem]
}

enum CuratedSection: String, Sendable, CaseIterable, Identifiable, Hashable, Codable {
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    var id: String { rawValue }

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
}
