//
//  MetadataSourceRegistry.swift
//  Rivulet
//
//  Sibling to MediaProviderRegistry for read-only catalog backends
//  (TMDB today; IMDB/TVDB/Trakt later). Phase 2 populates this with
//  TMDBMetadataSource at app launch.
//

import Foundation

@Observable @MainActor
final class MetadataSourceRegistry {
    static let shared = MetadataSourceRegistry()

    private(set) var sources: [String: any MetadataSource] = [:]

    init() {
        register(TMDBMetadataSource(), id: TMDBMediaMapper.providerID)
    }

    func source(for id: String) -> (any MetadataSource)? {
        sources[id]
    }

    func register(_ source: any MetadataSource, id: String) {
        sources[id] = source
    }

    func unregister(id: String) {
        sources.removeValue(forKey: id)
    }
}
