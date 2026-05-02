//
//  LocalRemuxServer.swift
//  Rivulet
//
//  NWListener-based local HTTP server that serves HLS playlists and fMP4
//  segments from an FFmpegRemuxSession. AVPlayer connects to localhost
//  and gets properly formatted HLS content.
//
//  Endpoints:
//    GET /master.m3u8    → HLS master playlist (single variant)
//    GET /stream.m3u8    → HLS media playlist (all segments with durations)
//    GET /init.mp4       → fMP4 init segment (moov with codec descriptors)
//    GET /segment_N.m4s  → fMP4 media segment (moof+mdat)
//

import Foundation
import Network

/// Local HTTP server that serves remuxed HLS content for AVPlayer.
nonisolated final class LocalRemuxServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rivulet.LocalRemuxServer")
    private var connections: Set<NWConnection> = []
    private let connectionLock = NSLock()

    /// The remux session producing fMP4 segments
    private let session: FFmpegRemuxSession

    /// Session info from open()
    private var sessionInfo: RemuxSessionInfo

    /// Port the server is listening on
    private(set) var port: UInt16 = 0

    /// Whether the server is running
    private(set) var isRunning = false

    /// Segment cache — ring buffer to avoid regenerating recent segments.
    /// 60 segments at 6s each = 360s lookahead buffer.
    private var segmentCache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private let maxCachedSegments = 60
    private let cacheLock = NSLock()

    /// Read-ahead tasks for background pre-generation.
    private var readAheadTasks: [Task<Void, Never>] = []

    /// Last segment index requested — used to detect seeks vs sequential access.
    private var lastRequestedIndex: Int = -1

    /// Segments currently being generated (prevents duplicate actor calls).
    private var inFlightSegments: Set<Int> = []

    /// Cached init segment
    private var initSegment: Data?

    /// Actual segment durations — updated as segments are generated.
    /// AVPlayer re-fetches EVENT playlists, so updated durations replace estimates.
    private var actualSegmentDurations: [Int: TimeInterval] = [:]
    private let durationLock = NSLock()

    /// Start offset for EXT-X-START — tells AVPlayer to begin at this time
    /// instead of segment 0, avoiding wrong-position playback + deferred seek.
    var startOffset: TimeInterval = 0

    init(
        session: FFmpegRemuxSession,
        sessionInfo: RemuxSessionInfo,
        prebuiltInitSegment: Data? = nil,
        prebuiltSegments: [Int: Data] = [:]
    ) {
        self.session = session
        self.sessionInfo = sessionInfo
        self.initSegment = prebuiltInitSegment
        if !prebuiltSegments.isEmpty {
            self.segmentCache = prebuiltSegments
            self.cacheOrder = prebuiltSegments.keys.sorted()
        }
    }

    // MARK: - Start/Stop

    /// Start the local HTTP server and return the master playlist URL.
    func start() throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
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
                playerDebugLog("[Remux] Listener failed: \(error)")
                self?.isRunning = false
            case .cancelled:
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
            throw NSError(domain: "LocalRemuxServer", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start remux server"])
        }

        let url = URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
        playerDebugLog("[Remux] Started on port \(port)")
        return url
    }

    /// Stop the server and clean up.
    func stop() {
        listener?.cancel()
        listener = nil

        connectionLock.lock()
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionLock.unlock()

        cacheLock.lock()
        segmentCache.removeAll()
        cacheOrder.removeAll()
        cacheLock.unlock()

        for task in readAheadTasks { task.cancel() }
        readAheadTasks.removeAll()
        lastRequestedIndex = -1
        inFlightSegments.removeAll()

        initSegment = nil
        isRunning = false
        playerDebugLog("[Remux] Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connectionLock.lock()
        connections.insert(connection)
        connectionLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.removeConnection(connection)
            }
        }

        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        connectionLock.lock()
        connections.remove(connection)
        connectionLock.unlock()
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                self?.removeConnection(connection)
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendError(on: connection, status: 400, message: "Bad Request")
                return
            }

            // Parse request line
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
            self.routeRequest(path: path, on: connection)
        }
    }

    // MARK: - Request Routing

    private func routeRequest(path: String, on connection: NWConnection) {
        let pathOnly = path.components(separatedBy: "?").first ?? path
        playerDebugLog("[Remux] Request: \(pathOnly)")

        if pathOnly == "/master.m3u8" {
            serveMasterPlaylist(on: connection)
        } else if pathOnly == "/stream.m3u8" {
            serveMediaPlaylist(on: connection)
        } else if pathOnly == "/init.mp4" {
            serveInitSegment(on: connection)
        } else if pathOnly.hasPrefix("/segment_"), pathOnly.hasSuffix(".m4s") {
            // Extract segment index from "/segment_N.m4s"
            let indexStr = pathOnly
                .replacingOccurrences(of: "/segment_", with: "")
                .replacingOccurrences(of: ".m4s", with: "")
            if let index = Int(indexStr) {
                serveMediaSegment(index: index, on: connection)
            } else {
                sendError(on: connection, status: 400, message: "Invalid segment index")
            }
        } else {
            sendError(on: connection, status: 404, message: "Not Found")
        }
    }

    // MARK: - Master Playlist

    private func serveMasterPlaylist(on connection: NWConnection) {
        // Build codec string matching the actual video codec.
        // Mismatch between playlist CODECS and init segment stsd causes AVPlayer
        // to reject every video sample with -12860 (kCMSampleBufferError_DataFailed).
        let codecs: String
        switch sessionInfo.videoCodecName {
        case "hevc":
            // Apple HLS requires hvc1 in CODECS (even for DV — dvh1 is rejected here,
            // but the init segment's stsd uses dvh1 to trigger the DV pipeline).
            codecs = "hvc1.2.4.L153.B0"
        case "h264":
            codecs = "avc1.640028"  // High Profile Level 4.0
        default:
            codecs = "avc1.640028"  // Safe fallback
        }

        // Audio codec string
        let audioCodec: String
        if sessionInfo.needsAudioTranscode {
            audioCodec = "ec-3"  // EAC3
        } else {
            switch sessionInfo.audioCodecName {
            case "aac": audioCodec = "mp4a.40.2"
            case "ac3": audioCodec = "ac-3"
            case "eac3", "ec-3": audioCodec = "ec-3"
            case "flac": audioCodec = "fLaC"
            case "alac": audioCodec = "alac"
            default: audioCodec = "mp4a.40.2"
            }
        }

        let resolution = "\(sessionInfo.width)x\(sessionInfo.height)"
        // Rough bandwidth estimate (we don't know actual bitrate, use a reasonable default)
        let bandwidth = 20_000_000  // 20 Mbps — high enough to not throttle

        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        playlist += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(resolution),"
        playlist += "CODECS=\"\(codecs),\(audioCodec)\"\n"
        playlist += "stream.m3u8\n"

        sendResponse(on: connection,
                     contentType: "application/vnd.apple.mpegurl",
                     body: playlist.data(using: .utf8)!)
    }

    // MARK: - Media Playlist

    private func serveMediaPlaylist(on connection: NWConnection) {
        let segments = sessionInfo.segments

        // Use actual segment durations when available (from generated segments).
        // AVPlayer maps segment content to the EXTINF timeline — mismatches cause
        // gaps that accumulate and eventually prevent decoding.
        durationLock.lock()
        let durations = actualSegmentDurations
        durationLock.unlock()

        // Compute target duration from actual + estimated
        var maxDuration = 6.0
        for seg in segments {
            let dur = durations[seg.index] ?? seg.duration
            if dur > maxDuration { maxDuration = dur }
        }

        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(Int(ceil(maxDuration)))\n"
        // Omit EXT-X-PLAYLIST-TYPE so AVPlayer may re-fetch the playlist.
        // This lets us update EXTINF durations as segments are generated,
        // ensuring the timeline matches actual content (not estimated 6.0s).
        // VOD causes AVPlayer to cache and never see updated durations.
        playlist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        playlist += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        if startOffset > 0 {
            playlist += "#EXT-X-START:TIME-OFFSET=\(String(format: "%.3f", startOffset))\n"
        }
        playlist += "#EXT-X-MAP:URI=\"init.mp4\"\n"

        for segment in segments {
            let duration = durations[segment.index] ?? segment.duration
            playlist += "#EXTINF:\(String(format: "%.6f", duration)),\n"
            playlist += "segment_\(segment.index).m4s\n"
        }

        playlist += "#EXT-X-ENDLIST\n"

        sendResponse(on: connection,
                     contentType: "application/vnd.apple.mpegurl",
                     body: playlist.data(using: .utf8)!)
    }

    // MARK: - Init Segment

    private func serveInitSegment(on connection: NWConnection) {
        // Check cache first
        if let cached = initSegment {
            sendResponse(on: connection, contentType: "video/mp4", body: cached)
            return
        }

        // Generate asynchronously
        Task {
            do {
                let data = try await session.generateInitSegment()
                self.initSegment = data
                self.sendResponse(on: connection, contentType: "video/mp4", body: data)
            } catch {
                playerDebugLog("[Remux] Init segment generation failed: \(error)")
                self.sendError(on: connection, status: 500, message: "Init segment generation failed")
            }
        }
    }

    // MARK: - Media Segment

    private func serveMediaSegment(index: Int, on connection: NWConnection) {
        guard index >= 0 && index < sessionInfo.segments.count else {
            sendError(on: connection, status: 404, message: "Segment out of range")
            return
        }

        let isSeek = index != lastRequestedIndex + 1 && lastRequestedIndex >= 0
        lastRequestedIndex = index

        // Cache hit — serve immediately
        cacheLock.lock()
        if let cached = segmentCache[index] {
            cacheLock.unlock()
            playerDebugLog("[Remux] Segment \(index) cache hit (\(cached.count) bytes)")
            sendResponse(on: connection, contentType: "video/mp4", body: cached)
            startReadAhead(from: index + 1)
            return
        }
        cacheLock.unlock()

        // On seek, cancel read-ahead so we don't wait behind stale pre-generation.
        // For sequential access, let read-ahead continue — it may be nearly done.
        if isSeek {
            playerDebugLog("[Remux] Seek detected: segment \(index), cancelling read-ahead")
            // Signal FFmpeg's interrupt callback to abort any in-progress av_read_frame()
            // immediately. This bypasses actor serialization — the stale generation exits
            // within one I/O poll cycle (~10-50ms) instead of running to completion (~4s).
            session.interruptFlag.pointee = 1
            for task in readAheadTasks { task.cancel() }
            readAheadTasks.removeAll()
            inFlightSegments.removeAll()
        }

        // If read-ahead is already generating this segment, wait for it
        if inFlightSegments.contains(index) {
            Task {
                await self.waitForCachedSegment(index: index, on: connection)
            }
            return
        }

        // Cache miss — generate and serve with Content-Length.
        // With interrupt callback + fast seeks, generation is ~2-3s which is
        // within AVPlayer's HTTP timeout. Chunked encoding caused AVPlayer to
        // miscount the segment delivery rate and get stuck evaluating buffering.
        inFlightSegments.insert(index)
        Task {
            do {
                let generationStart = Date()
                let data = try await self.session.generateSegment(index: index)
                if let dur = await self.session.lastSegmentActualDuration {
                    self.recordSegmentDuration(index: index, duration: dur)
                }
                self.inFlightSegments.remove(index)
                self.cacheSegment(index: index, data: data)
                let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
                playerDebugLog("[Remux] Segment \(index) generated (\(data.count) bytes, elapsed=\(elapsedMs)ms)")
                self.sendResponse(on: connection, contentType: "video/mp4", body: data)
                self.startReadAhead(from: index + 1)
            } catch {
                self.inFlightSegments.remove(index)
                playerDebugLog("[Remux] Segment \(index) generation failed: \(error)")
                self.sendError(on: connection, status: 500, message: "Segment generation failed")
            }
        }
    }

    /// Wait for an in-flight read-ahead to populate the cache, then serve.
    private func waitForCachedSegment(index: Int, on connection: NWConnection) async {
        let waitStart = Date()
        // Poll cache every 50ms for up to 10 seconds
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 50_000_000)

            if let cached = cachedSegment(for: index) {
                let waitedMs = Int(Date().timeIntervalSince(waitStart) * 1000)
                playerDebugLog("[Remux] Segment \(index) served from read-ahead cache (wait=\(waitedMs)ms)")
                sendResponse(on: connection, contentType: "video/mp4", body: cached)
                startReadAhead(from: index + 1)
                return
            }

            // If read-ahead finished without caching (error/cancel), generate directly
            if !inFlightSegments.contains(index) {
                break
            }

            // If AVPlayer seeked away, stop waiting — this segment is stale
            if lastRequestedIndex > index {
                playerDebugLog("[Remux] Segment \(index) wait abandoned — AVPlayer moved to \(lastRequestedIndex)")
                connection.cancel()
                removeConnection(connection)
                return
            }
        }

        // If AVPlayer seeked away, don't bother generating
        if lastRequestedIndex > index {
            playerDebugLog("[Remux] Segment \(index) fallback skipped — AVPlayer moved to \(lastRequestedIndex)")
            connection.cancel()
            removeConnection(connection)
            return
        }

        // Fallback: generate directly
        inFlightSegments.insert(index)
        do {
            let generationStart = Date()
            let data = try await session.generateSegment(index: index)
            if let dur = await session.lastSegmentActualDuration {
                recordSegmentDuration(index: index, duration: dur)
            }
            inFlightSegments.remove(index)
            cacheSegment(index: index, data: data)
            let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
            playerDebugLog("[Remux] Segment \(index) generated after wait fallback (\(data.count) bytes, elapsed=\(elapsedMs)ms)")
            sendResponse(on: connection, contentType: "video/mp4", body: data)
            startReadAhead(from: index + 1)
        } catch {
            inFlightSegments.remove(index)
            playerDebugLog("[Remux] Segment \(index) generation failed: \(error)")
            sendError(on: connection, status: 500, message: "Segment generation failed")
        }
    }

    // MARK: - Read-Ahead

    /// Fire-and-forget background generation of the next few segments.
    /// If AVPlayer requests them before they finish, direct generation handles it.
    /// Only reads ahead near the current playback position to avoid stale generation.
    private func startReadAhead(from startIndex: Int) {
        // Don't read ahead from a stale position — AVPlayer may have seeked away.
        // Allow read-ahead only if it's near what AVPlayer last requested.
        if lastRequestedIndex >= 0 && startIndex < lastRequestedIndex {
            return
        }

        let segmentCount = sessionInfo.segments.count
        let readAheadCount = 3
        let endIndex = min(startIndex + readAheadCount, segmentCount)
        guard startIndex < endIndex else { return }

        for i in startIndex..<endIndex {
            cacheLock.lock()
            let alreadyCached = segmentCache[i] != nil
            cacheLock.unlock()
            if alreadyCached || inFlightSegments.contains(i) { continue }

            inFlightSegments.insert(i)
            let task = Task { [weak self] in
                guard let self = self else { return }
                guard !Task.isCancelled else {
                    self.inFlightSegments.remove(i)
                    return
                }

                do {
                    let data = try await self.session.generateSegment(index: i)
                    if let dur = await self.session.lastSegmentActualDuration {
                        self.recordSegmentDuration(index: i, duration: dur)
                    }
                    self.inFlightSegments.remove(i)
                    self.cacheSegment(index: i, data: data)
                    playerDebugLog("[Remux] Read-ahead segment \(i) cached (\(data.count) bytes)")
                } catch {
                    self.inFlightSegments.remove(i)
                    if !Task.isCancelled {
                        playerDebugLog("[Remux] Read-ahead segment \(i) failed: \(error)")
                    }
                }
            }
            readAheadTasks.append(task)
        }

        // Clean up completed tasks
        readAheadTasks.removeAll { $0.isCancelled }
    }

    /// Update the session info with new segment data (e.g., after background Cue load).
    func updateSessionInfo(_ newInfo: RemuxSessionInfo) {
        self.sessionInfo = newInfo
    }

    /// Record the actual duration of a generated segment.
    func recordSegmentDuration(index: Int, duration: TimeInterval) {
        durationLock.lock()
        actualSegmentDurations[index] = duration
        durationLock.unlock()
    }

    // MARK: - Cache Management

    private func cacheSegment(index: Int, data: Data) {
        cacheLock.lock()
        if segmentCache[index] != nil {
            cacheOrder.removeAll { $0 == index }
        }
        segmentCache[index] = data
        cacheOrder.append(index)
        while cacheOrder.count > maxCachedSegments {
            let evicted = cacheOrder.removeFirst()
            segmentCache.removeValue(forKey: evicted)
        }
        cacheLock.unlock()
    }

    private func cachedSegment(for index: Int) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return segmentCache[index]
    }

    // MARK: - HTTP Response Helpers

    private func sendResponse(on connection: NWConnection, contentType: String, body: Data) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = response.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                if case let .posix(code) = error,
                   code == .EPIPE || code == .ECONNRESET {
                    // AVPlayer frequently cancels duplicate/in-flight segment requests.
                    // Treat broken pipe/reset as expected client aborts.
                } else {
                    playerDebugLog("[Remux] Send error: \(error)")
                }
            }
            connection.cancel()
            self?.removeConnection(connection)
        })
    }

    /// Send HTTP 200 headers immediately with chunked transfer encoding.
    /// The body is sent separately via `sendChunkedResponseBody()`.
    /// This prevents AVPlayer from timing out during slow segment generation.
    private func sendChunkedResponseHeaders(on connection: NWConnection, contentType: String) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Transfer-Encoding: chunked\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        connection.send(content: response.data(using: .utf8)!, contentContext: .defaultMessage,
                        isComplete: false, completion: .contentProcessed { error in
            if let error = error {
                playerDebugLog("[Remux] Chunked header send error: \(error)")
            }
        })
    }

    /// Send the body for a chunked response and close the connection.
    private func sendChunkedResponseBody(on connection: NWConnection, body: Data) {
        // Chunked encoding: hex-size CRLF data CRLF, then terminal 0-chunk
        let chunkHeader = String(format: "%x\r\n", body.count).data(using: .utf8)!
        let chunkTrailer = "\r\n0\r\n\r\n".data(using: .utf8)!

        var payload = Data()
        payload.reserveCapacity(chunkHeader.count + body.count + chunkTrailer.count)
        payload.append(chunkHeader)
        payload.append(body)
        payload.append(chunkTrailer)

        connection.send(content: payload, contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error = error {
                if case let .posix(code) = error,
                   code == .EPIPE || code == .ECONNRESET {
                    // Expected — AVPlayer may have moved on
                } else {
                    playerDebugLog("[Remux] Chunked body send error: \(error)")
                }
            }
            connection.cancel()
            self?.removeConnection(connection)
        })
    }

    private func sendError(on connection: NWConnection, status: Int, message: String) {
        let body = message.data(using: .utf8)!
        var response = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        response += "Content-Type: text/plain\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = response.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(connection)
        })
    }
}

// MARK: - NWConnection Hashable

nonisolated extension NWConnection: @retroactive Hashable {
    public static func == (lhs: NWConnection, rhs: NWConnection) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
