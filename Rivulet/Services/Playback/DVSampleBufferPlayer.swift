//
//  DVSampleBufferPlayer.swift
//  Rivulet
//
//  Alternative playback pipeline using AVSampleBufferDisplayLayer for Dolby Vision.
//  Bypasses AVPlayer's HLS parser by manually fetching fMP4 segments, demuxing them,
//  and feeding dvh1-tagged CMSampleBuffers directly to VideoToolbox.
//

import Foundation
import AVFoundation
import Combine
import CoreMedia
import Sentry

/// Player that uses AVSampleBufferDisplayLayer for DV content that AVPlayer rejects.
@MainActor
final class DVSampleBufferPlayer: ObservableObject {

    // MARK: - Display Layer (public for view binding)

    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let renderSynchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - Publishers

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private let tracksSubject = PassthroughSubject<Void, Never>()

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    // MARK: - State

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    var playbackRate: Float = 1.0

    // MARK: - Track Info (populated from demuxer)

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var currentAudioTrackId: Int?
    private(set) var currentSubtitleTrackId: Int?

    // MARK: - Private State

    private var fetcher: HLSSegmentFetcher?
    private var demuxer: FMP4Demuxer?
    private var downloadTask: Task<Void, Never>?
    private var enqueueTask: Task<Void, Never>?
    private var timeObserverTask: Task<Void, Never>?
    private var segmentBuffer: SegmentBuffer?
    private var currentSegmentIndex = 0
    private var isSeeking = false
    private var hasStartedFeeding = false
    private var needsRateRestoreAfterSeek = false
    private var needsInitialSync = false  // Wait to start sync until first video frame
    private var streamURL: URL?
    private var jitterStats = PlaybackJitterStats()

    // MARK: - Init

    init() {
        // Add renderers to synchronizer
        renderSynchronizer.addRenderer(displayLayer)
        renderSynchronizer.addRenderer(audioRenderer)

        // Configure display layer
        displayLayer.videoGravity = .resizeAspect

    }

    // MARK: - Playback Controls

