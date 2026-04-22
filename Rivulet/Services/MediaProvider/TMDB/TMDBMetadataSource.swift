//
//  TMDBMetadataSource.swift
//  Rivulet
//
//  TMDB implementation of MetadataSource. Wraps the existing
//  TMDBDiscoverService and translates DTOs through TMDBMediaMapper.
//

import Foundation

final class TMDBMetadataSource: MetadataSource {
    private let service: TMDBDiscoverService

    init(service: TMDBDiscoverService = .shared) {
        self.service = service
    }

    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem] {
        guard let plexSection = TMDBDiscoverSection(rawValue: section.rawValue) else {
            return []
        }
        let raw = await service.fetchSection(plexSection)
        return raw.map { TMDBMediaMapper.item($0) }
    }

    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail {
        guard ref.providerID == TMDBMediaMapper.providerID,
              let tmdbId = Int(ref.itemID) else {
            throw MediaProviderError.notFound
        }
        // We don't know mediaType from the ref alone; try movie first, fall back to TV.
        if let detail = await service.fetchDetail(tmdbId: tmdbId, type: .movie) {
            return TMDBMediaMapper.detail(detail)
        }
        if let detail = await service.fetchDetail(tmdbId: tmdbId, type: .tv) {
            return TMDBMediaMapper.detail(detail)
        }
        throw MediaProviderError.notFound
    }

    func search(_ query: String) async throws -> [MediaItem] {
        // TMDBDiscoverService doesn't currently expose a /search endpoint.
        // Discover view doesn't search TMDB today; add when needed.
        return []
    }

    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem] {
        // Phase 3's MediaDetailView "Recommended for You" row reimplements this
        // via TMDBDiscoverService.discover (genre-seeded) once detail is in hand.
        // Wave 1 stub: empty.
        return []
    }
}
