//
//  PlexTrailerPlaybackService.swift
//  Rivulet
//
//  Resolves Plex Discover trailer references into direct playable metadata.
//

import Foundation

enum PlexTrailerPlaybackError: LocalizedError {
    case invalidReference
    case missingAccountToken
    case invalidResponse
    case unexpectedStatusCode(Int)
    case playableKeyNotFound
    case playQueueItemNotFound
    case directPlayUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            return "The trailer reference is invalid."
        case .missingAccountToken:
            return "A Plex account token is required for this trailer."
        case .invalidResponse:
            return "The trailer response was invalid."
        case .unexpectedStatusCode(let code):
            return "The trailer request returned HTTP \(code)."
        case .playableKeyNotFound:
            return "The trailer playable key could not be found."
        case .playQueueItemNotFound:
            return "The trailer play queue did not contain a playable item."
        case .directPlayUnavailable:
            return "No direct-play trailer stream is available."
        }
    }
}

struct PlexResolvedTrailer: Sendable {
    let title: String
    let url: URL
    let container: String
    let duration: Int?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let file: String?
    let size: Int?
}

actor PlexTrailerPlaybackService {
    static let shared = PlexTrailerPlaybackService()

    private let providerBaseURL = URL(string: "https://vod.provider.plex.tv")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func resolveDiscoverTrailer(reference: String, accountToken: String?) async throws -> PlexMetadata {
        guard let trimmed = cleaned(reference) else {
            throw PlexTrailerPlaybackError.invalidReference
        }

        let resolved: PlexResolvedTrailer
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            resolved = try await resolvePlayback(for: url, accountToken: accountToken)
        } else if trimmed.hasPrefix("provider://") {
            guard let token = cleaned(accountToken) else {
                throw PlexTrailerPlaybackError.missingAccountToken
            }
            resolved = try await resolvePlayback(playableKey: trimmed, accountToken: token)
        } else {
            throw PlexTrailerPlaybackError.invalidReference
        }

        return metadata(for: resolved)
    }

    func resolveDiscoverTrailer(
        title: String,
        year: Int?,
        type: String?,
        accountToken: String?
    ) async throws -> PlexMetadata {
        guard let title = cleaned(title) else {
            throw PlexTrailerPlaybackError.invalidReference
        }

        let pageURLs = try await discoverPageURLs(title: title, year: year, type: type)
        guard !pageURLs.isEmpty else {
            throw PlexTrailerPlaybackError.playableKeyNotFound
        }

        var fallbackTrailerURLString: String?

        for pageURL in pageURLs.prefix(12) {
            guard let html = try? await fetchHTML(pageURL),
                  let trailerURLString = discoverTrailerURLString(in: html) else {
                continue
            }

            if matchesDiscoverYear(html: html, year: year) {
                return try await resolveDiscoverTrailer(
                    reference: trailerURLString,
                    accountToken: accountToken
                )
            }

            fallbackTrailerURLString = fallbackTrailerURLString ?? trailerURLString
        }

        if let fallbackTrailerURLString {
            return try await resolveDiscoverTrailer(
                reference: fallbackTrailerURLString,
                accountToken: accountToken
            )
        }

        throw PlexTrailerPlaybackError.playableKeyNotFound
    }

    private func resolvePlayback(for trailerURL: URL, accountToken: String?) async throws -> PlexResolvedTrailer {
        if let direct = await directMediaTrailer(for: trailerURL) {
            return direct
        }

        guard requiresPlexResolution(for: trailerURL) else {
            throw PlexTrailerPlaybackError.directPlayUnavailable
        }

        guard let token = cleaned(accountToken) else {
            throw PlexTrailerPlaybackError.missingAccountToken
        }

        let playableKey = try await resolvePlayableKey(from: trailerURL)
        return try await resolvePlayback(playableKey: playableKey, accountToken: token)
    }

    private func resolvePlayback(playableKey: String, accountToken: String) async throws -> PlexResolvedTrailer {
        let playQueue = try await fetchPlayQueue(for: playableKey, accountToken: accountToken)
        guard let item = selectedPlayQueueItem(from: playQueue) else {
            throw PlexTrailerPlaybackError.playQueueItemNotFound
        }

        guard let resolved = resolvedTrailer(from: item, accountToken: accountToken) else {
            throw PlexTrailerPlaybackError.directPlayUnavailable
        }

        return resolved
    }

    private func requiresPlexResolution(for url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let uri = components.queryItems?.first(where: { $0.name == "uri" })?.value,
           uri.hasPrefix("provider://") {
            return true
        }

        return host == "watch.plex.tv"
            || host == "app.plex.tv"
            || path.contains("/watch/video")
    }

    private func discoverPageURLs(title: String, year: Int?, type: String?) async throws -> [URL] {
        let normalizedType = type?.lowercased()
        let pathKind: String
        switch normalizedType {
        case "show", "season", "episode", "series":
            pathKind = "show"
        default:
            pathKind = "movie"
        }

        let slug = discoverSlug(from: title)
        var pathCandidates: [String] = []
        if !slug.isEmpty {
            if let year {
                pathCandidates.append("/en-GB/\(pathKind)/\(slug)-\(year)")
            }
            pathCandidates.append("/en-GB/\(pathKind)/\(slug)")
        }

        var searchComponents = URLComponents(string: "https://watch.plex.tv/en-GB/search")
        searchComponents?.queryItems = [URLQueryItem(name: "query", value: title)]
        if let searchURL = searchComponents?.url,
           let searchHTML = try? await fetchHTML(searchURL) {
            pathCandidates.append(contentsOf: discoverSearchResultPaths(in: searchHTML, preferredKind: pathKind))
        }

        let orderedPaths = orderDiscoverPaths(pathCandidates, year: year)
        var seen = Set<String>()
        return orderedPaths.compactMap { path in
            let cleanedPath = path
                .replacingOccurrences(of: "\\u002F", with: "/")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard cleanedPath.hasPrefix("/"),
                  seen.insert(cleanedPath).inserted else {
                return nil
            }
            return URL(string: "https://watch.plex.tv\(cleanedPath)")
        }
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 AppleTV Rivulet", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexTrailerPlaybackError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlexTrailerPlaybackError.unexpectedStatusCode(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PlexTrailerPlaybackError.invalidResponse
        }
        return html
    }

    private func discoverSearchResultPaths(in html: String, preferredKind: String) -> [String] {
        let normalizedHTML = html
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
        let kindPattern = NSRegularExpression.escapedPattern(for: preferredKind)
        let patterns = [
            "/en-GB/\(kindPattern)/[^\\\"?#<\\\\]+",
            "/\(kindPattern)/[^\\\"?#<\\\\]+"
        ]

        var paths: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalizedHTML.startIndex..<normalizedHTML.endIndex, in: normalizedHTML)
            for match in regex.matches(in: normalizedHTML, options: [], range: range) {
                guard let valueRange = Range(match.range(at: 0), in: normalizedHTML) else { continue }
                var path = String(normalizedHTML[valueRange])
                    .replacingOccurrences(of: "&amp;", with: "&")
                if path.hasPrefix("/\(preferredKind)/") {
                    path = "/en-GB\(path)"
                }
                guard seen.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    private func orderDiscoverPaths(_ paths: [String], year: Int?) -> [String] {
        guard let year else { return paths }
        let yearString = String(year)
        return paths.enumerated()
            .sorted { lhs, rhs in
                let lhsHasYear = lhs.element.contains(yearString)
                let rhsHasYear = rhs.element.contains(yearString)
                if lhsHasYear != rhsHasYear {
                    return lhsHasYear
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func matchesDiscoverYear(html: String, year: Int?) -> Bool {
        guard let year else { return true }
        let normalizedHTML = html.replacingOccurrences(of: "\\/", with: "/")
        let yearString = String(year)
        let patterns = [
            #"video:release_date"\s+content="([0-9]{4})"#,
            #""releaseDate":"([0-9]{4})"#,
            #""datePublished":"([0-9]{4})"#,
            #""releaseDate":"([0-9]{4})-[0-9]{2}-[0-9]{2}""#
        ]

        return patterns.contains { pattern in
            firstRegexMatch(in: normalizedHTML, pattern: pattern) == yearString
        }
    }

    private func discoverTrailerURLString(in html: String) -> String? {
        let normalizedHTML = html
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
        let watchTrailerPatterns = [
            #"<a[^>]*data-id="watchTrailer"[^>]*href="([^"]+)""#,
            #"<a[^>]*href="([^"]+)"[^>]*data-id="watchTrailer""#,
            #"<a[^>]*aria-label="Watch Trailer"[^>]*href="([^"]+)""#,
            #"<a[^>]*href="([^"]+)"[^>]*aria-label="Watch Trailer""#
        ]

        for pattern in watchTrailerPatterns {
            if let href = firstRegexMatch(in: normalizedHTML, pattern: pattern),
               let absoluteURLString = absolutePlexWatchURLString(from: href) {
                return absoluteURLString
            }
        }

        let discoverVideosPattern = #""title":"Watch [^"]+ Videos".*?"link":\{"url":"(/watch/video\?uri=provider%3A%2F%2Ftv\.plex\.provider\.discover%2Flibrary%2Fmetadata%2F[^"]+%2Fextras%2F[^"]+)""#
        if let href = firstRegexMatch(
            in: normalizedHTML,
            pattern: discoverVideosPattern,
            options: [.dotMatchesLineSeparators]
        ),
        let absoluteURLString = absolutePlexWatchURLString(from: href) {
            return absoluteURLString
        }

        let directDiscoverVideoPatterns = [
            #"(/(?:en-GB/)?watch/video\?uri=provider%3A%2F%2Ftv\.plex\.provider\.discover%2Flibrary%2Fmetadata%2F[^"\\<]+%2Fextras%2F[^"\\<]+)"#,
            #"\\\"(/(?:en-GB/)?watch/video\?uri=provider%3A%2F%2Ftv\.plex\.provider\.discover%2Flibrary%2Fmetadata%2F[^"\\<]+%2Fextras%2F[^"\\<]+)"#
        ]
        for pattern in directDiscoverVideoPatterns {
            if let href = firstRegexMatch(in: normalizedHTML, pattern: pattern),
               let absoluteURLString = absolutePlexWatchURLString(from: href) {
                return absoluteURLString
            }
        }

        return nil
    }

    private func absolutePlexWatchURLString(from rawValue: String) -> String? {
        let value = rawValue
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("provider://") {
            return value
        }
        if value.hasPrefix("/en-GB/watch/video") {
            return "https://watch.plex.tv\(value)"
        }
        if value.hasPrefix("/watch/video") {
            return "https://watch.plex.tv/en-GB\(value)"
        }
        return nil
    }

    private func discoverSlug(from title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func directMediaTrailer(for url: URL) async -> PlexResolvedTrailer? {
        guard !requiresPlexResolution(for: url) else { return nil }

        let lower = url.absoluteString.lowercased()
        let path = url.path.lowercased()
        let isHLS = lower.contains(".m3u8") || lower.contains("format=m3u8")
        let isProgressive = path.hasSuffix(".mp4") || path.hasSuffix(".m4v") || path.hasSuffix(".mov")
        let isKnownMediaHost = (url.host ?? "").lowercased().contains("cloudfront.net")
            || (url.host ?? "").lowercased().contains("provider.plex.tv")
            || (url.host ?? "").lowercased().contains("plex.direct")

        if isHLS || isProgressive || isKnownMediaHost {
            return makeDirectTrailer(url: url, isHLS: isHLS)
        }

        return await probeDirectMediaTrailer(for: url)
    }

    private func probeDirectMediaTrailer(for url: URL) async -> PlexResolvedTrailer? {
        if let trailer = await probeDirectMediaTrailer(for: url, method: "HEAD") {
            return trailer
        }
        return await probeDirectMediaTrailer(for: url, method: "GET", rangeHeader: "bytes=0-1")
    }

    private func probeDirectMediaTrailer(for url: URL, method: String, rangeHeader: String? = nil) async -> PlexResolvedTrailer? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("video/*,application/vnd.apple.mpegurl,application/x-mpegurl,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(http.statusCode) || http.statusCode == 206 else { return nil }

            let finalURL = http.url ?? url
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            let isHLS = contentType?.contains("mpegurl") == true || finalURL.absoluteString.lowercased().contains(".m3u8")
            let isMedia = isHLS
                || contentType?.contains("video/") == true
                || contentType?.contains("application/octet-stream") == true
                || finalURL.absoluteString.lowercased().contains(".mp4")
                || finalURL.absoluteString.lowercased().contains(".m4v")
                || finalURL.absoluteString.lowercased().contains(".mov")

            return isMedia ? makeDirectTrailer(url: finalURL, isHLS: isHLS) : nil
        } catch {
            return nil
        }
    }

    private func makeDirectTrailer(url: URL, isHLS: Bool) -> PlexResolvedTrailer {
        PlexResolvedTrailer(
            title: "Trailer",
            url: url,
            container: isHLS ? "m3u8" : (url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()),
            duration: nil,
            bitrate: nil,
            width: nil,
            height: nil,
            videoCodec: "h264",
            audioCodec: "aac",
            videoResolution: nil,
            file: url.lastPathComponent,
            size: nil
        )
    }

    private func resolvePlayableKey(from trailerURL: URL) async throws -> String {
        if let components = URLComponents(url: trailerURL, resolvingAgainstBaseURL: false),
           let uri = components.queryItems?.first(where: { $0.name == "uri" })?.value,
           uri.hasPrefix("provider://") {
            return uri
        }

        var request = URLRequest(url: trailerURL)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        addPlexClientHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexTrailerPlaybackError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlexTrailerPlaybackError.unexpectedStatusCode(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8),
              let playableKey = firstRegexMatch(in: html, pattern: #""playableKey":"(provider://[^"]+)""#) else {
            throw PlexTrailerPlaybackError.playableKeyNotFound
        }
        return playableKey
    }

    private func fetchPlayQueue(for playableKey: String, accountToken: String) async throws -> [String: Any] {
        guard var components = URLComponents(url: providerBaseURL.appendingPathComponent("playQueues"), resolvingAgainstBaseURL: false) else {
            throw PlexTrailerPlaybackError.invalidReference
        }

        components.queryItems = [
            URLQueryItem(name: "uri", value: playableKey),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "continuous", value: "1")
        ]

        guard let url = components.url else {
            throw PlexTrailerPlaybackError.invalidReference
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accountToken, forHTTPHeaderField: "X-Plex-Token")
        addPlexClientHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexTrailerPlaybackError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        default:
            throw PlexTrailerPlaybackError.unexpectedStatusCode(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mediaContainer = json["MediaContainer"] as? [String: Any] else {
            throw PlexTrailerPlaybackError.invalidResponse
        }
        return mediaContainer
    }

    private func selectedPlayQueueItem(from mediaContainer: [String: Any]) -> [String: Any]? {
        guard let items = mediaContainer["Metadata"] as? [[String: Any]], !items.isEmpty else {
            return nil
        }

        if let selectedID = mediaContainer["playQueueSelectedItemID"] as? Int,
           let selected = items.first(where: { ($0["playQueueItemID"] as? Int) == selectedID }) {
            return selected
        }

        return items.first
    }

    private func resolvedTrailer(from item: [String: Any], accountToken: String) -> PlexResolvedTrailer? {
        guard let mediaItems = item["Media"] as? [[String: Any]] else { return nil }

        var candidates: [(media: [String: Any], part: [String: Any])] = []
        for media in mediaItems {
            for part in (media["Part"] as? [[String: Any]]) ?? [] {
                guard cleaned(part["drm"] as? String) == nil,
                      cleaned(part["key"] as? String) != nil else {
                    continue
                }
                candidates.append((media, part))
            }
        }

        let preferred = candidates.first { candidate in
            let proto = cleaned(candidate.media["protocol"] as? String)?.lowercased()
            let key = cleaned(candidate.part["key"] as? String)?.lowercased() ?? ""
            return proto == "hls" || key.contains(".m3u8")
        } ?? candidates.first { candidate in
            let key = cleaned(candidate.part["key"] as? String)?.lowercased() ?? ""
            return key.contains(".mp4") || key.contains(".m4v") || key.contains(".mov")
        } ?? candidates.first

        guard let (media, part) = preferred,
              let streamURL = providerAssetURL(rawPath: part["key"] as? String, token: accountToken) else {
            return nil
        }

        let container = cleaned(media["container"] as? String)
            ?? (streamURL.absoluteString.lowercased().contains(".m3u8") ? "m3u8" : "mp4")

        return PlexResolvedTrailer(
            title: cleaned(item["title"] as? String) ?? "Trailer",
            url: streamURL,
            container: container.lowercased(),
            duration: intValue(part["duration"]) ?? intValue(media["duration"]),
            bitrate: intValue(media["bitrate"]),
            width: intValue(media["width"]),
            height: intValue(media["height"]),
            videoCodec: cleaned(media["videoCodec"] as? String),
            audioCodec: cleaned(media["audioCodec"] as? String),
            videoResolution: cleaned(media["videoResolution"] as? String),
            file: cleaned(part["file"] as? String),
            size: intValue(part["size"])
        )
    }

    private func providerAssetURL(rawPath: String?, token: String) -> URL? {
        guard let rawPath = cleaned(rawPath) else { return nil }

        if let absolute = URL(string: rawPath), absolute.scheme != nil {
            return absolute
        }

        guard var components = URLComponents(url: providerBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "includeAllStreams", value: "1"),
            URLQueryItem(name: "X-Plex-Product", value: "Plex Mediaverse"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        return components.url
    }

    private func metadata(for trailer: PlexResolvedTrailer) -> PlexMetadata {
        let mediaID = abs(trailer.url.absoluteString.hashValue % 1_000_000_000)
        let duration = trailer.duration
        let part = PlexPart(
            id: mediaID,
            key: trailer.url.absoluteString,
            duration: duration,
            file: trailer.file ?? trailer.url.lastPathComponent,
            size: trailer.size,
            container: trailer.container,
            Stream: nil
        )
        let media = PlexMedia(
            id: mediaID,
            duration: duration,
            bitrate: trailer.bitrate,
            width: trailer.width,
            height: trailer.height,
            aspectRatio: nil,
            audioChannels: nil,
            audioCodec: trailer.audioCodec ?? "aac",
            videoCodec: trailer.videoCodec ?? "h264",
            videoResolution: trailer.videoResolution,
            container: trailer.container,
            videoFrameRate: nil,
            Part: [part]
        )

        return PlexMetadata(
            ratingKey: "discover-trailer-\(mediaID)",
            key: trailer.url.absoluteString,
            type: "movie",
            title: trailer.title,
            summary: "Trailer",
            duration: duration,
            Media: [media]
        )
    }

    private func addPlexClientHeaders(to request: inout URLRequest) {
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(PlexAPI.deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
    }

    private func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "&amp;", with: "&")
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    private func firstRegexMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}
