//
//  PlaybackManager.swift
//  Rivulet
//
//  Manages AVPlayer instance, progress tracking, and Plex reporting
//

import AVFoundation
import AVKit
import Combine

@MainActor
class PlaybackManager: ObservableObject {
    static let shared = PlaybackManager()

    // MARK: - Published State
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var error: Error?
    @Published private(set) var currentStrategy: PlexNetworkManager.PlaybackStrategy = .directPlay

    // MARK: - Current Item Info
    private(set) var currentItem: PlexMetadata?
    private var ratingKey: String?
    private var serverURL: String?
    private var authToken: String?
    private var startOffset: Int?
    
    // MARK: - Playback Retry
    private var hasAttemptedFallback = false
    private var failedStrategies: Set<PlexNetworkManager.PlaybackStrategy> = []

    // MARK: - Observers
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var errorObservation: NSKeyValueObservation?
    private var playbackFailedObserver: NSObjectProtocol?

    // MARK: - Progress Reporting
    private var lastReportedTime: Double = 0
    private let reportingInterval: Double = 10 // Report every 10 seconds
    private let networkManager = PlexNetworkManager.shared

    private init() {}

    // MARK: - Playback Control

    /// Start playing a Plex media item
    func play(
        item: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: Int? = nil
    ) async {
        // Clean up previous playback
        stop()

        self.currentItem = item
        self.ratingKey = item.ratingKey
        self.serverURL = serverURL
        self.authToken = authToken
        self.startOffset = startOffset
        self.failedStrategies = []
        self.hasAttemptedFallback = false

        // Intelligently choose the best starting strategy based on media info
        let bestStrategy = selectBestStrategy(for: item)
        await playWithStrategy(bestStrategy, item: item)
    }
    
    /// Analyze media info and select the best playback strategy
    private func selectBestStrategy(for item: PlexMetadata) -> PlexNetworkManager.PlaybackStrategy {
        guard let media = item.Media?.first else {
            return .hlsTranscode
        }
        
        let container = (media.container ?? media.Part?.first?.container ?? "").lowercased()
        let videoCodec = (media.videoCodec ?? "").lowercased()
        let audioCodec = (media.audioCodec ?? "").lowercased()
        
        // Containers Apple TV can direct play
        let directPlayContainers = ["mp4", "m4v", "mov"]
        
        // Video codecs Apple TV supports
        let supportedVideoCodecs = ["h264", "hevc", "hvc1", "avc1"]
        
        // Audio codecs Apple TV supports natively
        let supportedAudioCodecs = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
        
        // Audio codecs that need transcoding (DTS family)
        let needsAudioTranscode = ["dts", "dca", "dca-ma", "truehd", "dtshd"]
        
        let canDirectPlayContainer = directPlayContainers.contains(container)
        let canDirectPlayVideo = supportedVideoCodecs.contains(where: { videoCodec.contains($0) })
        let canDirectPlayAudio = supportedAudioCodecs.contains(where: { audioCodec.contains($0) })
        let audioNeedsTranscode = needsAudioTranscode.contains(where: { audioCodec.contains($0) })
        
        print("""
        🎯 Strategy Selection:
           Container: \(container) → \(canDirectPlayContainer ? "✅ Direct Play OK" : "❌ Needs remux")
           Video: \(videoCodec) → \(canDirectPlayVideo ? "✅ Compatible" : "❌ Needs transcode")
           Audio: \(audioCodec) → \(canDirectPlayAudio ? "✅ Compatible" : audioNeedsTranscode ? "⚠️ Needs transcode" : "❌ Unknown")
        """)
        
        // Decision tree:
        // 1. If container is MP4/MOV AND video+audio are compatible → Direct Play
        // 2. If video is compatible but container/audio isn't → Direct Stream (remux + audio transcode if needed)
        // 3. Otherwise → Full HLS Transcode
        
        if canDirectPlayContainer && canDirectPlayVideo && canDirectPlayAudio {
            return .directPlay
        } else if canDirectPlayVideo {
            return .directStream
        } else {
            return .hlsTranscode
        }
    }
    