    /// Load an HLS stream, parse its init segment, and prepare for playback.
    /// Protocol conformance wrapper - calls the extended version without profile conversion.
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        try await load(url: url, headers: headers, startTime: startTime, requiresProfileConversion: false)
    }

    /// Load an HLS stream, parse its init segment, and prepare for playback.
    /// - Parameters:
    ///   - url: HLS master playlist URL
    ///   - headers: Optional HTTP headers for authentication
    ///   - startTime: Optional start time for resume playback
    ///   - requiresProfileConversion: Enable DV Profile 7/8.6 → 8.1 conversion
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool) async throws {
        playbackStateSubject.send(.loading)

        // Ensure audio session is configured for playback
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "[DVPlayer]"
        )

        self.streamURL = url
        self.jitterStats.reset()
        let effectiveHeaders = headers ?? [:]
        let fetcher = HLSSegmentFetcher(masterURL: url, headers: effectiveHeaders)
        self.fetcher = fetcher

        // Load playlist and get init segment
        let initData = try await fetcher.loadPlaylist()

        // Demux init segment
        let demuxer = FMP4Demuxer()
        try demuxer.parseInitSegment(initData, forceDVH1: true)

        // Enable DV profile conversion if requested (for P7/P8.6 content)
        if requiresProfileConversion {
            demuxer.profileConverter = DoviProfileConverter()
        }

        self.demuxer = demuxer

        self.duration = fetcher.totalDuration

        print("🎬 [DVPlayer] Loaded: \(fetcher.segments.count) segments, duration=\(duration)s, dvh1=\(demuxer.hasDVFormatDescription)")

        // Populate track info using demuxer codec info (enables enrichment with Plex metadata)
        if demuxer.audioTrackID != nil {
            let codecName = demuxer.audioCodecType?.uppercased() ?? "Audio"
            audioTracks = [MediaTrack(
                id: 1,
                name: codecName,
                codec: demuxer.audioCodecType,
                isDefault: true
            )]
            currentAudioTrackId = 1
        }
        tracksSubject.send()

        // Log DV playback session to Sentry for diagnostics
        let breadcrumb = Breadcrumb(level: .info, category: "dv_playback")
        breadcrumb.message = "DV SampleBuffer Load"
        breadcrumb.data = [
            "stream_url": url.absoluteString,
            "stream_host": url.host ?? "unknown",
            "segment_count": fetcher.segments.count,
            "duration": duration,
            "has_dv_format": demuxer.hasDVFormatDescription,
            "video_codec": demuxer.videoCodecType ?? "unknown",
            "video_resolution": demuxer.videoResolution ?? "unknown",
            "audio_codec": demuxer.audioCodecType ?? "unknown",
            "has_audio": demuxer.audioTrackID != nil,
            "video_track_id": demuxer.videoTrackID as Any,
            "audio_track_id": demuxer.audioTrackID as Any,
            "init_segment_size": initData.count
        ]
        SentrySDK.addBreadcrumb(breadcrumb)

        // Determine starting segment
        if let startTime = startTime, startTime > 0 {
            currentSegmentIndex = fetcher.segmentIndex(forTime: startTime)
            // Don't set synchronizer time here — the first keyframe's PTS might differ
            // from startTime. We'll sync to the actual first video frame in the enqueue loop.
            needsInitialSync = true
            currentTime = startTime
            timeSubject.send(startTime)
        }

        playbackStateSubject.send(.ready)
        startTimeObserver()
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true

        // Don't set rate yet if we need to sync to first frame's PTS
        if !needsInitialSync {
            renderSynchronizer.rate = playbackRate
        }

        if !hasStartedFeeding {
            hasStartedFeeding = true
            startFeedingLoop()
        }

        playbackStateSubject.send(.playing)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        renderSynchronizer.rate = 0.0
        playbackStateSubject.send(.paused)
    }

    func stop() {
        isPlaying = false
        cancelFeedingPipeline()
        timeObserverTask?.cancel()
        timeObserverTask = nil
        hasStartedFeeding = false

        renderSynchronizer.rate = 0.0
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()

        playbackStateSubject.send(.idle)
    }

    /// Cancel download + enqueue tasks, safely draining the segment buffer.
    private func cancelFeedingPipeline() {
        // Cancel buffer first to unblock any waiting continuations
        if let buffer = segmentBuffer {
            Task { await buffer.cancel() }
        }
        downloadTask?.cancel()
        downloadTask = nil
        enqueueTask?.cancel()
        enqueueTask = nil
        segmentBuffer = nil
    }

    func seek(to time: TimeInterval) async {
        guard let fetcher = fetcher else { return }

        isSeeking = true
        jitterStats.reset()
        playbackStateSubject.send(.buffering)

        // Cancel buffer first to unblock waiting continuations, then cancel tasks
        if let buffer = segmentBuffer {
            await buffer.cancel()
        }
        downloadTask?.cancel()
        enqueueTask?.cancel()
        let oldDownload = downloadTask
        let oldEnqueue = enqueueTask
        downloadTask = nil
        enqueueTask = nil
        segmentBuffer = nil
        await oldDownload?.value
        await oldEnqueue?.value

        // Flush buffers
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()

        // Find target segment
        currentSegmentIndex = fetcher.segmentIndex(forTime: time)

        // Set the synchronizer timebase to the target time, paused.
        // Don't start advancing until the first samples are enqueued,
        // otherwise the synchronizer runs ahead during segment download.
        let targetCMTime = CMTime(seconds: time, preferredTimescale: 90000)
        renderSynchronizer.setRate(0, time: targetCMTime)

        // Update current time immediately
        currentTime = time
        timeSubject.send(time)

        isSeeking = false
        hasStartedFeeding = true
        needsInitialSync = false  // Seek has its own sync handling
        needsRateRestoreAfterSeek = isPlaying

        // Always restart feeding so a seek while paused shows the new frame
        startFeedingLoop()
    }

    func seekRelative(by seconds: TimeInterval) async {
        let newTime = max(0, min(currentTime + seconds, duration))
        await seek(to: newTime)
    }

    // MARK: - Track Selection (stubs - single track for now)

    func selectAudioTrack(id: Int) {
        currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        currentSubtitleTrackId = id
    }

    func prepareForReuse() {
        stop()
        fetcher = nil
        demuxer = nil
        currentSegmentIndex = 0
        needsInitialSync = false
    }

    // MARK: - Private: Feeding Pipeline (Producer/Consumer)

    private func startFeedingLoop() {
        downloadTask?.cancel()
        enqueueTask?.cancel()

        // Create a bounded buffer: downloader produces, enqueuer consumes.
        // Buffer holds up to 3 downloaded segments so downloading stays ahead.
        let buffer = SegmentBuffer(capacity: 3)
        self.segmentBuffer = buffer

        let startIndex = currentSegmentIndex

        // Producer: downloads segments sequentially into the buffer
        downloadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let fetcher = await self.fetcher
            guard let fetcher = fetcher else { return }
            let segmentCount = fetcher.segments.count

            for index in startIndex..<segmentCount {
                guard !Task.isCancelled else { break }

                // Retry with exponential backoff: 1s, 2s, 4s
                let maxRetries = 3
                var lastError: Error?

                for attempt in 0...maxRetries {
                    guard !Task.isCancelled else { break }

                    do {
                        let data = try await fetcher.fetchSegment(at: index)
                        guard !Task.isCancelled else { break }
                        let accepted = await buffer.put(index: index, data: data)
                        guard accepted else { break }
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        if attempt < maxRetries && !Task.isCancelled {
                            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                            print("🎬 [DVPlayer] ⚠️ Segment \(index) download failed (attempt \(attempt + 1)/\(maxRetries + 1)): \(error). Retrying...")
                            try? await Task.sleep(nanoseconds: delay)
                        }
                    }
                }

                if let error = lastError {
                    if !Task.isCancelled {
                        print("🎬 [DVPlayer] Download error segment \(index) after \(maxRetries + 1) attempts: \(error)")

                        let streamURL = await self.streamURL
                        let demuxer = await self.demuxer
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "dv_player", key: "component")
                            scope.setTag(value: "segment_download", key: "error_type")
                            scope.setTag(value: demuxer?.videoCodecType ?? "unknown", key: "video_codec")
                            scope.setExtra(value: index, key: "segment_index")
                            scope.setExtra(value: segmentCount, key: "segment_count")
                            scope.setExtra(value: maxRetries + 1, key: "attempts")
                            scope.setExtra(value: streamURL?.host ?? "unknown", key: "stream_host")
                            scope.setExtra(value: demuxer?.videoResolution ?? "unknown", key: "video_resolution")
                            scope.setExtra(value: demuxer?.audioCodecType ?? "unknown", key: "audio_codec")
                        }

                        await buffer.putError(error)
                    }
                    return
                }
            }
            await buffer.finish()
        }

        // Consumer: reads from buffer, demuxes, enqueues samples
        enqueueTask = Task { [weak self] in
            guard let self = self else { return }
            await self.enqueueLoop(buffer: buffer, startIndex: startIndex)
        }
    }

    private func enqueueLoop(buffer: SegmentBuffer, startIndex: Int) async {
        guard let fetcher = fetcher, let demuxer = demuxer else { return }

        let segmentCount = fetcher.segments.count
        var index = startIndex

        while index < segmentCount && !Task.isCancelled {
            // Show buffering spinner while waiting for download
            let bufferWasEmpty = await buffer.isEmpty
            if bufferWasEmpty {
                playbackStateSubject.send(.buffering)
                jitterStats.recordBufferUnderrun()
            }

            // Wait for the next segment from the download buffer
            let result = await buffer.take()

            if bufferWasEmpty {
                jitterStats.recordBufferRecovery()
            }

            switch result {
            case .segment(let segIndex, let segmentData):
                guard !Task.isCancelled else { return }

                do {
                    let samples = try demuxer.parseMediaSegment(segmentData)

                    guard !Task.isCancelled else { return }

                    // Restore playing state now that we have data to enqueue
                    if isPlaying {
                        playbackStateSubject.send(.playing)
                    }

                    // Log detailed timing only for the first segment
                    if segIndex == startIndex, !samples.isEmpty {
                        let firstVideo = samples.first(where: { $0.isVideo })
                        let firstAudio = samples.first(where: { !$0.isVideo })
                        let videoCount = samples.filter { $0.isVideo }.count
                        let audioCount = samples.filter { !$0.isVideo }.count
                        let syncTime = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                    }

                    // Enqueue samples, restoring rate after the first video sample post-seek
                    var enqueuedVideo = 0
                    var enqueuedAudio = 0
                    for sample in samples {
                        guard !Task.isCancelled else { return }

                        do {
                            let sampleBuffer = try demuxer.createSampleBuffer(from: sample)

                            if sample.isVideo {
                                jitterStats.recordVideoPTS(CMTimeGetSeconds(sample.pts))
                                let isFirstVideoSample = enqueuedVideo == 0

                                // IMPORTANT: Set sync time BEFORE enqueueing to avoid deadlock.
                                // The enqueue pacing logic waits for sync to catch up, but sync
                                // won't advance if rate is still 0 from seek. We must set the
                                // rate first so the pacing check passes or the sync advances.
                                if needsInitialSync {
                                    needsInitialSync = false
                                    renderSynchronizer.setRate(isPlaying ? playbackRate : 0, time: sample.pts)
                                    let ptsSeconds = CMTimeGetSeconds(sample.pts)
                                    currentTime = ptsSeconds
                                    timeSubject.send(ptsSeconds)
                                } else if needsRateRestoreAfterSeek {
                                    needsRateRestoreAfterSeek = false
                                    renderSynchronizer.setRate(playbackRate, time: sample.pts)
                                } else if !isPlaying && isFirstVideoSample {
                                    // Paused seek: set time so the frame displays, keep rate at 0
                                    renderSynchronizer.setRate(0, time: sample.pts)
                                }

                                await enqueueVideoSample(sampleBuffer)
                                enqueuedVideo += 1

                                // Handle paused seek: return after enqueue so frame is displayed
                                if !isPlaying && isFirstVideoSample {
                                    playbackStateSubject.send(.paused)
                                    return
                                }
                            } else {
                                await enqueueAudioSample(sampleBuffer)
                                enqueuedAudio += 1
                            }
                        } catch {
                            print("🎬 [DVPlayer] Failed to create sample buffer: \(error)")
                        }
                    }

                    // Log errors from display layer / audio renderer
                    if let layerError = displayLayer.error {
                        print("🎬 [DVPlayer] ⚠️ Display layer error: \(layerError)")
                        SentrySDK.capture(error: layerError) { scope in
                            scope.setTag(value: "dv_player", key: "component")
                            scope.setTag(value: "display_layer", key: "error_type")
                            scope.setTag(value: demuxer.videoCodecType ?? "unknown", key: "video_codec")
                            scope.setExtra(value: segIndex, key: "segment_index")
                            scope.setExtra(value: demuxer.videoResolution ?? "unknown", key: "video_resolution")
                            scope.setExtra(value: self.streamURL?.host ?? "unknown", key: "stream_host")
                        }
                    }
                    if let audioError = audioRenderer.error {
                        print("🎬 [DVPlayer] ⚠️ Audio renderer error: \(audioError)")
                        SentrySDK.capture(error: audioError) { scope in
                            scope.setTag(value: "dv_player", key: "component")
                            scope.setTag(value: "audio_renderer", key: "error_type")
                            scope.setTag(value: demuxer.audioCodecType ?? "unknown", key: "audio_codec")
                            scope.setExtra(value: segIndex, key: "segment_index")
                            scope.setExtra(value: self.streamURL?.host ?? "unknown", key: "stream_host")
                        }
                    }

                    // Update buffered time
                    if segIndex < segmentCount {
                        let segment = fetcher.segments[segIndex]
                        bufferedTime = segment.startTime + segment.duration
                    }

                    currentSegmentIndex = segIndex + 1
                    index = segIndex + 1

                } catch {
                    if !Task.isCancelled {
                        print("🎬 [DVPlayer] Segment \(segIndex) parse error: \(error)")

                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "dv_player", key: "component")
                            scope.setTag(value: "segment_demux", key: "error_type")
                            scope.setTag(value: demuxer.videoCodecType ?? "unknown", key: "video_codec")
                            scope.setExtra(value: segIndex, key: "segment_index")
                            scope.setExtra(value: segmentData.count, key: "segment_bytes")
                            scope.setExtra(value: self.streamURL?.host ?? "unknown", key: "stream_host")
                            scope.setExtra(value: demuxer.videoResolution ?? "unknown", key: "video_resolution")
                            scope.setExtra(value: demuxer.audioCodecType ?? "unknown", key: "audio_codec")
                        }

                        errorSubject.send(.networkError(error.localizedDescription))
                    }
                    return
                }

            case .error(let error):
                if !Task.isCancelled {
                    print("🎬 [DVPlayer] Segment download error: \(error)")
                    // Note: Sentry capture already done in download task retry logic
                    errorSubject.send(.networkError(error.localizedDescription))
                }
                return

            case .finished:
                break

            case .cancelled:
                return
            }
        }

        // Reached end of content
        if !Task.isCancelled && currentSegmentIndex >= segmentCount {
            isPlaying = false
            playbackStateSubject.send(.ended)
            // Log conversion stats if converter was used
            if let converter = demuxer.profileConverter {
            } else {
            }
        }
    }

    /// Enqueue a video sample buffer, pacing to stay within lookahead window
    private func enqueueVideoSample(_ sampleBuffer: CMSampleBuffer) async {
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = CMTimeGetSeconds(samplePTS)

        // Pace enqueue: wait if sample is too far ahead of synchronizer time.
        // This prevents flooding the display layer buffer and causing long stalls.
        // Allow 2 seconds of lookahead for smooth playback runway.
        let maxLookahead: TimeInterval = 2.0

        while !Task.isCancelled {
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let ahead = sampleTime - syncTime

            // If we're within lookahead window or sync hasn't started, proceed
            if ahead <= maxLookahead || syncTime < 0.1 {
                break
            }

            // Sleep for a fraction of the excess time, then re-check
            let sleepTime = min(ahead - maxLookahead, 0.1) // max 100ms sleep
            try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
        }

        // Now wait for display layer readiness (should be brief with proper pacing)
        if !displayLayer.isReadyForMoreMediaData {
            let stallStart = CFAbsoluteTimeGetCurrent()
            while !displayLayer.isReadyForMoreMediaData && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }
            let stallDuration = CFAbsoluteTimeGetCurrent() - stallStart
            jitterStats.recordEnqueueStall(duration: stallDuration)
        }

        guard !Task.isCancelled else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    /// Enqueue an audio sample buffer, waiting if the renderer isn't ready
    private func enqueueAudioSample(_ sampleBuffer: CMSampleBuffer) async {
        while !audioRenderer.isReadyForMoreMediaData && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }

        guard !Task.isCancelled else { return }
        audioRenderer.enqueue(sampleBuffer)
    }

    // MARK: - Private: Time Observer

    private func startTimeObserver() {
        timeObserverTask?.cancel()

        timeObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

                guard let self = self, !Task.isCancelled else { return }

                let time = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                let rate = self.renderSynchronizer.rate
                let playing = self.isPlaying

                if time.isFinite && time >= 0 {
                    await MainActor.run {
                        self.currentTime = time
                        self.timeSubject.send(time)
                        self.jitterStats.recordSynchronizerTime(time, isPlaying: playing, rate: rate)
                        _ = self.jitterStats.reportIfNeeded()
                    }
                }
            }
        }
    }
}

