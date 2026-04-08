//
//  HLSPipeline.swift
//  Rivulet
//
//  HLS ingestion pipeline using HLSSegmentFetcher + FMP4Demuxer → SampleBufferRenderer.
//  Used for content requiring server-side processing:
//    - DTS/TrueHD audio (Plex transcodes audio, copies video)
//    - Live TV (already HLS from Plex/IPTV)
//    - Fallback when direct play fails
//
//  Shares the same renderer path as direct play so all playback goes through Rivulet.
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import Sentry

/// HLS pipeline: HLSSegmentFetcher → FMP4Demuxer → CMSampleBuffer → SampleBufferRenderer
@MainActor
final class HLSPipeline {

    // MARK: - Dependencies

    private let renderer: SampleBufferRenderer

    // MARK: - Private Components

    private var fetcher: HLSSegmentFetcher?
    private var demuxer: FMP4Demuxer?
    private var segmentBuffer: SegmentBuffer?

    // MARK: - Tasks

    private var downloadTask: Task<Void, Never>?
    private var enqueueTask: Task<Void, Never>?

    // MARK: - State

    private(set) var state: PipelineState = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0

    private var currentSegmentIndex = 0
    private var isPlaying = false
    private var playbackRate: Float = 1.0
    private var isSeeking = false
    private var hasStartedFeeding = false
    private var needsRateRestoreAfterSeek = false
    private var needsInitialSync = false
    private var streamURL: URL?
    private var lastRequestedSeekTime: TimeInterval = -1
    private var lastSeekWallTime: CFAbsoluteTime = 0
    private var isAudioRecoveryInProgress = false
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0

    // MARK: - Callbacks

    var onStateChange: ((PipelineState) -> Void)?
    var onError: ((Error) -> Void)?
    var onEndOfStream: (() -> Void)?

    // MARK: - Track Info

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []

    // MARK: - Init

    init(renderer: SampleBufferRenderer) {
        self.renderer = renderer
    }

    // MARK: - Load

