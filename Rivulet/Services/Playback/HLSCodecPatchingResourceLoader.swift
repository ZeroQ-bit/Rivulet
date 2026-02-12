//
//  HLSCodecPatchingResourceLoader.swift
//  Rivulet
//
//  Intercepts HLS requests and patches hvc1 codec tag to dvh1 for Dolby Vision
//  This is needed because Plex's HLS remux outputs hvc1 instead of dvh1 for MKV+DV content,
//  but AVPlayer on tvOS requires dvh1 for Dolby Vision playback.
//

import AVFoundation

/// Intercepts HLS requests and patches hvc1 codec tag to dvh1 for Dolby Vision
final class HLSCodecPatchingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let customScheme = "patched-hls"
    private let originalScheme: String
    private let headers: [String: String]
    private var pendingRequests: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]
    private let lock = NSLock()

    init(originalScheme: String = "http", headers: [String: String] = [:]) {
        self.originalScheme = originalScheme
        self.headers = headers
        super.init()
    }

    // MARK: - URL Transformation

    /// Convert original URL to use custom scheme for interception
    static func patchedURL(from originalURL: URL) -> URL? {
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        let originalScheme = components?.scheme ?? "http"
        components?.scheme = "\(customScheme)-\(originalScheme)"
        return components?.url
    }

    /// Restore original URL from patched URL
    private func originalURL(from patchedURL: URL) -> URL? {
        var components = URLComponents(url: patchedURL, resolvingAgainstBaseURL: false)
        guard let scheme = components?.scheme, scheme.hasPrefix(Self.customScheme) else { return nil }
        let originalScheme = String(scheme.dropFirst(Self.customScheme.count + 1))
        components?.scheme = originalScheme
        return components?.url
    }

    /// Convert an original scheme URL to patched scheme
    private func patchedSchemeURL(from originalURL: String) -> String {
        // Replace http:// or https:// with our custom scheme
        if originalURL.hasPrefix("http://") {
            return originalURL.replacingOccurrences(of: "http://", with: "\(Self.customScheme)-http://")
        } else if originalURL.hasPrefix("https://") {
            return originalURL.replacingOccurrences(of: "https://", with: "\(Self.customScheme)-https://")
        }
        return originalURL
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Log ALL incoming requests to debug missing init segment
        let rawURL = loadingRequest.request.url?.absoluteString ?? "nil"

        guard let requestURL = loadingRequest.request.url,
              let originalURL = originalURL(from: requestURL) else {
            return false
        }

        let urlString = originalURL.absoluteString
        let isPlaylist = urlString.contains(".m3u8")

        // Log more details for playlists to understand variant selection
        if isPlaylist {
            // Show path component after /video/ for context
            if let videoRange = urlString.range(of: "/video/") {
                let relevantPath = String(urlString[videoRange.lowerBound...].prefix(100))
            } else {
            }
        } else {
        }

        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        // Apply custom headers (including auth token)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.handleResponse(
                data: data,
                response: response,
                error: error,
                loadingRequest: loadingRequest,
                originalURL: originalURL
            )
        }

        lock.lock()
        pendingRequests[loadingRequest] = task
        lock.unlock()

        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let task = pendingRequests.removeValue(forKey: loadingRequest)
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Response Handling

    private func handleResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        loadingRequest: AVAssetResourceLoadingRequest,
        originalURL: URL
    ) {
        lock.lock()
        pendingRequests.removeValue(forKey: loadingRequest)
        lock.unlock()

        // Check if request was already cancelled
        guard !loadingRequest.isCancelled else {
            return
        }

        if let error = error {
            print("[HLS Patcher] Request failed: \(error.localizedDescription) - \(originalURL.lastPathComponent)")
            loadingRequest.finishLoading(with: error)
            return
        }

        guard var data = data else {
            let noDataError = NSError(
                domain: "HLSCodecPatcher",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No data received"]
            )
            loadingRequest.finishLoading(with: noDataError)
            return
        }

        let httpResponse = response as? HTTPURLResponse
        let mimeType = httpResponse?.mimeType ?? ""
        let urlString = originalURL.absoluteString

        // Check if this is an m3u8 playlist - need to rewrite URLs
        if urlString.contains(".m3u8") || mimeType.contains("mpegurl") || mimeType.contains("m3u") {
            data = rewritePlaylistURLs(data, baseURL: originalURL)
        }
        // Log init segment but don't patch - keep hvc1 to match master playlist declaration
        // This allows playback as HEVC; DV metadata in video stream may still be recognized by TV
        else if shouldPatchCodecTag(data) {
        }
        // Log segment format for debugging
        else if data.count > 4 {
            let header = data.prefix(8)
            let headerHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")

            // Check for MPEG-TS sync byte (0x47)
            // Check for fMP4 (ftyp or moof box)
            else if let ftypMarker = "ftyp".data(using: .ascii), data.range(of: ftypMarker) != nil {
            } else if let moofMarker = "moof".data(using: .ascii), data.range(of: moofMarker) != nil {
            } else {
            }
        }

        // Set content info
        if let contentInfoRequest = loadingRequest.contentInformationRequest {
            contentInfoRequest.contentLength = Int64(data.count)
            contentInfoRequest.isByteRangeAccessSupported = false

            // Set appropriate content type
            if urlString.contains(".m3u8") {
                contentInfoRequest.contentType = "public.m3u-playlist"
            } else if !mimeType.isEmpty {
                contentInfoRequest.contentType = mimeType
            }
        }

        // Return data to AVPlayer
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    // MARK: - Playlist URL Rewriting

    /// Rewrite URLs in m3u8 playlist to use our custom scheme
    private func rewritePlaylistURLs(_ data: Data, baseURL: URL) -> Data {
        guard let playlistString = String(data: data, encoding: .utf8) else {
            return data
        }

        // Log playlist content for debugging
        let lines = playlistString.components(separatedBy: .newlines)
        let isVariant = playlistString.contains("#EXTINF")
        let isMaster = playlistString.contains("#EXT-X-STREAM-INF")

        // For master playlists, patch codec to hvc1 so AVPlayer accepts stream
        // AVPlayer rejects dvh1 codec declaration before downloading any content
        if isMaster {

            // Patch CODECS from dvh1 to hvc1 so AVPlayer accepts the stream
            // The init segment already has hvc1, so they will match
            var modifiedLines = lines.map { line -> String in
                if line.contains("CODECS=\"dvh1") {
                    let patched = line.replacingOccurrences(
                        of: "dvh1.08.06",
                        with: "hvc1.2.4.L153.B0"
                    )
                    print("[HLS Patcher] Patched CODECS: dvh1.08.06 -> hvc1.2.4.L153.B0")
                    return patched
                }
                return line
            }

            // Remove I-frame stream reference so AVPlayer uses the main base variant
            modifiedLines = modifiedLines.filter { !$0.contains("I-FRAME") }

            let modifiedMaster = modifiedLines.joined(separator: "\n")
            return modifiedMaster.data(using: .utf8) ?? data
        }

        // Check for fMP4 init segment (EXT-X-MAP)
        if let mapLine = lines.first(where: { $0.contains("#EXT-X-MAP") }) {
            // Log first 15 lines of fMP4 variant playlist for debugging
        } else if isVariant {
            print("[HLS Patcher] WARNING: No #EXT-X-MAP found - using MPEG-TS format (no init segment to patch)")
        }

        // Log codec info from master playlist
        if let codecLine = lines.first(where: { $0.contains("CODECS=") }) {
            if let codecStart = codecLine.range(of: "CODECS=\""),
               let codecEnd = codecLine[codecStart.upperBound...].firstIndex(of: "\"") {
                let codecs = String(codecLine[codecStart.upperBound..<codecEnd])
                print("[HLS Patcher] Playlist codecs: \(codecs)")
            }
        }

        var modifiedPlaylist = playlistString
        var urlsRewritten = 0

        // Rewrite absolute URLs (http:// and https://)
        var modifiedLines: [String] = []

        for line in lines {
            var modifiedLine = line

            // Skip comment lines that don't contain URIs
            if line.hasPrefix("#") && !line.contains("URI=") {
                modifiedLines.append(line)
                continue
            }

            // Handle URI= attributes (e.g., in EXT-X-MAP or EXT-X-KEY)
            if line.contains("URI=\"http://") || line.contains("URI=\"https://") {
                // Extract and replace URI value
                if let range = line.range(of: "URI=\"http://") {
                    let urlStart = range.lowerBound
                    if let endQuote = line[range.upperBound...].firstIndex(of: "\"") {
                        let urlEndIndex = line.index(before: endQuote)
                        let originalURL = String(line[line.index(urlStart, offsetBy: 5)...urlEndIndex])
                        let patchedURL = patchedSchemeURL(from: originalURL)
                        modifiedLine = line.replacingOccurrences(of: originalURL, with: patchedURL)
                        urlsRewritten += 1
                    }
                } else if let range = line.range(of: "URI=\"https://") {
                    let urlStart = range.lowerBound
                    if let endQuote = line[range.upperBound...].firstIndex(of: "\"") {
                        let urlEndIndex = line.index(before: endQuote)
                        let originalURL = String(line[line.index(urlStart, offsetBy: 5)...urlEndIndex])
                        let patchedURL = patchedSchemeURL(from: originalURL)
                        modifiedLine = line.replacingOccurrences(of: originalURL, with: patchedURL)
                        urlsRewritten += 1
                    }
                }
            }
            // Handle standalone URLs (segment URLs)
            else if line.hasPrefix("http://") || line.hasPrefix("https://") {
                modifiedLine = patchedSchemeURL(from: line)
                urlsRewritten += 1
            }

            modifiedLines.append(modifiedLine)
        }

        modifiedPlaylist = modifiedLines.joined(separator: "\n")

        return modifiedPlaylist.data(using: .utf8) ?? data
    }

    // MARK: - Codec Tag Patching

    /// Check if data contains hvc1 codec tag that needs patching
    /// Only patch init segments (fMP4 with ftyp box) containing hvc1
    private func shouldPatchCodecTag(_ data: Data) -> Bool {
        // Look for "ftyp" box marker to confirm it's an fMP4 init segment
        guard let ftypMarker = "ftyp".data(using: .ascii),
              let hvc1Marker = "hvc1".data(using: .ascii) else {
            return false
        }

        // Must have both ftyp (init segment) and hvc1 (HEVC codec tag)
        return data.range(of: ftypMarker) != nil && data.range(of: hvc1Marker) != nil
    }

    /// Patch hvc1 codec tag to dvh1 for Dolby Vision compatibility
    /// This changes 4 bytes in the stsd (sample description) box
    private func patchCodecTag(_ data: Data) -> Data {
        var mutableData = data

        guard let hvc1 = "hvc1".data(using: .ascii),
              let dvh1 = "dvh1".data(using: .ascii) else {
            return data
        }

        // Replace all occurrences (usually just one in stsd box)
        var patchCount = 0
        while let range = mutableData.range(of: hvc1) {
            mutableData.replaceSubrange(range, with: dvh1)
            patchCount += 1
        }

        if patchCount > 0 {
            print("[HLS Patcher] Replaced \(patchCount) hvc1 tag(s) with dvh1")
        }

        return mutableData
    }
}
