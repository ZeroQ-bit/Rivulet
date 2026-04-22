//
//  StreamURLCache.swift
//  Rivulet
//
//  Caches pre-computed stream URLs to reduce startup latency.
//  MediaDetailView pre-warms URLs when loading fullMetadata,
//  and UniversalPlayerViewModel checks cache before building URLs.
//

import Foundation

/// Cached stream URL data
struct CachedStreamURL {
    let url: URL
    let headers: [String: String]
    let timestamp: Date

    /// Cache entries expire after 5 minutes (session IDs may become stale)
    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 300
    }
}

/// Thread-safe cache for pre-computed stream URLs
/// Reduces startup latency by allowing MediaDetailView to pre-build URLs
/// while the user is still viewing the detail page.
@MainActor
final class StreamURLCache {
    static let shared = StreamURLCache()

    /// Cache keyed by ratingKey
    private var cache: [String: CachedStreamURL] = [:]

    private init() {}

    /// Store a pre-computed stream URL for a given ratingKey
    func set(ratingKey: String, url: URL, headers: [String: String]) {
        cache[ratingKey] = CachedStreamURL(url: url, headers: headers, timestamp: Date())
    }

    /// Retrieve a cached stream URL if available and not expired
    func get(ratingKey: String) -> CachedStreamURL? {
        guard let cached = cache[ratingKey] else { return nil }
        if cached.isExpired {
            cache.removeValue(forKey: ratingKey)
            return nil
        }
        return cached
    }

    /// Remove a cached URL (e.g., after playback starts)
    func remove(ratingKey: String) {
        cache.removeValue(forKey: ratingKey)
    }

    /// Clear all cached URLs
    func clear() {
        cache.removeAll()
    }
}