    /// Load an HLS stream for playback.
    /// - Parameters:
    ///   - url: HLS master playlist URL
    ///   - headers: HTTP headers for authentication
    ///   - startTime: Optional resume position
    ///   - requiresProfileConversion: Enable DV P7/P8.6 → P8.1 conversion
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool = false) async throws {
        state = .loading
        onStateChange?(.loading)
        self.streamURL = url

        renderer.jitterStats.reset()

        let effectiveHeaders = headers ?? [:]
        let fetcher = HLSSegmentFetcher(masterURL: url, headers: effectiveHeaders)
        self.fetcher = fetcher

        // Load playlist and get init segment
        let initData = try await fetcher.loadPlaylist()

        // Demux init segment
        let demuxer = FMP4Demuxer()
        try demuxer.parseInitSegment(initData, forceDVH1: true)

        // Enable DV profile conversion if requested
        if requiresProfileConversion {
            demuxer.profileConverter = DoviProfileConverter()
        }

        self.demuxer = demuxer
        self.duration = fetcher.totalDuration

        // Populate track info
        if demuxer.audioTrackID != nil {
            let codecName = demuxer.audioCodecType?.uppercased() ?? "Audio"
            audioTracks = [MediaTrack(
                id: 1,
                name: codecName,
                codec: demuxer.audioCodecType,
                isDefault: true
            )]
        }

        // Handle start time
        if let startTime = startTime, startTime > 0 {
            currentSegmentIndex = fetcher.segmentIndex(forTime: startTime)
            needsInitialSync = true
        }

        state = .ready
        onStateChange?(.ready)

        // Log session
        let breadcrumb = Breadcrumb(level: .info, category: "hls_pipeline")
        breadcrumb.message = "HLS Pipeline Load"
        breadcrumb.data = [
            "stream_url": url.absoluteString,
            "stream_host": url.host ?? "unknown",
            "segment_count": fetcher.segments.count,
            "duration": duration,
            "has_dv": demuxer.hasDVFormatDescription,
            "video_codec": demuxer.videoCodecType ?? "unknown",
            "audio_codec": demuxer.audioCodecType ?? "unknown",
            "profile_conversion": requiresProfileConversion
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // MARK: - Playback Control

    func start(rate: Float = 1.0) {
        guard state == .ready || state == .paused else { return }
        isPlaying = true
        playbackRate = rate

        if !needsInitialSync {
            renderer.resumeAudio()
            renderer.setRate(rate)
        }

        if !hasStartedFeeding {
            hasStartedFeeding = true
            startFeedingLoop()
        }

        state = .running
        onStateChange?(.running)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        renderer.pauseAudio()
        renderer.setRate(0)
        state = .paused
        onStateChange?(.paused)
    }

    func resume() {
        guard !isPlaying, state == .paused else { return }
        isPlaying = true
        renderer.resumeAudio()
        renderer.setRate(playbackRate)
        state = .running
        onStateChange?(.running)
    }

    func stop() {
        isPlaying = false
        cancelFeedingPipeline()
        hasStartedFeeding = false
        state = .idle
        onStateChange?(.idle)
    }

    /// Deterministic shutdown that cancels and awaits feeding tasks.
    func shutdown() async {
        isPlaying = false

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

        hasStartedFeeding = false
        state = .idle
        onStateChange?(.idle)
    }

    // MARK: - Seek

    func seek(to time: TimeInterval, isPlaying: Bool, force: Bool = false) async {
        guard let fetcher = fetcher else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let currentTime = renderer.currentTime
        let deltaFromCurrent = abs(time - currentTime)
        let deltaFromLastRequest = lastRequestedSeekTime >= 0 ? abs(time - lastRequestedSeekTime) : .infinity

        if !force, now - lastSeekWallTime < 0.2 && deltaFromLastRequest < 0.25 {
            playerDebugLog("[HLSPipeline] seek deduped: Δ=\(String(format: "%.0f", deltaFromLastRequest * 1000))ms from last request")
            return
        }
        if !force, deltaFromCurrent < 0.20 {
            playerDebugLog("[HLSPipeline] seek ignored: Δ=\(String(format: "%.0f", deltaFromCurrent * 1000))ms from current (too small)")
            return
        }

        lastSeekWallTime = now
        lastRequestedSeekTime = time
        isSeeking = true
        renderer.jitterStats.reset()

        // Cancel existing pipeline
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

        // Flush renderer
        renderer.flush()

        // Find target segment
        currentSegmentIndex = fetcher.segmentIndex(forTime: time)

        // Set synchronizer time, paused
        let targetCMTime = CMTime(seconds: time, preferredTimescale: 90000)
        renderer.setRate(0, time: targetCMTime)

        isSeeking = false
        self.isPlaying = isPlaying
        hasStartedFeeding = true
        needsInitialSync = false
        needsRateRestoreAfterSeek = isPlaying

        // Restart feeding
        startFeedingLoop()
    }

    func recoverAudio(afterFlushTime flushTime: CMTime, reason: String) async {
        guard state != .idle, state != .loading else { return }
        guard !isSeeking else {
            playerDebugLog("[HLSPipeline] recoverAudio skipped (\(reason)) — seek already in progress")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if isAudioRecoveryInProgress {
            playerDebugLog("[HLSPipeline] recoverAudio skipped (\(reason)) — recovery already in progress")
            return
        }
        if now - lastAudioRecoveryWallTime < 0.2 {
            playerDebugLog("[HLSPipeline] recoverAudio debounced (\(reason))")
            return
        }

        lastAudioRecoveryWallTime = now
        isAudioRecoveryInProgress = true
        defer { isAudioRecoveryInProgress = false }

        let flushSeconds = CMTimeGetSeconds(flushTime)
        let syncTime = renderer.currentTime
        let targetTime = max(
            0,
            (flushSeconds.isFinite && flushSeconds >= 0) ? flushSeconds : syncTime
        )
        let wasPlaying = isPlaying

        playerDebugLog(
            "[HLSPipeline] recoverAudio reason=\(reason) target=\(String(format: "%.3f", targetTime))s " +
            "flush=\(String(format: "%.3f", flushSeconds))s sync=\(String(format: "%.3f", syncTime))s " +
            "wasPlaying=\(wasPlaying)"
        )

        await seek(to: targetTime, isPlaying: wasPlaying, force: true)
    }

    // MARK: - Private: Feeding Pipeline

    private func cancelFeedingPipeline() {
        if let buffer = segmentBuffer {
            Task { await buffer.cancel() }
        }
        downloadTask?.cancel()
        downloadTask = nil
        enqueueTask?.cancel()
        enqueueTask = nil
        segmentBuffer = nil
    }

    private func startFeedingLoop() {
        downloadTask?.cancel()
        enqueueTask?.cancel()

        let buffer = SegmentBuffer(capacity: 3)
        self.segmentBuffer = buffer
        let startIndex = currentSegmentIndex

        // Producer: download segments
        downloadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let fetcher = await self.fetcher
            guard let fetcher = fetcher else { return }
            let segmentCount = fetcher.segments.count

            for index in startIndex..<segmentCount {
                guard !Task.isCancelled else { break }

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
                            try? await Task.sleep(nanoseconds: delay)
                        }
                    }
                }

                if let error = lastError {
                    if !Task.isCancelled {
                        let streamURL = await self.streamURL
                        let demuxer = await self.demuxer
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "hls_pipeline", key: "component")
                            scope.setTag(value: "segment_download", key: "error_type")
                            scope.setTag(value: demuxer?.videoCodecType ?? "unknown", key: "video_codec")
                            scope.setExtra(value: index, key: "segment_index")
                            scope.setExtra(value: segmentCount, key: "segment_count")
                            scope.setExtra(value: streamURL?.host ?? "unknown", key: "stream_host")
                        }
                        await buffer.putError(error)
                    }
                    return
                }
            }
            await buffer.finish()
        }

        // Consumer: demux and enqueue
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
            let bufferWasEmpty = await buffer.isEmpty
            if bufferWasEmpty {
                onStateChange?(.loading)
                renderer.jitterStats.recordBufferUnderrun()
            }

            let result = await buffer.take()

            if bufferWasEmpty {
                renderer.jitterStats.recordBufferRecovery()
            }

            switch result {
            case .segment(let segIndex, let segmentData):
                guard !Task.isCancelled else { return }

                do {
                    let samples = try demuxer.parseMediaSegment(segmentData)
                    guard !Task.isCancelled else { return }

                    if isPlaying {
                        onStateChange?(.running)
                    }

                    var enqueuedVideo = 0
                    for sample in samples {
                        guard !Task.isCancelled else { return }

                        do {
                            let sampleBuffer = try demuxer.createSampleBuffer(from: sample)

                            if sample.isVideo {
                                renderer.jitterStats.recordVideoPTS(CMTimeGetSeconds(sample.pts))
                                let isFirstVideoSample = enqueuedVideo == 0

                                // Sync timing before first enqueue
                                if needsInitialSync {
                                    needsInitialSync = false
                                    renderer.setRate(isPlaying ? playbackRate : 0, time: sample.pts)
                                } else if needsRateRestoreAfterSeek {
                                    needsRateRestoreAfterSeek = false
                                    renderer.setRate(playbackRate, time: sample.pts)
                                } else if !isPlaying && isFirstVideoSample {
                                    renderer.setRate(0, time: sample.pts)
                                }

                                await renderer.enqueueVideo(sampleBuffer)
                                enqueuedVideo += 1

                                // Paused seek: return after showing frame
                                if !isPlaying && isFirstVideoSample {
                                    onStateChange?(.paused)
                                    return
                                }
                            } else {
                                await renderer.enqueueAudio(sampleBuffer)
                            }
                        } catch {
                            playerDebugLog("[HLSPipeline] Failed to create sample buffer: \(error)")
                        }
                    }

                    // Log renderer errors
                    if let layerError = renderer.displayLayerError {
                        playerDebugLog("[HLSPipeline] Display layer error: \(layerError)")
                        SentrySDK.capture(error: layerError) { scope in
                            scope.setTag(value: "hls_pipeline", key: "component")
                            scope.setTag(value: "display_layer", key: "error_type")
                        }
                    }
                    if let audioError = renderer.audioRendererError {
                        playerDebugLog("[HLSPipeline] Audio renderer error: \(audioError)")
                        SentrySDK.capture(error: audioError) { scope in
                            scope.setTag(value: "hls_pipeline", key: "component")
                            scope.setTag(value: "audio_renderer", key: "error_type")
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
                        playerDebugLog("[HLSPipeline] Segment \(segIndex) parse error: \(error)")
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "hls_pipeline", key: "component")
                            scope.setTag(value: "segment_demux", key: "error_type")
                            scope.setExtra(value: segIndex, key: "segment_index")
                        }
                        onError?(error)
                    }
                    return
                }

            case .error(let error):
                if !Task.isCancelled {
                    onError?(error)
                }
                return

            case .finished:
                break

            case .cancelled:
                return
            }
        }

        // End of content
        if !Task.isCancelled && currentSegmentIndex >= segmentCount {
            isPlaying = false
            state = .ended
            onEndOfStream?()
        }
    }
}
