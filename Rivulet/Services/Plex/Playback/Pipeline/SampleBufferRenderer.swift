//
//  SampleBufferRenderer.swift
//  Rivulet
//
//  Shared rendering layer for video and audio sample buffers.
//  Owns AVSampleBufferDisplayLayer, AVSampleBufferAudioRenderer, and
//  AVSampleBufferRenderSynchronizer. Used by both DirectPlayPipeline and HLSPipeline.
//

import Foundation
import AVFoundation
import CoreMedia

/// Shared rendering layer that accepts CMSampleBuffers and manages A/V synchronization.
@MainActor
final class SampleBufferRenderer {

    // MARK: - Public: Display layer for view binding

    let displayLayer = AVSampleBufferDisplayLayer()
    let audioRenderer = AVSampleBufferAudioRenderer()
    let renderSynchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - Configuration

    /// Maximum seconds of lookahead before pacing slows enqueue
    var maxVideoLookahead: TimeInterval = 2.0

    // MARK: - Audio State

    private var hasLoggedFirstAudioSample = false
    private var lastAudioRendererStatus: AVQueuedSampleBufferRenderingStatus?
    private var audioBackpressureDropCount = 0
    private var audioEnqueueCount = 0
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0

    // MARK: - Jitter Diagnostics

    var jitterStats = PlaybackJitterStats()

    // MARK: - Init

    init() {
        renderSynchronizer.addRenderer(displayLayer)
        renderSynchronizer.addRenderer(audioRenderer)
        displayLayer.videoGravity = .resizeAspect

        // Ensure audio renderer is unmuted and at full volume
        audioRenderer.volume = 1.0
        audioRenderer.isMuted = false
    }

    // MARK: - Synchronizer Control

    /// Current playback position from the synchronizer clock.
    var currentTime: TimeInterval {
        let time = CMTimeGetSeconds(renderSynchronizer.currentTime())
        return time.isFinite && time >= 0 ? time : 0
    }

    /// Current synchronizer time as CMTime.
    var currentCMTime: CMTime {
        renderSynchronizer.currentTime()
    }

    /// Set synchronizer rate (0 = paused, 1 = normal playback).
    func setRate(_ rate: Float) {
        renderSynchronizer.rate = rate
    }

    /// Set synchronizer rate and time simultaneously.
    func setRate(_ rate: Float, time: CMTime) {
        renderSynchronizer.setRate(rate, time: time)
    }

    // MARK: - Enqueue

