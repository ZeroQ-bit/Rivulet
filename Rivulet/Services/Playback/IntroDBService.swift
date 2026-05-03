//
//  IntroDBService.swift
//  Rivulet
//
//  Fetches crowd-sourced episode intro segments from IntroDB.
//

import Foundation

nonisolated enum IntroDBError: Error, CustomStringConvertible {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var description: String {
        switch self {
        case .invalidURL:
            return "Invalid IntroDB URL"
        case .invalidResponse:
            return "Invalid IntroDB response"
        case .httpStatus(let statusCode):
            return "IntroDB HTTP \(statusCode)"
        }
    }
}

nonisolated struct IntroDBSegment: Decodable, Sendable {
    let startSec: IntroDBTimestamp?
    let endSec: IntroDBTimestamp?
    let startMs: Int?
    let endMs: Int?
    let confidence: Double?
    let submissionCount: Int?

    var markerOffsets: (start: Int, end: Int)? {
        let start = startMs ?? startSec?.milliseconds
        let end = endMs ?? endSec?.milliseconds
        guard let start, let end, start >= 0, end > start else { return nil }
        return (start, end)
    }

    enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec = "end_sec"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
        case submissionCount = "submission_count"
    }
}

nonisolated struct IntroDBSegmentsResponse: Decodable, Sendable {
    let imdbId: String
    let season: Int
    let episode: Int
    let intro: IntroDBSegment?
    let recap: IntroDBSegment?
    let outro: IntroDBSegment?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
        case season
        case episode
        case intro
        case recap
        case outro
    }
}

nonisolated struct IntroDBTimestamp: Decodable, Sendable {
    let seconds: Double

    var milliseconds: Int {
        Int((seconds * 1000).rounded())
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Double.self) {
            seconds = value
            return
        }

        let stringValue = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(stringValue) {
            seconds = value
            return
        }

        let parts = stringValue.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2:
            seconds = parts[0] * 60 + parts[1]
        case 3:
            seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported timestamp format: \(stringValue)"
            )
        }
    }
}

actor IntroDBService {
    static let shared = IntroDBService()

    private enum CacheEntry {
        case found(IntroDBSegmentsResponse)
        case missing
    }

    enum SegmentKind: String {
        case intro
        case recap
        case outro
    }

    private let session: URLSession
    private var introCache: [String: CacheEntry] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func segments(imdbId: String, season: Int, episode: Int) async throws -> IntroDBSegmentsResponse? {
        let normalizedIMDbId = imdbId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = "\(normalizedIMDbId):\(season):\(episode)"

        if let cached = introCache[cacheKey] {
            switch cached {
            case .found(let segments):
                return segments
            case .missing:
                return nil
            }
        }

        guard var components = URLComponents(string: "https://api.introdb.app/segments") else {
            throw IntroDBError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: normalizedIMDbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]

        guard let url = components.url else {
            throw IntroDBError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rivulet/tvOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntroDBError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let decoded = try JSONDecoder().decode(IntroDBSegmentsResponse.self, from: data)
            introCache[cacheKey] = .found(decoded)
            return decoded
        case 404:
            introCache[cacheKey] = .missing
            return nil
        default:
            throw IntroDBError.httpStatus(httpResponse.statusCode)
        }
    }

    func segment(_ kind: SegmentKind, imdbId: String, season: Int, episode: Int) async throws -> IntroDBSegment? {
        guard let segments = try await segments(imdbId: imdbId, season: season, episode: episode) else {
            return nil
        }

        let segment: IntroDBSegment?
        switch kind {
        case .intro:
            segment = segments.intro
        case .recap:
            segment = segments.recap
        case .outro:
            segment = segments.outro
        }

        guard segment?.markerOffsets != nil else { return nil }
        return segment
    }

    func introSegment(imdbId: String, season: Int, episode: Int) async throws -> IntroDBSegment? {
        try await segment(.intro, imdbId: imdbId, season: season, episode: episode)
    }
}