    /// Attempt playback with a specific strategy
    private func playWithStrategy(
        _ strategy: PlexNetworkManager.PlaybackStrategy,
        item: PlexMetadata
    ) async {
        guard let ratingKey = item.ratingKey,
              let serverURL = serverURL,
              let authToken = authToken else {
            self.error = PlaybackError.invalidURL
            return
        }
        
        // Get media info for direct play decisions
        let media = item.Media?.first
        let partKey = media?.Part?.first?.key
        let container = media?.container ?? media?.Part?.first?.container
        
        // Print comprehensive debug info
        printDebugInfo(item: item, strategy: strategy, serverURL: serverURL)
        
        // Build the streaming URL for this strategy
        guard let streamURL = networkManager.buildStreamURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            partKey: partKey,
            container: container,
            strategy: strategy,
            offsetMs: startOffset ?? item.viewOffset ?? 0
        ) else {
            // Try next strategy if this one fails to build URL (e.g., container not supported)
            await tryNextStrategy(after: strategy)
            return
        }

        self.currentStrategy = strategy
        
        // For transcode strategies, ping the URL first to start the transcode session
        if strategy == .directStream || strategy == .hlsTranscode {
            let sessionReady = await waitForTranscodeSession(url: streamURL, authToken: authToken)
            if !sessionReady {
                print("⚠️ Transcode session failed to start, trying next strategy...")
                await tryNextStrategy(after: strategy)
                return
            }
        }
        
        // Create player item with custom asset options for better compatibility
        let asset = AVURLAsset(url: streamURL, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier
            ],
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        
        // Set preferred configurations for HLS
        playerItem.preferredForwardBufferDuration = 60
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        
        let newPlayer = AVPlayer(playerItem: playerItem)

        // Configure player
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        
        // For direct play, we may need to seek after load
        // For HLS streams, the offset is in the URL

        self.player = newPlayer

        // Setup observers (including error handling for fallback)
        setupObservers(for: newPlayer)

        // For non-HLS streams (direct play), we need to seek after loading
        if strategy == .directPlay {
            let offset = startOffset ?? item.viewOffset
            if let offsetMs = offset, offsetMs > 0 {
                let offsetSeconds = Double(offsetMs) / 1000.0
                await seek(to: offsetSeconds)
            }
        }

        // Start playback
        newPlayer.play()
        isPlaying = true

