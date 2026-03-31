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
final class LocalRemuxServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rivulet.LocalRemuxServer")
    private var connections: Set<NWConnection> = []
    private let connectionLock = NSLock()

    /// The remux session producing fMP4 segments
    private let session: FFmpegRemuxSession

    /// Session info from open()
    private let sessionInfo: RemuxSessionInfo

    /// Port the server is listening on
    private(set) var port: UInt16 = 0

    /// Whether the server is running
    private(set) var isRunning = false

    /// Segment cache — ring buffer to avoid regenerating recent segments.
    /// 60 segments at 2s each = 120s lookahead buffer.
    private var segmentCache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private let maxCachedSegments = 60
    private let cacheLock = NSLock()

    /// Sequential producer state.
    /// Produces segments in index order with bounded lookahead from latest demand.
    private let producerLock = NSLock()
    private var producerTask: Task<Void, Never>?
    private var producerCursor: Int?
    private var producerMaxRequested = -1
    private let producerLookahead = 12

    /// Cached init segment
    private var initSegment: Data?

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
                print("[RemuxServer] Listener failed: \(error)")
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
        print("[RemuxServer] Started on port \(port)")
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
        producerLock.lock()
        producerTask?.cancel()
        producerTask = nil
        producerCursor = nil
        producerMaxRequested = -1
        producerLock.unlock()

        initSegment = nil
        isRunning = false
        print("[RemuxServer] Stopped")
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
        print("[RemuxServer] Request: \(pathOnly)")

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
        // Build codec string
        var codecs = "hvc1.2.4.L153.B0"  // Default HEVC
        if sessionInfo.hasDolbyVision {
            // Use hvc1 in master playlist — AVPlayer rejects dvh1 in CODECS
            // The init segment's codec tag (dvh1) triggers DV pipeline
            codecs = "hvc1.2.4.L153.B0"
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

        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:7\n"
        playlist += "#EXT-X-TARGETDURATION:\(Int(ceil(segments.map(\.duration).max() ?? 6.0)))\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        playlist += "#EXT-X-MAP:URI=\"init.mp4\"\n"

        for segment in segments {
            playlist += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n"
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
                print("[RemuxServer] Init segment generation failed: \(error)")
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

        // Cache hit — serve immediately with Content-Length
        cacheLock.lock()
        if let cached = segmentCache[index] {
            cacheLock.unlock()
            print("[RemuxServer] Segment \(index) cache hit (\(cached.count) bytes)")
            sendResponse(on: connection, contentType: "video/mp4", body: cached)
            requestSequentialProduction(startingAt: index + 1)
            return
        }
        cacheLock.unlock()

        // Start/advance sequential producer and wait for cache fill.
        requestSequentialProduction(startingAt: index)
        Task {
            await self.waitForCachedSegment(index: index, on: connection)
        }
    }

    /// Wait for a segment to appear in cache (another request is generating it).
    private func waitForCachedSegment(index: Int, on connection: NWConnection) async {
        // Poll cache every 100ms for up to 5 seconds.
        // If sequential production falls behind, fail over faster to direct generation.
        let waitStart = Date()
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)

            cacheLock.lock()
            if let cached = segmentCache[index] {
                cacheLock.unlock()
                let waitedMs = Int(Date().timeIntervalSince(waitStart) * 1000)
                print("[RemuxServer] Segment \(index) served from cache after wait (\(cached.count) bytes, wait=\(waitedMs)ms)")
                sendResponse(on: connection, contentType: "video/mp4", body: cached)
                return
            }
            cacheLock.unlock()
        }

        // Producer timed out. Kick producer again, then do one direct fallback attempt.
        requestSequentialProduction(startingAt: index)
        print("[RemuxServer] Segment \(index) wait timed out, generating directly")
        do {
            let generationStart = Date()
            let data = try await session.generateSegment(index: index)
            cacheSegment(index: index, data: data)
            let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
            print("[RemuxServer] Direct segment \(index) generated in \(elapsedMs)ms (\(data.count) bytes)")
            sendResponse(on: connection, contentType: "video/mp4", body: data)
        } catch {
            print("[RemuxServer] Segment \(index) generation failed: \(error)")
            sendError(on: connection, status: 500, message: "Segment generation failed")
        }
    }

    // MARK: - Sequential Producer

    private func requestSequentialProduction(startingAt index: Int) {
        guard index >= 0 else { return }
        producerLock.lock()
        let cappedIndex = min(index, max(sessionInfo.segments.count - 1, 0))
        producerMaxRequested = max(producerMaxRequested, cappedIndex)
        if producerCursor == nil {
            producerCursor = cappedIndex
        }
        if producerTask == nil {
            producerTask = Task { [weak self] in
                await self?.runSequentialProducer()
            }
        }
        producerLock.unlock()
    }

    private func runSequentialProducer() async {
        while !Task.isCancelled {
            let nextIndex: Int?
            producerLock.lock()
            let segmentCount = sessionInfo.segments.count
            let maxIndex = max(segmentCount - 1, 0)
            guard let cursor = producerCursor else {
                producerTask = nil
                producerLock.unlock()
                return
            }
            if segmentCount == 0 || cursor > maxIndex {
                producerTask = nil
                producerLock.unlock()
                return
            }
            let target = min(maxIndex, producerMaxRequested + producerLookahead)
            if cursor > target {
                producerTask = nil
                producerLock.unlock()
                return
            }
            nextIndex = cursor
            producerCursor = cursor + 1
            producerLock.unlock()

            guard let segmentIndex = nextIndex else { continue }

            cacheLock.lock()
            let alreadyCached = segmentCache[segmentIndex] != nil
            cacheLock.unlock()
            if alreadyCached { continue }

            do {
                let generationStart = Date()
                let data = try await session.generateSegment(index: segmentIndex)
                cacheSegment(index: segmentIndex, data: data)
                let elapsedMs = Int(Date().timeIntervalSince(generationStart) * 1000)
                print("[RemuxServer] Sequential segment \(segmentIndex) (\(data.count) bytes, elapsed=\(elapsedMs)ms)")
            } catch {
                print("[RemuxServer] Sequential segment \(segmentIndex) failed: \(error)")
            }
        }
        producerLock.lock()
        producerTask = nil
        producerLock.unlock()
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
                    print("[RemuxServer] Send error: \(error)")
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

extension NWConnection: @retroactive Hashable {
    public static func == (lhs: NWConnection, rhs: NWConnection) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