// MARK: - Playback Jitter Stats

/// Lightweight diagnostics for detecting micro-jitters and stutters.
/// Tracks PTS gaps between consecutive video frames, buffer underruns,
/// and enqueue stalls. Logs a summary periodically.
struct PlaybackJitterStats {
    /// Expected frame duration based on content framerate
    private(set) var expectedFrameDuration: TimeInterval = 0

    // Frame timing
    private var lastVideoPTS: TimeInterval = -1
    private var totalVideoFrames: Int = 0
    private var droppedFrameGaps: Int = 0        // PTS gaps > 1.5x expected duration
    private var maxPTSGap: TimeInterval = 0
    private var ptsGapSum: TimeInterval = 0
    private var ptsGapSumSquared: TimeInterval = 0  // for std deviation
    private var minPTS: TimeInterval = .infinity   // for fps detection via PTS range
    private var maxPTS: TimeInterval = -.infinity  // for fps detection via PTS range

    // Buffer health
    private(set) var bufferUnderruns: Int = 0     // times enqueue loop found buffer empty
    private var lastUnderrunTime: CFAbsoluteTime = 0
    private var totalUnderrunDuration: TimeInterval = 0

    // Enqueue stalls (display layer not ready)
    private(set) var videoEnqueueStalls: Int = 0  // times we had to wait for isReadyForMoreMediaData
    private var maxStallDuration: TimeInterval = 0
    private var totalStallDuration: TimeInterval = 0

