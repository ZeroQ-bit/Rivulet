//
//  DVHLSProxyServer.swift
//  Rivulet
//
//  Local HTTP reverse proxy that patches Dolby Vision HLS master playlists.
//  Proxies all HLS requests to the Plex server, patching only the master
//  playlist response (dvh1 → hvc1 in CODECS) so AVPlayer accepts DV content.
//
//  This approach avoids:
//  - AVAssetResourceLoaderDelegate timeout issues (approach #3)
//  - file:// master can't reference http:// variants (approach #5/6)
//  - AVPlayer rejecting dvh1 codec declarations (error -11848)
//

import Foundation
import Network

/// Patching strategy for DV HLS content
enum DVHLSPatchMode {
    /// Patch master dvh1→hvc1, leave init as hvc1 (plays as HDR10)
    case patchMasterToHVC1
    /// Keep master as dvh1, leave init as hvc1 (test: does real HTTP avoid -11848?)
    case keepDVH1InMaster
    /// Patch master dvh1→hvc1, patch init hvc1→dvh1 (test: does init dvh1 trigger DV pipeline?)
    case patchInitToDVH1
}

/// Lightweight HTTP reverse proxy that patches DV HLS master playlists for AVPlayer compatibility.
///
/// AVPlayer on tvOS rejects `dvh1` in HLS CODECS strings. Plex's HLS remux for MKV+DV content
/// declares `dvh1.08.06` in the master playlist. This proxy intercepts the master playlist response
/// and patches `dvh1` → `hvc1` so AVPlayer accepts the stream, while the init segment's `hvc1`
/// codec tag matches naturally.
final class DVHLSProxyServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rivulet.DVHLSProxy")
    private var connections: [NWConnection] = []

    /// The upstream Plex server URL (scheme + host + port)
    private let upstreamBaseURL: URL
    /// Headers to forward to Plex (auth, client info)
    private let upstreamHeaders: [String: String]
    /// The full original master playlist URL path + query from Plex
    private let originalMasterPath: String
    /// Patching strategy
    private let patchMode: DVHLSPatchMode

    /// Port the proxy is listening on
    private(set) var port: UInt16 = 0

    /// Whether the proxy is running
    private(set) var isRunning = false

    init(upstreamURL: URL, headers: [String: String], patchMode: DVHLSPatchMode = .patchMasterToHVC1) {
        // Extract base URL (scheme + host + port)
        var components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false)!
        let fullPath = components.path
        let query = components.query
        self.originalMasterPath = query != nil ? "\(fullPath)?\(query!)" : fullPath

        components.path = ""
        components.query = nil
        components.fragment = nil
        self.upstreamBaseURL = components.url!
        self.upstreamHeaders = headers
        self.patchMode = patchMode
    }

    /// Start the proxy server. Returns the localhost URL to pass to AVPlayer.
    func start() throws -> URL {
        // Use TCP on a random available port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Allow insecure local connections
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port {
                    self?.port = port.rawValue
                    self?.isRunning = true
                }
            case .failed(let error):
                print("[DV Proxy] Listener failed: \(error)")
                self?.isRunning = false
            case .cancelled:
                print("[DV Proxy] Listener cancelled")
                self?.isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        self.listener = listener
        listener.start(queue: queue)

        // Wait for listener to be ready (up to 2s)
        let startTime = Date()
        while !isRunning && Date().timeIntervalSince(startTime) < 2.0 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        guard isRunning, port > 0 else {
            throw NSError(domain: "DVHLSProxy", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start proxy server"])
        }

        // Build the proxy URL that mirrors the original Plex path
        let proxyURL = URL(string: "http://127.0.0.1:\(port)\(originalMasterPath)")!
        return proxyURL
    }

    /// Stop the proxy server
    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            for connection in connections {
                connection.cancel()
            }
            connections.removeAll()
        }
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.connections.append(connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                print("[DV Proxy] Connection failed: \(error)")
                self?.removeConnection(connection)
            }
        }

        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.connections.removeAll { $0 === connection }
        }
    }

    private func receiveHTTPRequest(on connection: NWConnection) {
        // Read up to 16KB for the HTTP request (headers only, no body expected)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if let error = error {
                    print("[DV Proxy] Receive error: \(error)")
                }
                connection.cancel()
                self?.removeConnection(connection)
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendError(on: connection, status: 400, message: "Bad Request")
                return
            }

            // Parse the request line: "GET /path HTTP/1.1"
            let lines = requestString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                self.sendError(on: connection, status: 400, message: "Bad Request")
                return
            }

            let parts = requestLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else {
                self.sendError(on: connection, status: 400, message: "Bad Request")
                return
            }

            let path = String(parts[1])

            // Forward to Plex
            self.proxyRequest(path: path, on: connection)
        }
    }

    // MARK: - Proxying

    private func proxyRequest(path: String, on connection: NWConnection) {
        // Build upstream URL
        let upstreamURLString = upstreamBaseURL.absoluteString + path
        guard let upstreamURL = URL(string: upstreamURLString) else {
            sendError(on: connection, status: 502, message: "Bad Gateway - Invalid upstream URL")
            return
        }

        var request = URLRequest(url: upstreamURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        // Forward auth headers to Plex
        for (key, value) in upstreamHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let isMasterPlaylist = self.isMasterPlaylistRequest(path: path)
        let isInitSegment = self.isInitSegmentRequest(path: path)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[DV Proxy] Upstream error: \(error.localizedDescription)")
                self.sendError(on: connection, status: 502, message: "Bad Gateway - \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, var data = data else {
                self.sendError(on: connection, status: 502, message: "Bad Gateway - No response")
                return
            }

            // Patch the master playlist if needed
            if isMasterPlaylist && httpResponse.statusCode == 200 {
                data = self.patchMasterPlaylist(data)
            }

            // Patch the init segment if needed (patchInitToDVH1 mode)
            if isInitSegment && httpResponse.statusCode == 200 && self.patchMode == .patchInitToDVH1 {
                data = self.patchInitSegment(data)
            }

            // Build HTTP response
            var responseLines = [
                "HTTP/1.1 \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))",
                "Content-Length: \(data.count)",
                "Connection: close"
            ]

            // Forward content type
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                responseLines.append("Content-Type: \(contentType)")
            }

            // Allow cross-origin for local playback
            responseLines.append("Access-Control-Allow-Origin: *")
            responseLines.append("") // End of headers
            responseLines.append("") // Blank line before body

            let headerString = responseLines.joined(separator: "\r\n")
            var responseData = headerString.data(using: .utf8)!
            responseData.append(data)

            connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("[DV Proxy] Send error: \(error)")
                }
                connection.cancel()
                self?.removeConnection(connection)
            })
        }.resume()
    }

    // MARK: - Master Playlist Detection

    private func isMasterPlaylistRequest(path: String) -> Bool {
        // The first request will be the master playlist (same path as originalMasterPath)
        // Also detect by .m3u8 at the path level before query params
        let pathOnly = path.components(separatedBy: "?").first ?? path
        // Master playlists from Plex end with start.m3u8 or are the transcode endpoint
        return path.hasPrefix(originalMasterPath.components(separatedBy: "?").first ?? originalMasterPath)
            && (pathOnly.hasSuffix("start.m3u8") || pathOnly.contains("/transcode/universal"))
    }

    private func isInitSegmentRequest(path: String) -> Bool {
        // Plex init segments end with "header" (no extension)
        let pathOnly = path.components(separatedBy: "?").first ?? path
        return pathOnly.hasSuffix("/header")
    }

    // MARK: - Playlist Patching

    private func patchMasterPlaylist(_ data: Data) -> Data {
        guard let playlist = String(data: data, encoding: .utf8) else {
            print("[DV Proxy] Could not decode master playlist as UTF-8")
            return data
        }

        let lines = playlist.components(separatedBy: "\n")
        var patchedLines: [String] = []
        var didPatch = false

        for line in lines {
            var modifiedLine = line

            switch patchMode {
            case .patchMasterToHVC1, .patchInitToDVH1:
                // Patch CODECS: dvh1.xx.xx → hvc1.2.4.L153.B0
                // dvh1 can appear anywhere in the CODECS string (e.g., "ac-3,dvh1.08.06")
                if modifiedLine.contains("CODECS=") && modifiedLine.contains("dvh1") {
                    modifiedLine = modifiedLine.replacingOccurrences(
                        of: #"dvh1\.\d+\.\d+"#,
                        with: "hvc1.2.4.L153.B0",
                        options: .regularExpression
                    )
                    didPatch = true
                    print("[DV Proxy] Patched CODECS: dvh1 → hvc1.2.4.L153.B0")
                }
            case .keepDVH1InMaster:
                // Don't patch CODECS - keep dvh1 as-is
                if modifiedLine.contains("CODECS=") && modifiedLine.contains("dvh1") {
                    didPatch = true
                    print("[DV Proxy] Keeping CODECS as dvh1 (no patch)")
                }
            }

            // Remove I-FRAME-STREAM-INF lines (uses keyframes playlist that confuses AVPlayer)
            if modifiedLine.contains("I-FRAME") {
                print("[DV Proxy] Removed I-FRAME stream line")
                continue
            }

            patchedLines.append(modifiedLine)
        }

        if !didPatch {
            print("[DV Proxy] WARNING: No dvh1 codec found in master playlist - passing through unmodified")
        }

        let patched = patchedLines.joined(separator: "\n")

        return patched.data(using: .utf8) ?? data
    }

    // MARK: - Init Segment Patching

    /// Patch hvc1 → dvh1 in the fMP4 init segment's stsd box
    private func patchInitSegment(_ data: Data) -> Data {
        guard let hvc1Marker = "hvc1".data(using: .ascii),
              let dvh1Marker = "dvh1".data(using: .ascii) else {
            return data
        }

        // Verify this is an fMP4 init segment (has ftyp box)
        guard let ftypMarker = "ftyp".data(using: .ascii),
              data.range(of: ftypMarker) != nil else {
            print("[DV Proxy] Init segment: no ftyp box found, skipping patch")
            return data
        }

        var mutableData = data
        var patchCount = 0

        while let range = mutableData.range(of: hvc1Marker) {
            mutableData.replaceSubrange(range, with: dvh1Marker)
            patchCount += 1
        }

        if patchCount > 0 {
            print("[DV Proxy] Patched \(patchCount) hvc1 → dvh1 in init segment (\(data.count) bytes)")
        } else {
            print("[DV Proxy] Init segment: no hvc1 found to patch")
        }

        return mutableData
    }

    // MARK: - Error Response

    private func sendError(on connection: NWConnection, status: Int, message: String) {
        let body = message.data(using: .utf8)!
        let response = [
            "HTTP/1.1 \(status) \(message)",
            "Content-Length: \(body.count)",
            "Content-Type: text/plain",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var responseData = response.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(connection)
        })
    }
}
