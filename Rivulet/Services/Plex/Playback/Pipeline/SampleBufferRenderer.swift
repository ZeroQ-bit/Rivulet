//
//  SampleBufferRenderer.swift
//  Rivulet
//
//  Shared rendering layer for video and audio sample buffers.
//  Owns AVSampleBufferDisplayLayer for video.
//  Audio output uses AVAudioEngine for PCM (client-decoded) audio, or
//  AVSampleBufferAudioRenderer for compressed passthrough (AC3/EAC3).
//

import Foundation
import AVFoundation
import CoreMedia

/// Shared rendering layer that accepts CMSampleBuffers and manages A/V synchronization.
@MainActor
final class SampleBufferRenderer {

    // MARK: - Public: Display layer for view binding

    let displayLayer = AVSampleBufferDisplayLayer()

    /// Passthrough audio renderer — used for compressed formats (AC3/EAC3) that the
    /// receiver can decode natively. NOT used for client-decoded PCM audio.
    nonisolated(unsafe) let audioRenderer = AVSampleBufferAudioRenderer()

    /// Synchronizer for passthrough audio. Drives the video timebase in passthrough mode.
    nonisolated(unsafe) let renderSynchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - AVAudioEngine (PCM Audio)

    /// When true, client-decoded PCM audio routes through AVAudioEngine instead of
    /// AVSampleBufferAudioRenderer. The engine handles sample rate conversion and
    /// device-specific buffering (critical for AirPlay/HomePod).
    nonisolated(unsafe) private(set) var useAudioEngine = false

    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var pcmAudioFormat: AVAudioFormat?
    private var engineConfigObserver: NSObjectProtocol?

    /// Our own timebase for video when using AVAudioEngine.
    /// Advances with the host clock at the set rate. We control it via setRate/setTime.
    nonisolated(unsafe) private var videoTimebase: CMTimebase?

    // MARK: - Configuration

    /// Maximum seconds of lookahead before pacing slows enqueue
    var maxVideoLookahead: TimeInterval = 2.0

    /// Maximum seconds to wait for audio renderer backpressure before dropping.
    var audioBackpressureMaxWait: TimeInterval = 0.5

    /// Use pull-mode audio delivery for passthrough path.
    var useAudioPullMode = false

    // MARK: - Pull-Mode Audio State (passthrough only)

    private let audioPullLock = NSLock()
    private nonisolated(unsafe) var audioPullBuffer: [CMSampleBuffer] = []
    private nonisolated(unsafe) var audioPullRequesting = false
    private let audioPullQueue = DispatchQueue(label: "rivulet.audio-pull", qos: .userInteractive)

    // MARK: - Callbacks

    /// Called when the audio renderer is automatically flushed by the system.
    var onAudioRendererFlushedAutomatically: ((CMTime) -> Void)?

    /// Called when the audio output configuration changes.
    var onAudioOutputConfigurationChanged: (() -> Void)?

    // MARK: - Audio State

    private var hasLoggedFirstAudioSample = false
    private var lastAudioRendererStatus: AVQueuedSampleBufferRenderingStatus?
    private var audioBackpressureDropCount = 0
    private var audioEnqueueCount = 0
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0
    private var lastAudioDiagWallTime: CFAbsoluteTime = 0
    private var audioNotReadyStreak = 0

    // MARK: - Notification Observers

    private var autoFlushObserver: NSObjectProtocol?
    private var outputConfigObserver: NSObjectProtocol?

    // MARK: - Jitter Diagnostics

    var jitterStats = PlaybackJitterStats()

    // MARK: - Init

    init() {
        // Synchronizer manages passthrough audio only.
        renderSynchronizer.addRenderer(audioRenderer)

        if #available(tvOS 14.5, *) {
            renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        }

        // Default: video uses the synchronizer's timebase (passthrough mode).
        displayLayer.controlTimebase = renderSynchronizer.timebase
        displayLayer.videoGravity = .resizeAspect

        audioRenderer.volume = 1.0
        audioRenderer.isMuted = false
        audioRenderer.allowedAudioSpatializationFormats = []