    // Synchronizer drift tracking
    private var lastSyncCheckWallTime: CFAbsoluteTime = 0
    private var lastSyncCheckPlaybackTime: TimeInterval = 0
    private var syncDriftSamples: [Double] = []  // drift rate samples (sync advance / wall advance)
    private var maxSyncDrift: Double = 0         // max deviation from 1.0 rate
    private var syncDriftAlerts: Int = 0         // significant drift events
    private var consecutiveDriftCount: Int = 0   // consecutive samples with same drift direction
    private var lastDriftDirection: Int = 0      // -1 = slow, 0 = normal, +1 = fast

    // Reporting
    private var lastReportTime: CFAbsoluteTime = 0
    private var lastReportFrameCount: Int = 0
    private static let reportIntervalSeconds: TimeInterval = 30

    /// Reset all stats (call on seek or new load)
    mutating func reset() {
        expectedFrameDuration = 0
        lastVideoPTS = -1
        totalVideoFrames = 0
        droppedFrameGaps = 0
        maxPTSGap = 0
        ptsGapSum = 0
        ptsGapSumSquared = 0
        minPTS = .infinity
        maxPTS = -.infinity
        bufferUnderruns = 0
        lastUnderrunTime = 0
        totalUnderrunDuration = 0
        videoEnqueueStalls = 0
        maxStallDuration = 0
        totalStallDuration = 0
        lastSyncCheckWallTime = 0
        lastSyncCheckPlaybackTime = 0
        syncDriftSamples = []
        maxSyncDrift = 0
        syncDriftAlerts = 0
        consecutiveDriftCount = 0
        lastDriftDirection = 0
        lastReportTime = CFAbsoluteTimeGetCurrent()
        lastReportFrameCount = 0
    }

