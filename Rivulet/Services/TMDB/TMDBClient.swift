//
//  TMDBClient.swift
//  Rivulet
//
//  Lightweight TMDB client that talks to the Cloudflare Worker proxy.
//  Includes simple on-disk caching to reduce requests and work offline.
//

import Foundation

enum TMDBMediaType: String {
    case movie
    case tv
}

struct TMDBKeyword: Codable {
    let id: Int?
    let name: String?
}

struct TMDBGenre: Codable {
    let id: Int?
    let name: String?
}

struct TMDBDetails: Codable {
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case genres
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

struct TMDBCredit: Codable {
    let id: Int?
    let name: String?
    let job: String?
    let department: String?
    let character: String?
}

private struct TMDBKeywordsResponse: Codable {
    let keywords: [TMDBKeyword]?
    let results: [TMDBKeyword]?

    var allKeywords: [TMDBKeyword] {
        if let keywords { return keywords }
        if let results { return results }
        return []
    }
}

private struct TMDBCreditsResponse: Codable {
    let cast: [TMDBCredit]?
    let crew: [TMDBCredit]?
}

struct TMDBLogo: Codable {
    let filePath: String?
    let iso6391: String?
    let aspectRatio: Double?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
        case aspectRatio = "aspect_ratio"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

private struct TMDBImagesResponse: Codable {
    let logos: [TMDBLogo]?
}

private struct TMDBFindResponse: Codable {
    let tvResults: [TMDBFindResult]?
    let movieResults: [TMDBFindResult]?

    enum CodingKeys: String, CodingKey {
        case tvResults = "tv_results"
        case movieResults = "movie_results"
    }
}

private struct TMDBFindResult: Codable {
    let id: Int?
}

struct TMDBItemFeatures: Codable {
    var keywords: [String]
    var cast: [String]
    var directors: [String]
    var genres: [String]
    var voteAverage: Double?
    var voteCount: Int?

    mutating func merge(from other: TMDBItemFeatures) {
        keywords.append(contentsOf: other.keywords)
        cast.append(contentsOf: other.cast)
        directors.append(contentsOf: other.directors)
        genres.append(contentsOf: other.genres)
    }

    func normalized() -> TMDBItemFeatures {
        TMDBItemFeatures(
            keywords: Array(Set(keywords)),
            cast: Array(Set(cast)),
            directors: Array(Set(directors)),
            genres: Array(Set(genres)),
            voteAverage: voteAverage,
            voteCount: voteCount
        )
    }
}

private struct CachedFeatures: Codable {
    let generatedAt: Date
    let features: TMDBItemFeatures
}

private struct CachedLogoURL: Codable {
    let generatedAt: Date
    let logoURLString: String?  // nil means "no logo found"
}

final class TMDBClient: @unchecked Sendable {
    static let shared = TMDBClient()

    private let session: URLSession
    private let cacheDirectory: URL
    private let cacheTTL = TMDBConfig.localCacheTTL

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = caches.appendingPathComponent("TMDBCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func fetchFeatures(tmdbId: Int, type: TMDBMediaType) async -> TMDBItemFeatures? {
        if let cached = loadCachedFeatures(tmdbId: tmdbId, type: type) {
            return cached
        }

        do {
            async let keywordsResponse: TMDBKeywordsResponse = request(endpoint: "tmdb/keywords/\(tmdbId)", type: type)
            async let creditsResponse: TMDBCreditsResponse = request(endpoint: "tmdb/credits/\(tmdbId)", type: type)
            async let detailsResponse: TMDBDetails = request(endpoint: "tmdb/details/\(tmdbId)", type: type)

            let (keywords, credits, details) = try await (keywordsResponse, creditsResponse, detailsResponse)

            let features = TMDBItemFeatures(
                keywords: keywords.allKeywords.compactMap { $0.name?.lowercased() },
                cast: (credits.cast ?? []).prefix(8).compactMap { $0.name?.lowercased() },
                directors: (credits.crew ?? []).filter { $0.job?.lowercased() == "director" }.prefix(4).compactMap { $0.name?.lowercased() },
                genres: (details.genres ?? []).compactMap { $0.name?.lowercased() },
                voteAverage: details.voteAverage,
                voteCount: details.voteCount
            ).normalized()

            saveCachedFeatures(features, tmdbId: tmdbId, type: type)
            return features
        } catch {
            return nil
        }
    }

