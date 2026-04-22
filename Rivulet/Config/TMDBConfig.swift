//
//  TMDBConfig.swift
//  Rivulet
//
//  Centralized configuration for TMDB proxy access.
//

import Foundation

nonisolated enum TMDBConfig {
    /// Proxy base URL (Cloudflare Worker) that forwards TMDB requests with caching.
    static let proxyBaseURL = URL(string: "https://tmdb-proxy.baingurley.workers.dev")!

    /// Cache TTL for TMDB responses when stored locally (in seconds).
    static let localCacheTTL: TimeInterval = 60 * 60 * 24 * 30  // 30 days
}