    /// Record a video frame's PTS. Detects gaps indicating potential stutter.
    mutating func recordVideoPTS(_ pts: TimeInterval) {
        totalVideoFrames += 1

        // Track PTS range for fps detection (works regardless of B-frame ordering)
        if pts < minPTS { minPTS = pts }
        if pts > maxPTS { maxPTS = pts }

        // Detect fps after 100 frames using PTS range / frame count
        // This is immune to B-frame decode ordering issues
        if expectedFrameDuration == 0 && totalVideoFrames == 100 && maxPTS > minPTS {
            let ptsRange = maxPTS - minPTS
            expectedFrameDuration = ptsRange / Double(totalVideoFrames - 1)
            let detectedFPS = 1.0 / expectedFrameDuration
        }

        guard lastVideoPTS >= 0 else {
            lastVideoPTS = pts
            return
        }

        let gap = pts - lastVideoPTS
        lastVideoPTS = pts

        // Skip negative/zero gaps (B-frame reordering or seek)
        guard gap > 0 else { return }

        ptsGapSum += gap
        ptsGapSumSquared += gap * gap

        if gap > maxPTSGap {
            maxPTSGap = gap
        }

        // Flag gaps significantly larger than expected (potential stutter)
        // Use 24x threshold (~1 second for 24fps) to ignore normal GOP structure (8-frame jumps)
        // Only alert on truly anomalous multi-second gaps indicating real problems
        if expectedFrameDuration > 0 && gap > expectedFrameDuration * 24.0 {
            droppedFrameGaps += 1
            print("📊 [Jitter] ⚠️ Large PTS gap: \(String(format: "%.0f", gap * 1000))ms at frame \(totalVideoFrames) (expected ~\(String(format: "%.0f", expectedFrameDuration * 1000))ms)")
        }
    }