    /// Fetches the best English logo URL from TMDB images.
    /// Returns a URL to the logo image at w500 resolution, or nil if none found.
    func fetchLogoURL(tmdbId: Int, type: TMDBMediaType) async -> URL? {
        // Double-optional: nil = not cached, .some(nil) = cached "no logo", .some(url) = cached logo
        if let cached = loadCachedLogoURL(tmdbId: tmdbId, type: type) {
            return cached
        }

        do {
            let images: TMDBImagesResponse = try await request(endpoint: "tmdb/images/\(tmdbId)", type: type)

            // Prefer English logos, then null-language (often text-less), sorted by vote average
            let logos = images.logos ?? []
            let best = logos
                .filter { $0.filePath != nil }
                .sorted { a, b in
                    let aLang = a.iso6391 ?? ""
                    let bLang = b.iso6391 ?? ""
                    // English first, then null/empty, then others
                    let aScore = aLang == "en" ? 0 : (aLang.isEmpty ? 1 : 2)
                    let bScore = bLang == "en" ? 0 : (bLang.isEmpty ? 1 : 2)
                    if aScore != bScore { return aScore < bScore }
                    return (a.voteAverage ?? 0) > (b.voteAverage ?? 0)
                }
                .first

            let urlString: String?
            if let filePath = best?.filePath {
                urlString = "https://image.tmdb.org/t/p/w500\(filePath)"
            } else {
                urlString = nil
            }

            saveCachedLogoURL(urlString, tmdbId: tmdbId, type: type)
            if let urlString { return URL(string: urlString) }
            return nil
        } catch {
            return nil
        }
    }

    /// Converts a TVDB ID to a TMDB ID using the /find endpoint.
    func findTmdbId(tvdbId: Int, type: TMDBMediaType) async -> Int? {
        do {
            let response: TMDBFindResponse = try await request(
                endpoint: "tmdb/find/\(tvdbId)",
                queryItems: [
                    URLQueryItem(name: "type", value: type.rawValue),
                    URLQueryItem(name: "source", value: "tvdb_id")
                ]
            )
            let results = type == .tv ? response.tvResults : response.movieResults
            return results?.first?.id
        } catch {
            return nil
        }
    }

    // MARK: - Networking

    private func request<T: Decodable>(endpoint: String, type: TMDBMediaType) async throws -> T {
        try await request(endpoint: endpoint, queryItems: [
            URLQueryItem(name: "type", value: type.rawValue)
        ])
    }

    private func request<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]) async throws -> T {
        guard let url = URL(string: endpoint, relativeTo: TMDBConfig.proxyBaseURL) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems
        guard let finalURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Local Cache

    private func cacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        cacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId).json")
    }

    private func loadCachedFeatures(tmdbId: Int, type: TMDBMediaType) -> TMDBItemFeatures? {
        let url = cacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedFeatures.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(cached.generatedAt)
        guard age < cacheTTL else { return nil }
        return cached.features
    }

    private func saveCachedFeatures(_ features: TMDBItemFeatures, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedFeatures(generatedAt: Date(), features: features)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = cacheURL(tmdbId: tmdbId, type: type)
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Logo Cache

    private func logoCacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        cacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId)_logo.json")
    }

    private func loadCachedLogoURL(tmdbId: Int, type: TMDBMediaType) -> URL?? {
        let url = logoCacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }  // No cache file → nil (not cached)
        guard let cached = try? JSONDecoder().decode(CachedLogoURL.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(cached.generatedAt)
        guard age < cacheTTL else { return nil }
        // Return .some(URL?) — .some(nil) means "cached negative result (no logo)"
        if let urlString = cached.logoURLString {
            return .some(URL(string: urlString))
        }
        return .some(nil)
    }

    private func saveCachedLogoURL(_ urlString: String?, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedLogoURL(generatedAt: Date(), logoURLString: urlString)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = logoCacheURL(tmdbId: tmdbId, type: type)
        try? data.write(to: url, options: [.atomic])
    }
}