        observeAudioRendererNotifications()
    }

    deinit {
        if audioPullRequesting {
            audioRenderer.stopRequestingMediaData()
        }
        if let autoFlushObserver {
            NotificationCenter.default.removeObserver(autoFlushObserver)
        }
        if let outputConfigObserver {
            NotificationCenter.default.removeObserver(outputConfigObserver)
        }
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
    }

    // MARK: - AVAudioEngine Setup

    /// Enable AVAudioEngine for PCM audio output. Call before enqueuing any audio.
    /// The engine is configured lazily from the first CMSampleBuffer's format.
    func enableAudioEngine() {
        guard !useAudioEngine else { return }

        // Create our own timebase for video (decoupled from the synchronizer).
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        if let tb {
            videoTimebase = tb
            displayLayer.controlTimebase = tb
        }

        useAudioEngine = true
        print("[Renderer] Audio engine mode enabled — video uses independent timebase")
    }

    /// Disable AVAudioEngine and revert to passthrough mode.
    func disableAudioEngine() {
        guard useAudioEngine else { return }

        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
        pcmAudioFormat = nil

        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
            self.engineConfigObserver = nil
        }

        // Revert video to synchronizer's timebase
        displayLayer.controlTimebase = renderSynchronizer.timebase
        videoTimebase = nil
        useAudioEngine = false
        print("[Renderer] Audio engine mode disabled — reverted to passthrough")
    }

    /// Lazily configure and start the audio engine from the first buffer's format.
    private func configureAudioEngine(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else {
            print("[Renderer] AudioEngine: cannot read format from sample buffer")
            return false
        }

        let a = asbd.pointee
        let isFloat = (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let commonFormat: AVAudioCommonFormat = isFloat ? .pcmFormatFloat32 : .pcmFormatInt16

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: a.mSampleRate,
            channels: AVAudioChannelCount(a.mChannelsPerFrame),
            interleaved: true
        ) else {
            print("[Renderer] AudioEngine: failed to create AVAudioFormat")
            return false
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            print("[Renderer] AudioEngine: failed to start — \(error.localizedDescription)")
            return false
        }

        // Observe engine config changes (route switches, sample rate changes).
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigChange()
            }
        }

        self.audioEngine = engine
        self.audioPlayerNode = playerNode
        self.pcmAudioFormat = format

        let formatName = isFloat ? "float32" : "s16"
        print("[Renderer] AudioEngine started: \(Int(a.mSampleRate))Hz " +
              "\(a.mChannelsPerFrame)ch \(formatName) → output \(engine.outputNode.outputFormat(forBus: 0))")

        // Node stays stopped — buffers are queued during preroll.
        // setRate(rate > 0) calls play() once video is also ready.
        return true
    }

    private func handleEngineConfigChange() {
        print("[Renderer] AudioEngine config changed — restarting")
        guard let engine = audioEngine, let playerNode = audioPlayerNode else { return }

        // Engine stops itself on config change. Restart it.
        do {
            try engine.start()
            // Only resume the player node if we're actively playing (timebase rate > 0).
            // If paused, the node stays stopped until setRate(rate > 0) is called.
            if let tb = videoTimebase, CMTimebaseGetRate(tb) > 0 {
                playerNode.play()
            }
            print("[Renderer] AudioEngine restarted after config change (playing=\(playerNode.isPlaying))")
        } catch {
            print("[Renderer] AudioEngine restart failed: \(error.localizedDescription)")
        }

        onAudioOutputConfigurationChanged?()
    }

    // MARK: - Synchronizer / Timebase Control

    /// Current playback position.
    nonisolated var currentTime: TimeInterval {
        if useAudioEngine, let tb = videoTimebase {
            let time = CMTimeGetSeconds(CMTimebaseGetTime(tb))
            return time.isFinite && time >= 0 ? time : 0
        }
        let time = CMTimeGetSeconds(renderSynchronizer.currentTime())
        return time.isFinite && time >= 0 ? time : 0
    }

    /// Current time as CMTime.
    nonisolated var currentCMTime: CMTime {
        if useAudioEngine, let tb = videoTimebase {
            return CMTimebaseGetTime(tb)
        }
        return renderSynchronizer.currentTime()
    }

    /// Set playback rate (0 = paused, 1 = normal).
    func setRate(_ rate: Float) {
        print("[Renderer] setRate(\(rate))")
        if useAudioEngine {
            if let tb = videoTimebase {
                CMTimebaseSetRate(tb, rate: Float64(rate))
            }
            if rate > 0 {
                audioPlayerNode?.play()
            } else {
                audioPlayerNode?.pause()
            }
        } else {
            renderSynchronizer.rate = rate
        }
    }

    /// Set playback rate and time simultaneously.
    func setRate(_ rate: Float, time: CMTime) {
        print("[Renderer] setRate(\(rate), time=\(String(format: "%.3f", CMTimeGetSeconds(time)))s)")
        if useAudioEngine {
            if let tb = videoTimebase {
                CMTimebaseSetTime(tb, time: time)
                CMTimebaseSetRate(tb, rate: Float64(rate))
            }
            if rate > 0 {
                audioPlayerNode?.play()
            } else {
                audioPlayerNode?.pause()
            }
        } else {
            renderSynchronizer.setRate(rate, time: time)
        }
    }

    // MARK: - Enqueue Video

    /// Enqueue a video sample buffer with pacing to prevent buffer overflow.
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer, bypassLookahead: Bool = false) async {
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = CMTimeGetSeconds(samplePTS)

        if !bypassLookahead {
            while !Task.isCancelled {
                let syncTime = currentTime
                let ahead = sampleTime - syncTime

                if ahead <= maxVideoLookahead || syncTime < 0.1 {
                    break
                }

                let sleepTime = min(ahead - maxVideoLookahead, 0.1)
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

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
                try? await Task.sleep(nanoseconds: 2_000_000)
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

    // MARK: - Enqueue Audio

    /// Enqueue an audio sample buffer. Routes to AVAudioEngine (PCM) or
    /// AVSampleBufferAudioRenderer (passthrough) based on current mode.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) async {
        if useAudioEngine {
            enqueueAudioViaEngine(sampleBuffer)
            return
        }

        if useAudioPullMode {
            enqueueAudioPullMode(sampleBuffer)
            return
        }

        // --- Passthrough push mode ---

        let currentStatus = audioRenderer.status
        if lastAudioRendererStatus != currentStatus {
            lastAudioRendererStatus = currentStatus
            let errorDescription = audioRenderer.error?.localizedDescription ?? "none"
            print("[Renderer] Audio renderer status changed: \(audioRendererStatusDescription(currentStatus)) (error=\(errorDescription))")
        }

        if currentStatus == .failed {
            guard recoverAudioRendererIfNeeded(reason: "pre_enqueue") else { return }
        }

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
            let waitStart = CFAbsoluteTimeGetCurrent()
            let maxWait = audioBackpressureMaxWait

            while !audioRenderer.isReadyForMoreMediaData && !Task.isCancelled {
                if audioRenderer.status == .failed {
                    guard recoverAudioRendererIfNeeded(reason: "backpressure_wait") else { return }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - waitStart
                if elapsed > maxWait {
                    audioBackpressureDropCount += 1
                    audioNotReadyStreak += 1
                    if audioBackpressureDropCount == 1 || audioBackpressureDropCount % 50 == 0 {
                        let syncRate = renderSynchronizer.rate
                        let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
                        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        print(
                            "[Renderer] Dropping audio sample after \(String(format: "%.0f", elapsed * 1000))ms backpressure " +
                            "(drops=\(audioBackpressureDropCount), streak=\(audioNotReadyStreak), " +
                            "status=\(audioRenderer.status.rawValue), error=\(audioRenderer.error?.localizedDescription ?? "none"), " +
                            "syncRate=\(syncRate), syncTime=\(String(format: "%.3f", syncTime))s, " +
                            "samplePTS=\(String(format: "%.3f", pts))s, muted=\(audioRenderer.isMuted))"
                        )
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
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
        audioNotReadyStreak = 0

        // Periodic audio diagnostics (every 5s)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let audioAhead = pts - syncTime
            print("[Renderer] AudioDiag: enqueued=\(audioEnqueueCount) drops=\(audioBackpressureDropCount) " +
                  "syncRate=\(syncRate) syncTime=\(String(format: "%.3f", syncTime))s " +
                  "audioPTS=\(String(format: "%.3f", pts))s ahead=\(String(format: "%.3f", audioAhead))s " +
                  "ready=\(audioRenderer.isReadyForMoreMediaData) status=\(audioRenderer.status.rawValue) " +
                  "muted=\(audioRenderer.isMuted) vol=\(audioRenderer.volume)")
        }
    }

    // MARK: - AVAudioEngine Audio Enqueue

    /// Convert a CMSampleBuffer to AVAudioPCMBuffer and schedule on the player node.
    private func enqueueAudioViaEngine(_ sampleBuffer: CMSampleBuffer) {
        // Lazy setup: configure engine from first buffer's format description.
        if audioEngine == nil {
            guard configureAudioEngine(from: sampleBuffer) else { return }
        }

        guard let playerNode = audioPlayerNode,
              let format = pcmAudioFormat else { return }

        // Extract raw PCM data from the CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer
        )
        guard status == noErr, let data = dataPointer, length > 0 else { return }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = AVAudioFrameCount(length / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy interleaved PCM data into the AVAudioPCMBuffer
        let dst = pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mData!
        memcpy(dst, data, length)

        playerNode.scheduleBuffer(pcmBuffer)
        audioEnqueueCount += 1

        // First sample log
        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let outputFormat = audioEngine?.outputNode.outputFormat(forBus: 0)
            print("[Renderer] AudioEngine first sample: PTS=\(String(format: "%.3f", CMTimeGetSeconds(pts)))s " +
                  "inputFormat=\(format) frames=\(frameCount) " +
                  "outputRate=\(outputFormat.map { String(Int($0.sampleRate)) } ?? "?")")
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_engine")
        }

        // Periodic diagnostics
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let tbTime = videoTimebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            print("[Renderer] AudioEngineDiag: enqueued=\(audioEnqueueCount) " +
                  "tbTime=\(String(format: "%.3f", tbTime))s " +
                  "audioPTS=\(String(format: "%.3f", pts))s " +
                  "engineRunning=\(audioEngine?.isRunning ?? false)")
        }
    }

    // MARK: - Pull-Mode Audio (passthrough only)

    private func enqueueAudioPullMode(_ sampleBuffer: CMSampleBuffer) {
        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            print("[Renderer] Pull-mode audio first sample: syncRate=\(syncRate), " +
                  "syncTime=\(String(format: "%.3f", syncTime))s, " +
                  "PTS=\(String(format: "%.3f", CMTimeGetSeconds(pts)))s")
            logAudioSampleFormat(sampleBuffer)
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_pull")
        }

        audioPullLock.lock()
        audioPullBuffer.append(sampleBuffer)
        let bufferCount = audioPullBuffer.count
        let needsRestart = !audioPullRequesting
        audioPullLock.unlock()

        audioEnqueueCount += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            print("[Renderer] AudioPullDiag: buffered=\(bufferCount) enqueued=\(audioEnqueueCount) " +
                  "requesting=\(audioPullRequesting) " +
                  "syncTime=\(String(format: "%.3f", syncTime))s " +
                  "audioPTS=\(String(format: "%.3f", pts))s " +
                  "status=\(audioRenderer.status.rawValue)")
        }

        if needsRestart {
            startAudioPullMode()
        }
    }

    private func startAudioPullMode() {
        audioPullLock.lock()
        audioPullRequesting = true
        audioPullLock.unlock()

        audioRenderer.requestMediaDataWhenReady(on: audioPullQueue) { [weak self] in
            self?.drainAudioPullBuffer()
        }
    }

    private nonisolated func drainAudioPullBuffer() {
        while audioRenderer.isReadyForMoreMediaData {
            audioPullLock.lock()
            guard !audioPullBuffer.isEmpty else {
                audioPullRequesting = false
                audioPullLock.unlock()
                audioRenderer.stopRequestingMediaData()
                return
            }
            let sample = audioPullBuffer.removeFirst()
            audioPullLock.unlock()

            audioRenderer.enqueue(sample)
        }
    }

    func stopAudioPullMode() {
        audioPullLock.lock()
        if audioPullRequesting {
            audioPullRequesting = false
            audioPullLock.unlock()
            audioRenderer.stopRequestingMediaData()
        } else {
            audioPullLock.unlock()
        }

        audioPullLock.lock()
        audioPullBuffer.removeAll()
        audioPullLock.unlock()
    }

    /// Reset audio diagnostics and recovery state (call after flush/seek).
    func resetAudioState() {
        hasLoggedFirstAudioSample = false
        lastAudioRendererStatus = nil
        audioBackpressureDropCount = 0
        audioEnqueueCount = 0
        lastAudioRecoveryWallTime = 0
        lastAudioDiagWallTime = 0
        audioNotReadyStreak = 0

        audioPullLock.lock()
        audioPullBuffer.removeAll()
        audioPullLock.unlock()
    }

    // MARK: - Flush

    /// Flush both video and audio buffers (for seeking).
    func flush() {
        displayLayer.flushAndRemoveImage()

        if useAudioEngine {
            // Stop the player node to clear all scheduled buffers.
            // Node stays stopped — setRate(rate > 0) will call play() when ready.
            audioPlayerNode?.stop()
            audioEngine?.stop()
            audioPlayerNode = nil
            audioEngine = nil
            pcmAudioFormat = nil
            if let engineConfigObserver {
                NotificationCenter.default.removeObserver(engineConfigObserver)
                self.engineConfigObserver = nil
            }
        } else {
            // Passthrough: stop pull mode and flush renderer
            audioPullLock.lock()
            let wasPulling = audioPullRequesting
            if wasPulling {
                audioPullRequesting = false
            }
            audioPullLock.unlock()

            if wasPulling {
                audioRenderer.stopRequestingMediaData()
            }

            audioRenderer.flush()
        }

        resetAudioState()
    }

    /// Check for errors on display layer or audio renderer.
    var displayLayerError: Error? { displayLayer.error }
    var audioRendererError: Error? {
        useAudioEngine ? nil : audioRenderer.error
    }
    var isAudioPrimedForPlayback: Bool {
        if useAudioEngine {
            return audioEnqueueCount > 0
        }
        return audioEnqueueCount > 0 || audioRenderer.status == .rendering
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

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSigned = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0
        let formatType = isFloat ? "float" : (isSigned ? "sint" : "uint")

        print(
            "[Renderer] Audio format details: codec=\(codec) sampleRate=\(Int(asbd.mSampleRate)) " +
            "channels=\(asbd.mChannelsPerFrame) bitsPerChannel=\(asbd.mBitsPerChannel) " +
            "type=\(formatType) packed=\(isPacked) flags=\(asbd.mFormatFlags) " +
            "bytesPerFrame=\(asbd.mBytesPerFrame) layout=\(channelLayoutSummary)"
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

    // MARK: - Notification Observers

    private func observeAudioRendererNotifications() {
        autoFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: .main
        ) { [weak self] notification in
            let flushTime: CMTime
            if let timeValue = notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue {
                flushTime = timeValue.timeValue
            } else {
                flushTime = .invalid
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only relevant for passthrough mode
                guard !self.useAudioEngine else { return }
                let flushTimeSeconds = CMTimeGetSeconds(flushTime)
                let syncTime = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                print("[Renderer] Audio renderer auto-flushed at \(String(format: "%.3f", flushTimeSeconds))s " +
                      "(syncTime=\(String(format: "%.3f", syncTime))s, " +
                      "enqueued=\(self.audioEnqueueCount), drops=\(self.audioBackpressureDropCount))")

                self.resetAudioState()
                self.onAudioRendererFlushedAutomatically?(flushTime)
            }
        }

        outputConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: audioRenderer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only relevant for passthrough mode
                guard !self.useAudioEngine else { return }
                let syncTime = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                print("[Renderer] Audio output configuration changed (syncTime=\(String(format: "%.3f", syncTime))s)")

                AudioRouteDiagnostics.shared.logCurrentRoute(
                    owner: "SampleBufferRenderer",
                    reason: "output_config_changed"
                )

                self.onAudioOutputConfigurationChanged?()
            }
        }
    }
}