    /// Record a buffer underrun (enqueue loop found buffer empty while playing)
    mutating func recordBufferUnderrun() {
        bufferUnderruns += 1
        lastUnderrunTime = CFAbsoluteTimeGetCurrent()
    }

    /// Record end of buffer underrun (segment arrived)
    mutating func recordBufferRecovery() {
        if lastUnderrunTime > 0 {
            totalUnderrunDuration += CFAbsoluteTimeGetCurrent() - lastUnderrunTime
            lastUnderrunTime = 0
        }
    }

    /// Record an enqueue stall with its wall-clock duration
    mutating func recordEnqueueStall(duration: TimeInterval) {
        videoEnqueueStalls += 1
        totalStallDuration += duration
        if duration > maxStallDuration {
            maxStallDuration = duration
        }
        // Log significant stalls (>100ms) immediately - these likely cause visible stutters
        if duration > 0.1 {
            print("📊 [Jitter] ⏱️ Enqueue stall: \(String(format: "%.0f", duration * 1000))ms (frame \(totalVideoFrames))")
        }
    }

    /// Record synchronizer drift - checks if playback clock advances smoothly relative to wall time.
    /// Call periodically from time observer. Returns drift rate (1.0 = perfect, <1.0 = slow, >1.0 = fast).
    mutating func recordSynchronizerTime(_ syncTime: TimeInterval, isPlaying: Bool, rate: Float) {
        let now = CFAbsoluteTimeGetCurrent()

        // Skip if not playing or rate is 0
        guard isPlaying && rate > 0 else {
            lastSyncCheckWallTime = 0
            lastSyncCheckPlaybackTime = 0
            return
        }

        // First sample - just record baseline
        guard lastSyncCheckWallTime > 0 else {
            lastSyncCheckWallTime = now
            lastSyncCheckPlaybackTime = syncTime
            return
        }

        let wallDelta = now - lastSyncCheckWallTime
        let syncDelta = syncTime - lastSyncCheckPlaybackTime

        // Skip if not enough time passed (< 200ms)
        guard wallDelta > 0.2 else { return }

        // Calculate drift rate: how fast sync is advancing relative to wall time * rate
        // Perfect playback at rate 1.0 should give driftRate = 1.0
        let expectedSyncDelta = wallDelta * Double(rate)
        let driftRate = syncDelta / expectedSyncDelta

        // Track samples for statistics
        syncDriftSamples.append(driftRate)
        if syncDriftSamples.count > 50 {
            syncDriftSamples.removeFirst()
        }

        let deviation = abs(driftRate - 1.0)
        if deviation > maxSyncDrift {
            maxSyncDrift = deviation
        }

        // Track drift direction for sustained drift detection
        let currentDirection: Int
        if driftRate < 0.95 {
            currentDirection = -1  // running slow
        } else if driftRate > 1.05 {
            currentDirection = 1   // running fast
        } else {
            currentDirection = 0   // normal
        }

        // Only alert on sustained drift (3+ consecutive samples in same direction)
        // This filters out momentary clock jitter from measurement timing
        if currentDirection != 0 && currentDirection == lastDriftDirection {
            consecutiveDriftCount += 1
            if consecutiveDriftCount >= 3 {
                syncDriftAlerts += 1
                let direction = currentDirection < 0 ? "slow" : "fast"
                print("📊 [Jitter] ⚠️ Sustained sync drift (\(direction)): \(String(format: "%.1f", driftRate * 100))% (wall: \(String(format: "%.0f", wallDelta * 1000))ms, sync: \(String(format: "%.0f", syncDelta * 1000))ms)")
                consecutiveDriftCount = 0  // Reset after alerting
            }
        } else {
            consecutiveDriftCount = currentDirection != 0 ? 1 : 0
        }
        lastDriftDirection = currentDirection

        lastSyncCheckWallTime = now
        lastSyncCheckPlaybackTime = syncTime
    }

