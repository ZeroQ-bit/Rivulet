//
//  HLSSegmentFetcher.swift
//  Rivulet
//
//  Parses HLS master + variant playlists and downloads fMP4 segments on demand.
//  Used by Rivulet's HLS pipeline to feed AVSampleBufferDisplayLayer.
//

import Foundation
import Sentry

// MARK: - HLS Segment

/// Represents a single media segment in an HLS playlist
struct HLSSegment {
    let url: URL
    let duration: TimeInterval
    let startTime: TimeInterval  // Cumulative start time
    let index: Int
}

// MARK: - HLS Segment Fetcher

/// Fetches and parses HLS playlists and downloads fMP4 segments.
/// Handles Plex auth headers on all requests.
final class HLSSegmentFetcher {

    // MARK: - Properties

    private let masterURL: URL
    private let headers: [String: String]
    private let session: URLSession

    /// Parsed segments from the variant playlist
    private(set) var segments: [HLSSegment] = []

    /// Total duration of all segments
    private(set) var totalDuration: TimeInterval = 0

    /// The initialization segment URL (EXT-X-MAP)
    private(set) var initSegmentURL: URL?

    /// The resolved variant playlist URL
    private(set) var variantURL: URL?

    // MARK: - Init

    init(masterURL: URL, headers: [String: String]) {
        self.masterURL = masterURL
        self.headers = headers

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = headers
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Playlist Loading

    /// Fetch master playlist, resolve best variant, parse segments, and return init segment data.
    /// - Returns: The initialization segment data (ftyp + moov)
    @discardableResult
    func loadPlaylist() async throws -> Data {
        // Step 1: Fetch master playlist
        let masterData = try await fetchData(from: masterURL)
        guard let masterContent = String(data: masterData, encoding: .utf8) else {
            throw HLSFetcherError.invalidPlaylist("Master playlist is not valid UTF-8")
        }

        // Step 2: Resolve variant playlist URL
        let resolvedVariantURL = try resolveVariantURL(from: masterContent, masterURL: masterURL)
        self.variantURL = resolvedVariantURL

        // Step 3: Fetch variant playlist
        let variantData = try await fetchData(from: resolvedVariantURL)
        guard let variantContent = String(data: variantData, encoding: .utf8) else {
            throw HLSFetcherError.invalidPlaylist("Variant playlist is not valid UTF-8")
        }

        // Step 4: Parse variant playlist for segments and init segment
        try parseVariantPlaylist(variantContent, baseURL: resolvedVariantURL)

        // Step 5: Fetch init segment
        guard let initURL = initSegmentURL else {
            let error = HLSFetcherError.missingInitSegment
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_hls_fetcher", key: "component")
                scope.setTag(value: "missing_init_segment", key: "error_type")
                scope.setExtra(value: resolvedVariantURL.absoluteString, key: "variant_url")
                scope.setExtra(value: self.segments.count, key: "segment_count")
            }
            throw error
        }

        // Retry init segment fetch — Plex may still be muxing the init segment even after
        // the playlist is available. This is common when:
        //   - Switching between DV files quickly (server still cleaning up previous transcode)
        //   - Server is under load (500 errors on other endpoints)
        //   - Large MKV files that take time to start muxing
        // Use 15s per attempt (enough for local network muxing) with exponential backoff.
        let maxRetries = 3
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let initData = try await fetchData(from: initURL, timeout: 15)
                return initData
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = Double(3 * (attempt + 1))  // 3s, 6s, 9s
                    playerDebugLog("🎬 [HLSFetcher] ⚠️ Init segment fetch failed (attempt \(attempt + 1)/\(maxRetries + 1)): \(error.localizedDescription). Retrying in \(Int(delay))s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    playerDebugLog("🎬 [HLSFetcher] ❌ Init segment fetch failed after \(maxRetries + 1) attempts: \(error.localizedDescription)")
                }
            }
        }
        throw lastError!
    }

    // MARK: - Segment Fetching

    /// Download a media segment by index
    func fetchSegment(at index: Int) async throws -> Data {
        guard index >= 0 && index < segments.count else {
            throw HLSFetcherError.segmentOutOfRange(index, segments.count)
        }

        let segment = segments[index]
        return try await fetchData(from: segment.url)
    }

    /// Find the segment index that contains the given time
    func segmentIndex(forTime time: TimeInterval) -> Int {
        guard !segments.isEmpty else { return 0 }

        // Binary search for the segment containing `time`
        var low = 0
        var high = segments.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let seg = segments[mid]
            let segEnd = seg.startTime + seg.duration

            if time < seg.startTime {
                high = mid - 1
            } else if time >= segEnd {
                low = mid + 1
            } else {
                return mid
            }
        }

        // Clamp to valid range
        return min(max(low, 0), segments.count - 1)
    }

    // MARK: - Private: HTTP Fetching

    private func fetchData(from url: URL, timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let timeout {
            request.timeoutInterval = timeout
        }
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HLSFetcherError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let error = HLSFetcherError.httpError(httpResponse.statusCode, url)
            // Only report non-transient HTTP errors to Sentry (skip 5xx server errors)
            if !(500...599).contains(httpResponse.statusCode) {
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "dv_hls_fetcher", key: "component")
                    scope.setTag(value: String(httpResponse.statusCode), key: "http_status")
                    scope.setExtra(value: url.host ?? "unknown", key: "host")
                    scope.setExtra(value: url.path, key: "path")
                }
            }
            throw error
        }

        return data
    }

    // MARK: - Private: Playlist Parsing

    /// Resolve the best variant URL from a master playlist.
    /// Picks the highest bandwidth variant (best quality).
    private func resolveVariantURL(from masterContent: String, masterURL: URL) throws -> URL {
        let lines = masterContent.components(separatedBy: .newlines)

        // Check if this is already a media playlist (has segments, no stream variants)
        if masterContent.contains("#EXTINF:") && !masterContent.contains("#EXT-X-STREAM-INF:") {
            // This is a media playlist, not a master playlist
            return masterURL
        }

        // Parse EXT-X-STREAM-INF entries
        struct VariantInfo {
            let bandwidth: Int
            let url: URL
        }

        var variants: [VariantInfo] = []

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Next non-comment, non-empty line is the variant URL
                let bandwidth = parseBandwidth(from: line)

                // Find next URI line
                for j in (i + 1) ..< lines.count {
                    let uriLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if !uriLine.isEmpty && !uriLine.hasPrefix("#") {
                        if let variantURL = resolveURL(uriLine, relativeTo: masterURL) {
                            variants.append(VariantInfo(bandwidth: bandwidth, url: variantURL))
                        }
                        break
                    }
                }
            }
        }

        guard !variants.isEmpty else {
            let error = HLSFetcherError.noVariantsFound
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "dv_hls_fetcher", key: "component")
                scope.setTag(value: "no_variants", key: "error_type")
                scope.setExtra(value: masterURL.host ?? "unknown", key: "host")
                scope.setExtra(value: masterURL.absoluteString, key: "master_url")
            }
            throw error
        }

        // Pick highest bandwidth
        let best = variants.max(by: { $0.bandwidth < $1.bandwidth })!
        return best.url
    }

    private func parseBandwidth(from streamInfLine: String) -> Int {
        // Parse BANDWIDTH=<value> from EXT-X-STREAM-INF
        if let range = streamInfLine.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) {
            let match = streamInfLine[range]
            let valueStr = match.split(separator: "=").last.map(String.init) ?? "0"
            return Int(valueStr) ?? 0
        }
        return 0
    }

    /// Parse a media/variant playlist to extract segments and init segment URL
    private func parseVariantPlaylist(_ content: String, baseURL: URL) throws {
        let lines = content.components(separatedBy: .newlines)
        var parsedSegments: [HLSSegment] = []
        var cumulativeTime: TimeInterval = 0
        var currentDuration: TimeInterval = 0
        var segmentIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXT-X-MAP:") {
                // Init segment: #EXT-X-MAP:URI="init.mp4"
                if let uri = parseAttributeValue(from: trimmed, key: "URI") {
                    initSegmentURL = resolveURL(uri, relativeTo: baseURL)
                }
            } else if trimmed.hasPrefix("#EXTINF:") {
                // Segment duration: #EXTINF:6.006,
                let durationStr = trimmed
                    .replacingOccurrences(of: "#EXTINF:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: ",").first
                    .map(String.init) ?? "0"
                currentDuration = TimeInterval(durationStr) ?? 0
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // Segment URI
                if let segURL = resolveURL(trimmed, relativeTo: baseURL) {
                    parsedSegments.append(HLSSegment(
                        url: segURL,
                        duration: currentDuration,
                        startTime: cumulativeTime,
                        index: segmentIndex
                    ))
                    cumulativeTime += currentDuration
                    segmentIndex += 1
                }
                currentDuration = 0
            }
        }

        self.segments = parsedSegments
        self.totalDuration = cumulativeTime
    }

    /// Parse a quoted attribute value from an HLS tag (e.g., URI="value")
    private func parseAttributeValue(from line: String, key: String) -> String? {
        // Match KEY="value" or KEY=value
        let pattern = "\(key)=\"([^\"]+)\""
        if let range = line.range(of: pattern, options: .regularExpression) {
            let match = line[range]
            // Extract value between quotes
            if let openQuote = match.firstIndex(of: "\""),
               let closeQuote = match[match.index(after: openQuote)...].firstIndex(of: "\"") {
                return String(match[match.index(after: openQuote) ..< closeQuote])
            }
        }

        // Try unquoted
        let unquotedPattern = "\(key)=([^,\\s]+)"
        if let range = line.range(of: unquotedPattern, options: .regularExpression) {
            let match = line[range]
            return String(match.split(separator: "=").last ?? "")
        }

        return nil
    }

    /// Resolve a URI (possibly relative) against a base URL
    private func resolveURL(_ uri: String, relativeTo baseURL: URL) -> URL? {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return URL(string: uri)
        }
        return URL(string: uri, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - Errors

enum HLSFetcherError: Error, CustomStringConvertible {
    case invalidPlaylist(String)
    case noVariantsFound
    case missingInitSegment
    case segmentOutOfRange(Int, Int)
    case httpError(Int, URL)
    case invalidResponse

    var description: String {
        switch self {
        case .invalidPlaylist(let msg): return "Invalid HLS playlist: \(msg)"
        case .noVariantsFound: return "No variant streams found in master playlist"
        case .missingInitSegment: return "No EXT-X-MAP (init segment) found in variant playlist"
        case .segmentOutOfRange(let idx, let count): return "Segment index \(idx) out of range (0..<\(count))"
        case .httpError(let code, let url): return "HTTP \(code) fetching \(url.absoluteString)"
        case .invalidResponse: return "Invalid HTTP response"
        }
    }
}
