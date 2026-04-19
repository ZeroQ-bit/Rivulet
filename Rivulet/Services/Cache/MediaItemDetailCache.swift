//
//  MediaItemDetailCache.swift
//  Rivulet
//
//  Caches TMDB-sourced detail fields (cast, runtime, genres) hydrated by the
//  preview prefetch ring. MediaDetailView reads from here when rendering
//  below-fold content for TMDB-only items. Plex-sourced fields are cached
//  separately by PlexDataStore.
//

import Foundation

actor MediaItemDetailCache {
    static let shared = MediaItemDetailCache()

    struct Detail: Sendable, Equatable {
        let cast: [CastMember]
        let runtimeMinutes: Int?
        let genres: [String]
    }

    private var storage: [String: Detail] = [:]

    func detail(for id: String) -> Detail? {
        storage[id]
    }

    func store(id: String, cast: [CastMember], runtimeMinutes: Int?, genres: [String]) {
        storage[id] = Detail(cast: cast, runtimeMinutes: runtimeMinutes, genres: genres)
    }
}