    /// Check if it's time for a periodic report. If so, log and return true.
    mutating func reportIfNeeded() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReportTime >= Self.reportIntervalSeconds else { return false }

        let framesSinceReport = totalVideoFrames - lastReportFrameCount
        let avgGap = framesSinceReport > 1 ? ptsGapSum / Double(framesSinceReport - 1) : 0
        // Use detected fps, or estimate from average gap if still detecting
        let fps: Double
        if expectedFrameDuration > 0 {
            fps = 1.0 / expectedFrameDuration
        } else if avgGap > 0 {
            fps = 1.0 / avgGap
        } else {
            fps = 0
        }

        // Compute PTS gap std deviation
        let n = Double(max(framesSinceReport - 1, 1))
        let variance = max(0, (ptsGapSumSquared / n) - (avgGap * avgGap))
        let stdDev = sqrt(variance)

        // Compute sync drift statistics
        var syncAvg: Double = 1.0
        var syncStdDev: Double = 0
        if !syncDriftSamples.isEmpty {
            syncAvg = syncDriftSamples.reduce(0, +) / Double(syncDriftSamples.count)
            let syncVariance = syncDriftSamples.reduce(0) { $0 + ($1 - syncAvg) * ($1 - syncAvg) } / Double(syncDriftSamples.count)
            syncStdDev = sqrt(syncVariance)
        }