        // Report start to Plex
        await reportProgress(state: .playing)
    }
    
    /// Try the next playback strategy after a failure
    private func tryNextStrategy(after failedStrategy: PlexNetworkManager.PlaybackStrategy) async {
        failedStrategies.insert(failedStrategy)
        
        // Smart fallback: go to the next more aggressive strategy
        // Direct Play → Direct Stream → HLS Transcode
        // But never go backwards (e.g., don't try Direct Play after Direct Stream failed)
        let nextStrategy: PlexNetworkManager.PlaybackStrategy?
        switch failedStrategy {
        case .directPlay:
            nextStrategy = .directStream
        case .directStream:
            nextStrategy = .hlsTranscode
        case .hlsTranscode:
            nextStrategy = nil
        }
        
        if let next = nextStrategy, !failedStrategies.contains(next) {
            print("""
            
            🔄 FALLBACK: \(failedStrategy.rawValue) → \(next.rawValue)
               Title: \(currentItem?.title ?? "Unknown")
            
            """)
            
            guard let item = currentItem else {
                self.error = PlaybackError.allStrategiesFailed
                return
            }
            
            // Clean up current player before retry
            cleanupPlayer()
            
            // Small delay before retry to avoid hammering the server
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            await playWithStrategy(next, item: item)
        } else {
            print("""
            
            ⛔ ALL STRATEGIES EXHAUSTED
               Failed strategies: \(failedStrategies.map { $0.rawValue }.joined(separator: ", "))
               Title: \(currentItem?.title ?? "Unknown")
            
            """)
            self.error = PlaybackError.allStrategiesFailed
        }
    }
    
    /// Handle playback failure and attempt fallback
    private func handlePlaybackError(_ playerItem: AVPlayerItem) async {
        guard !hasAttemptedFallback else { return }
        hasAttemptedFallback = true
        
        let itemError = playerItem.error
        print("PlaybackManager: Playback error: \(itemError?.localizedDescription ?? "unknown")")
        
        // Try next strategy
        await tryNextStrategy(after: currentStrategy)
    }
    
    /// Clean up current player without full stop
    private func cleanupPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        errorObservation?.invalidate()
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }
        
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        
        isPlaying = false
        isBuffering = false
        hasAttemptedFallback = false
    }

    /// Pause playback
    func pause() {
        player?.pause()
        isPlaying = false
        Task {
            await reportProgress(state: .paused)
        }
    }

    /// Resume playback
    func resume() {
        player?.play()
        isPlaying = true
        Task {
            await reportProgress(state: .playing)
        }
    }

    /// Toggle play/pause
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Seek to a specific time in seconds
    func seek(to seconds: Double) async {
        let time = CMTime(seconds: seconds, preferredTimescale: 1)
        await player?.seek(to: time)
        currentTime = seconds
    }

    /// Skip forward by specified seconds
    func skipForward(seconds: Double = 10) async {
        let newTime = min(currentTime + seconds, duration)
        await seek(to: newTime)
    }

    /// Skip backward by specified seconds
    func skipBackward(seconds: Double = 10) async {
        let newTime = max(currentTime - seconds, 0)
        await seek(to: newTime)
    }

    /// Stop playback and clean up
    func stop() {
        // Report stop to Plex
        Task {
            await reportProgress(state: .stopped)
        }

        // Remove all observers
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        errorObservation?.invalidate()
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }

        // Stop and clear player
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        // Reset state
        isPlaying = false
        currentTime = 0
        duration = 0
        isBuffering = false
        error = nil
        currentItem = nil
        ratingKey = nil
        serverURL = nil
        authToken = nil
        startOffset = nil
        lastReportedTime = 0
        failedStrategies = []
        hasAttemptedFallback = false
        currentStrategy = .directPlay
    }

    // MARK: - Progress

    /// Current progress as a percentage (0.0 - 1.0)
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    /// Formatted current time string
    var currentTimeFormatted: String {
        formatTime(currentTime)
    }

    /// Formatted duration string
    var durationFormatted: String {
        formatTime(duration)
    }

    /// Formatted remaining time string
    var remainingTimeFormatted: String {
        formatTime(duration - currentTime)
    }

    // MARK: - Private Methods

    private func setupObservers(for player: AVPlayer) {
        // Periodic time observer (every 0.5 seconds)
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds

                // Report progress periodically
                if abs(self.currentTime - self.lastReportedTime) >= self.reportingInterval {
                    self.lastReportedTime = self.currentTime
                    await self.reportProgress(state: self.isPlaying ? .playing : .paused)
                }
            }
        }

        // Observe player item status
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    let duration = item.duration.seconds
                    if duration.isFinite {
                        self.duration = duration
                    }
                    
                    // Log track information but don't fail on video track issues
                    // The simulator has issues with hardware video decoding
                    await self.logTrackInfo(item: item)
                    
                case .failed:
                    let errorDesc = item.error?.localizedDescription ?? "unknown"
                    let nsError = item.error as NSError?
                    print("""
                    
                    ❌ PLAYBACK FAILED
                       Strategy: \(self.currentStrategy.rawValue)
                       Error: \(errorDesc)
                       Domain: \(nsError?.domain ?? "unknown")
                       Code: \(nsError?.code ?? 0)
                       Title: \(self.currentItem?.title ?? "Unknown")
                    
                    """)
                    // Try fallback before reporting error
                    await self.handlePlaybackError(item)
                default:
                    break
                }
            }
        }

        // Observe buffering state
        bufferObservation = player.currentItem?.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.isBuffering = item.isPlaybackBufferEmpty
            }
        }
        
        // Observe error property directly
        errorObservation = player.currentItem?.observe(\.error, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let error = item.error else { return }
                print("PlaybackManager: Player item error: \(error.localizedDescription)")
                await self.handlePlaybackError(item)
            }
        }
        
        // Listen for playback failure notifications
        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let item = notification.object as? AVPlayerItem else { return }
                print("PlaybackManager: Failed to play to end time")
                await self.handlePlaybackError(item)
            }
        }
    }

    private func reportProgress(state: PlaybackState) async {
        guard let ratingKey = ratingKey,
              let serverURL = serverURL,
              let authToken = authToken else { return }

        let timeMs = Int(currentTime * 1000)
        let durationMs = Int(duration * 1000)

        do {
            try await networkManager.reportProgress(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                timeMs: timeMs,
                state: state.rawValue,
                duration: durationMs
            )
        } catch {
            print("PlaybackManager: Failed to report progress: \(error)")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }

        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    // MARK: - Transcode Session
    
    /// Wait for a transcode session to be ready by checking if segments are available
    private func waitForTranscodeSession(url: URL, authToken: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.addValue(authToken, forHTTPHeaderField: "X-Plex-Token")
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        
        // Try up to 5 times with longer delays to give transcoder time to start
        for attempt in 1...5 {
            do {
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    
                    if httpResponse.statusCode == 200 && data.count > 0 {
                        if let content = String(data: data, encoding: .utf8) {
                            // Check for valid HLS manifest with actual segments
                            let hasHeader = content.contains("#EXTM3U")
                            let hasSegments = content.contains(".ts") || content.contains(".m4s") || content.contains("#EXTINF")
                            let hasVariant = content.contains("#EXT-X-STREAM-INF")
                            
                            if hasHeader && (hasSegments || hasVariant) {
                                // For master playlists, we need to check the variant playlist too
                                if hasVariant && !hasSegments {
                                    // Extract first variant URL and check it
                                    let variantReady = await checkVariantPlaylist(masterContent: content, baseURL: url, authToken: authToken)
                                    if variantReady {
                                        return true
                                    } else {
                                    }
                                } else {
                                    return true
                                }
                            } else if hasHeader {
                            } else {
                                print("   ⚠️ Invalid manifest format")
                            }
                        }
                    } else if httpResponse.statusCode == 503 {
                    } else {
                        print("   ⚠️ Unexpected status: \(httpResponse.statusCode)")
                    }
                }
            } catch {
                print("   ❌ Request failed: \(error.localizedDescription)")
            }
            
            // Longer delays to give transcoder time (2s, 3s, 4s, 5s)
            if attempt < 5 {
                let delay = UInt64(attempt + 1) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        
        print("   ❌ Transcode session failed to produce valid segments")
        return false
    }
    
    /// Check a variant playlist for actual segments
    private func checkVariantPlaylist(masterContent: String, baseURL: URL, authToken: String) async -> Bool {
        // Extract the first variant URL from the master playlist
        let lines = masterContent.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if line.contains("#EXT-X-STREAM-INF") && index + 1 < lines.count {
                let variantPath = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if variantPath.isEmpty || variantPath.hasPrefix("#") { continue }
                
                // Build full variant URL
                let variantURL: URL?
                if variantPath.hasPrefix("http") {
                    variantURL = URL(string: variantPath)
                } else {
                    // Relative URL - construct from base
                    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                    let basePath = (components?.path ?? "").components(separatedBy: "/").dropLast().joined(separator: "/")
                    components?.path = basePath + "/" + variantPath
                    variantURL = components?.url
                }
                
                guard let url = variantURL else { continue }
                
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.addValue(authToken, forHTTPHeaderField: "X-Plex-Token")
                
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       let content = String(data: data, encoding: .utf8) {
                        let hasSegments = content.contains(".ts") || content.contains("#EXTINF")
                        return hasSegments
                    }
                } catch {
                    print("      Variant check failed: \(error.localizedDescription)")
                }
                
                break // Only check first variant
            }
        }
        return false
    }
    
    // MARK: - Track Validation
    
    /// Log track information for debugging (non-blocking)
    /// Note: HLS streams may not report tracks via the standard API
    private func logTrackInfo(item: AVPlayerItem) async {
        // For HLS streams, tracks aren't always enumerable via loadTracks()
        // The stream is working if we got here with readyToPlay status
        
        // Check the player item's tracks directly (works better for HLS)
        let tracks = item.tracks
        let videoTracks = tracks.filter { $0.assetTrack?.mediaType == .video }
        let audioTracks = tracks.filter { $0.assetTrack?.mediaType == .audio }
        
        if !tracks.isEmpty {
        } else {
            // For HLS, tracks may be dynamically loaded
            // Just note that we're streaming
        }
    }
    
    // MARK: - Debug Info
    
    /// Print comprehensive debug info for troubleshooting playback issues
    private func printDebugInfo(item: PlexMetadata, strategy: PlexNetworkManager.PlaybackStrategy, serverURL: String) {
        let separator = String(repeating: "=", count: 60)
        let media = item.Media?.first
        let part = media?.Part?.first
        
        var debugOutput = """
        
        \(separator)
        🎬 RIVULET PLAYBACK DEBUG INFO
        \(separator)
        
        📋 METADATA
           Title: \(item.title ?? "Unknown")
           Type: \(item.type ?? "Unknown")
           Rating Key: \(item.ratingKey ?? "N/A")
           Year: \(item.year.map { String($0) } ?? "N/A")
           Duration: \(item.durationFormatted ?? "N/A")
        
        🎯 PLAYBACK
           Strategy: \(strategy.rawValue)
           Server: \(serverURL)
           Resume Offset: \(startOffset ?? item.viewOffset ?? 0)ms
        
        """
        
        if let media = media {
            let bitrateStr: String
            if let bitrate = media.bitrate {
                if bitrate >= 1000 {
                    bitrateStr = String(format: "%.1f Mbps", Double(bitrate) / 1000.0)
                } else {
                    bitrateStr = "\(bitrate) kbps"
                }
            } else {
                bitrateStr = "N/A"
            }
            
            debugOutput += """
        📹 VIDEO
           Codec: \(media.videoCodec ?? "N/A")
           Resolution: \(media.videoResolution ?? "N/A")
           Dimensions: \(media.width ?? 0) x \(media.height ?? 0)
           Frame Rate: \(media.videoFrameRate ?? "N/A")
           Bitrate: \(bitrateStr)
        
        🔊 AUDIO
           Codec: \(media.audioCodec ?? "N/A")
           Channels: \(media.audioChannels.map { String($0) } ?? "N/A")
        
        📦 CONTAINER
           Format: \(media.container ?? "N/A")
        
        """
        }
        
        if let part = part {
            let fileName = (part.file ?? "").split(separator: "/").last.map(String.init) ?? "N/A"
            let fileSize: String
            if let size = part.size {
                fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            } else {
                fileSize = "N/A"
            }
            
            debugOutput += """
        📁 FILE
           Name: \(fileName)
           Size: \(fileSize)
           Part Key: \(part.key)
           Container: \(part.container ?? "N/A")
        
        """
        }
        
        // Apple TV compatibility assessment
        let videoCodec = media?.videoCodec?.lowercased() ?? ""
        let audioCodec = media?.audioCodec?.lowercased() ?? ""
        let container = media?.container?.lowercased() ?? ""
        
        let directPlayableVideoCodecs = ["h264", "hevc", "mpeg4"]
        let directPlayableAudioCodecs = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]
        let directPlayableContainers = ["mp4", "mov", "m4v", "mkv", "ts"]
        
        let videoOK = directPlayableVideoCodecs.contains(where: { videoCodec.contains($0) })
        let audioOK = directPlayableAudioCodecs.contains(where: { audioCodec.contains($0) })
        let containerOK = directPlayableContainers.contains(where: { container.contains($0) })
        
        debugOutput += """
        🍎 APPLE TV COMPATIBILITY
           Video Codec OK: \(videoOK ? "✅ YES" : "❌ NO") (\(videoCodec))
           Audio Codec OK: \(audioOK ? "✅ YES" : "❌ NO") (\(audioCodec))
           Container OK: \(containerOK ? "✅ YES" : "❌ NO") (\(container))
           Expected: \(videoOK && audioOK ? "Direct Play should work" : "May need transcoding")
        
        \(separator)
        
        """
        
    }
}

// MARK: - Playback State

enum PlaybackState: String {
    case playing
    case paused
    case stopped
    case buffering
}

// MARK: - Playback Error

enum PlaybackError: LocalizedError {
    case invalidURL
    case streamNotAvailable
    case allStrategiesFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to create streaming URL"
        case .streamNotAvailable:
            return "Stream is not available"
        case .allStrategiesFailed:
            return "Unable to play this file. All playback methods failed."
        case .unknown:
            return "An unknown error occurred"
        }
    }
}