    /// Enqueue a video sample buffer with pacing to prevent buffer overflow.
    /// Waits if the sample is too far ahead of the synchronizer clock.
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer, bypassLookahead: Bool = false) async {
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = CMTimeGetSeconds(samplePTS)

        // Pace enqueue: wait if sample is too far ahead of synchronizer time
        if !bypassLookahead {
            while !Task.isCancelled {
                let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
                let ahead = sampleTime - syncTime

                if ahead <= maxVideoLookahead || syncTime < 0.1 {
                    break
                }

                let sleepTime = min(ahead - maxVideoLookahead, 0.1)
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        // Wait for display layer readiness.
        // During preroll (rate=0), use a short timeout to avoid startup deadlocks.
        if !displayLayer.isReadyForMoreMediaData {
            let stallStart = CFAbsoluteTimeGetCurrent()
            let maxWait: TimeInterval = bypassLookahead ? 0.12 : 2.0

            while !displayLayer.isReadyForMoreMediaData && !Task.isCancelled {
                let elapsed = CFAbsoluteTimeGetCurrent() - stallStart
                if elapsed > maxWait {
                    print("[Renderer] Video enqueue timeout after \(String(format: "%.0f", elapsed * 1000))ms — dropping frame (preroll=\(bypassLookahead), layer error: \(displayLayer.error?.localizedDescription ?? "none"))")
                    jitterStats.recordEnqueueStall(duration: elapsed)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }

            let stallDuration = CFAbsoluteTimeGetCurrent() - stallStart
            jitterStats.recordEnqueueStall(duration: stallDuration)
        }

        guard !Task.isCancelled else { return }

        if let error = displayLayer.error {
            print("[Renderer] Display layer error before enqueue: \(error)")
        }

        displayLayer.enqueue(sampleBuffer)
    }

    /// Enqueue an audio sample buffer with bounded backpressure waits.
    /// Drops individual samples when the renderer remains backpressured too long.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) async {
        let currentStatus = audioRenderer.status
        if lastAudioRendererStatus != currentStatus {
            lastAudioRendererStatus = currentStatus
            let errorDescription = audioRenderer.error?.localizedDescription ?? "none"
            print("[Renderer] Audio renderer status changed: \(audioRendererStatusDescription(currentStatus)) (error=\(errorDescription))")
        }

        if currentStatus == .failed {
            guard recoverAudioRendererIfNeeded(reason: "pre_enqueue") else { return }
        }

        // Log first audio attempt with renderer + session details.
        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let ready = audioRenderer.isReadyForMoreMediaData
            let status = audioRenderer.status.rawValue
            print("[Renderer] Audio enqueue attempt: ready=\(ready), syncRate=\(syncRate), syncTime=\(String(format: "%.3f", syncTime))s, status=\(status)")
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            print("[Renderer] Audio sample PTS=\(CMTimeGetSeconds(pts))s, size=\(CMSampleBufferGetTotalSampleSize(sampleBuffer))B")
            logAudioSampleFormat(sampleBuffer)
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_sample")
        }

        if !audioRenderer.isReadyForMoreMediaData {
            // Bounded wait to avoid unbounded stalls while still tolerating normal startup backpressure.
            let waitStart = CFAbsoluteTimeGetCurrent()
            let maxWait: TimeInterval = 0.5 // 500ms

            while !audioRenderer.isReadyForMoreMediaData && !Task.isCancelled {
                if audioRenderer.status == .failed {
                    guard recoverAudioRendererIfNeeded(reason: "backpressure_wait") else { return }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - waitStart
                if elapsed > maxWait {
                    audioBackpressureDropCount += 1
                    if audioBackpressureDropCount == 1 || audioBackpressureDropCount % 100 == 0 {
                        print(
                            "[Renderer] Dropping audio sample after \(String(format: "%.0f", elapsed * 1000))ms backpressure " +
                            "(drops=\(audioBackpressureDropCount), status=\(audioRenderer.status.rawValue), error=\(audioRenderer.error?.localizedDescription ?? "none"))"
                        )
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
            }
        }

        guard !Task.isCancelled else { return }

        if audioRenderer.status == .failed {
            guard recoverAudioRendererIfNeeded(reason: "post_wait") else { return }
        }

        if let error = audioRenderer.error {
            print("[Renderer] Audio renderer error before enqueue: \(error)")
            return
        }

        audioRenderer.enqueue(sampleBuffer)
        audioEnqueueCount += 1
    }

    /// Reset audio renderer diagnostics and recovery state (call after flush/seek).
    func resetAudioState() {
        hasLoggedFirstAudioSample = false
        lastAudioRendererStatus = nil
        audioBackpressureDropCount = 0
        audioEnqueueCount = 0
        lastAudioRecoveryWallTime = 0
    }

    // MARK: - Flush

    /// Flush both video and audio buffers (for seeking).
    func flush() {
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()
        resetAudioState()
    }

    /// Check for errors on display layer or audio renderer.
    var displayLayerError: Error? { displayLayer.error }
    var audioRendererError: Error? { audioRenderer.error }
    var isAudioPrimedForPlayback: Bool {
        audioEnqueueCount > 0 || audioRenderer.status == .rendering
    }

    @discardableResult
    private func recoverAudioRendererIfNeeded(reason: String) -> Bool {
        guard audioRenderer.status == .failed else { return true }

        let errorDescription = audioRenderer.error?.localizedDescription ?? "none"
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioRecoveryWallTime > 0.25 {
            lastAudioRecoveryWallTime = now
            print("[Renderer] Audio renderer failed during \(reason); flushing to recover (error=\(errorDescription))")
        }
        audioRenderer.flush()
        return true
    }

    private func logAudioSampleFormat(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            print("[Renderer] Audio format: unavailable")
            return
        }

        let asbd = streamBasicDescription.pointee
        let codec = fourCCString(asbd.mFormatID)

        var channelLayoutSummary = "unknown"
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize) {
            let tag = layout.pointee.mChannelLayoutTag
            let channels = AudioChannelLayoutTag_GetNumberOfChannels(tag)
            channelLayoutSummary = "tag=\(tag),channels=\(channels)"
        }

        print(
            "[Renderer] Audio format details: codec=\(codec) sampleRate=\(Int(asbd.mSampleRate)) " +
            "channels=\(asbd.mChannelsPerFrame) bitsPerChannel=\(asbd.mBitsPerChannel) " +
            "framesPerPacket=\(asbd.mFramesPerPacket) layout=\(channelLayoutSummary)"
        )
    }

    private func fourCCString(_ fourCC: UInt32) -> String {
        let n = Int(fourCC.bigEndian)
        let scalars = [
            UnicodeScalar((n >> 24) & 255),
            UnicodeScalar((n >> 16) & 255),
            UnicodeScalar((n >> 8) & 255),
            UnicodeScalar(n & 255)
        ]
        let characters = scalars.compactMap { $0.map(Character.init) }
        return String(characters)
    }

    private func audioRendererStatusDescription(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown:
            return "unknown(0)"
        case .rendering:
            return "rendering(1)"
        case .failed:
            return "failed(2)"
        @unknown default:
            return "unknown_future(\(status.rawValue))"
        }
    }
}