        let hasIssues = droppedFrameGaps > 0 || bufferUnderruns > 0 || videoEnqueueStalls > 0 || syncDriftAlerts > 0
        let icon = hasIssues ? "⚠️" : "✅"

        print("📊 [Jitter] \(icon) \(totalVideoFrames) frames | \(String(format: "%.1f", fps))fps | " +
              "gaps: avg=\(String(format: "%.1f", avgGap * 1000))ms σ=\(String(format: "%.2f", stdDev * 1000))ms max=\(String(format: "%.1f", maxPTSGap * 1000))ms | " +
              "drops: \(droppedFrameGaps) | underruns: \(bufferUnderruns) (\(String(format: "%.1f", totalUnderrunDuration * 1000))ms) | " +
              "stalls: \(videoEnqueueStalls) (max=\(String(format: "%.1f", maxStallDuration * 1000))ms total=\(String(format: "%.1f", totalStallDuration * 1000))ms) | " +
              "sync: \(String(format: "%.1f", syncAvg * 100))%±\(String(format: "%.1f", syncStdDev * 100))% alerts:\(syncDriftAlerts)")

        lastReportTime = now
        lastReportFrameCount = totalVideoFrames
        return true
    }
}

// MARK: - Segment Buffer (Producer/Consumer)

/// Thread-safe bounded buffer for downloaded segments.
/// Producer (downloader) waits when full; consumer (enqueuer) waits when empty.
/// Call `cancel()` before discarding to safely resume any pending continuations.
private actor SegmentBuffer {
    enum Item {
        case segment(index: Int, data: Data)
        case error(Error)
        case finished
        case cancelled
    }

    let capacity: Int
    private var items: [Item] = []
    private var isCancelled = false
    private var isFinished = false
    private var producerContinuation: CheckedContinuation<Bool, Never>?  // returns false if cancelled
    private var consumerContinuation: CheckedContinuation<Item, Never>?

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Cancel the buffer, waking any waiting producer/consumer.
    func cancel() {
        isCancelled = true
        if let producer = producerContinuation {
            producerContinuation = nil
            producer.resume(returning: false)
        }
        if let consumer = consumerContinuation {
            consumerContinuation = nil
            consumer.resume(returning: .cancelled)
        }
    }

    /// Producer: add a downloaded segment. Waits if buffer is full.
    /// Returns false if the buffer was cancelled while waiting.
    func put(index: Int, data: Data) async -> Bool {
        // Wait until there's space or we're cancelled
        while items.count >= capacity && !isCancelled {
            let shouldContinue = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                producerContinuation = cont
            }
            if !shouldContinue { return false }
        }

        guard !isCancelled else { return false }

        let item = Item.segment(index: index, data: data)

        // If a consumer is waiting, deliver directly
        if let consumer = consumerContinuation {
            consumerContinuation = nil
            consumer.resume(returning: item)
        } else {
            items.append(item)
        }
        return true
    }

    /// Producer: signal an error
    func putError(_ error: Error) {
        guard !isCancelled else { return }
        let item = Item.error(error)
        if let consumer = consumerContinuation {
            consumerContinuation = nil
            consumer.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    /// Producer: signal no more segments
    func finish() {
        isFinished = true
        if let consumer = consumerContinuation {
            consumerContinuation = nil
            consumer.resume(returning: .finished)
        }
    }

    /// Consumer: take the next item. Waits if buffer is empty.
    func take() async -> Item {
        guard !isCancelled else { return .cancelled }

        if let item = items.first {
            items.removeFirst()
            // Wake producer if it was waiting for space
            if let producer = producerContinuation {
                producerContinuation = nil
                producer.resume(returning: true)
            }
            return item
        }

        if isFinished {
            return .finished
        }

        // Wait for producer to add something
        return await withCheckedContinuation { (cont: CheckedContinuation<Item, Never>) in
            consumerContinuation = cont
        }
    }
}

// MARK: - PlayerProtocol Conformance

extension DVSampleBufferPlayer: PlayerProtocol {}
