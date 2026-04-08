//
//  PlaybackJitterStats.swift
//  Rivulet
//
//  Lightweight playback diagnostics shared by the active sample-buffer renderer.
//

import Foundation

/// Lightweight diagnostics for detecting micro-jitters and stutters.
/// Tracks PTS gaps between consecutive video frames, buffer underruns,
/// and enqueue stalls. Logs a summary periodically.
struct PlaybackJitterStats {
    /// Expected frame duration based on content framerate
    private(set) var expectedFrameDuration: TimeInterval = 0

    // Frame timing
    private var lastVideoPTS: TimeInterval = -1
    private var totalVideoFrames: Int = 0
    private var droppedFrameGaps: Int = 0
    private var maxPTSGap: TimeInterval = 0
    private var ptsGapSum: TimeInterval = 0
    private var ptsGapSumSquared: TimeInterval = 0
    private var minPTS: TimeInterval = .infinity
    private var maxPTS: TimeInterval = -.infinity

    // Buffer health
    private(set) var bufferUnderruns: Int = 0
    private var lastUnderrunTime: CFAbsoluteTime = 0
    private var totalUnderrunDuration: TimeInterval = 0

    // Enqueue stalls
    private(set) var videoEnqueueStalls: Int = 0
    private var maxStallDuration: TimeInterval = 0
    private var totalStallDuration: TimeInterval = 0

    // Synchronizer drift tracking
    private var lastSyncCheckWallTime: CFAbsoluteTime = 0
    private var lastSyncCheckPlaybackTime: TimeInterval = 0
    private var syncDriftSamples: [Double] = []
    private var maxSyncDrift: Double = 0
    private var syncDriftAlerts: Int = 0
    private var consecutiveDriftCount: Int = 0
    private var lastDriftDirection: Int = 0

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

        if pts < minPTS { minPTS = pts }
        if pts > maxPTS { maxPTS = pts }

        if expectedFrameDuration == 0 && totalVideoFrames == 100 && maxPTS > minPTS {
            let ptsRange = maxPTS - minPTS
            expectedFrameDuration = ptsRange / Double(totalVideoFrames - 1)
        }

        guard lastVideoPTS >= 0 else {
            lastVideoPTS = pts
            return
        }

        let gap = pts - lastVideoPTS
        lastVideoPTS = pts

        guard gap > 0 else { return }

        ptsGapSum += gap
        ptsGapSumSquared += gap * gap

        if gap > maxPTSGap {
            maxPTSGap = gap
        }

        if expectedFrameDuration > 0 && gap > expectedFrameDuration * 24.0 {
            droppedFrameGaps += 1
            playerDebugLog(
                "📊 [Jitter] ⚠️ Large PTS gap: \(String(format: "%.0f", gap * 1000))ms " +
                "at frame \(totalVideoFrames) (expected ~\(String(format: "%.0f", expectedFrameDuration * 1000))ms)"
            )
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
        if duration > 0.1 {
            playerDebugLog("📊 [Jitter] ⏱️ Enqueue stall: \(String(format: "%.0f", duration * 1000))ms (frame \(totalVideoFrames))")
        }
    }

    /// Record synchronizer drift relative to wall time.
    mutating func recordSynchronizerTime(_ syncTime: TimeInterval, isPlaying: Bool, rate: Float) {
        let now = CFAbsoluteTimeGetCurrent()

        guard isPlaying && rate > 0 else {
            lastSyncCheckWallTime = 0
            lastSyncCheckPlaybackTime = 0
            return
        }

        guard lastSyncCheckWallTime > 0 else {
            lastSyncCheckWallTime = now
            lastSyncCheckPlaybackTime = syncTime
            return
        }

        let wallDelta = now - lastSyncCheckWallTime
        let syncDelta = syncTime - lastSyncCheckPlaybackTime

        guard wallDelta > 0.2 else { return }

        let expectedSyncDelta = wallDelta * Double(rate)
        let driftRate = syncDelta / expectedSyncDelta

        syncDriftSamples.append(driftRate)
        if syncDriftSamples.count > 50 {
            syncDriftSamples.removeFirst()
        }

        let deviation = abs(driftRate - 1.0)
        if deviation > maxSyncDrift {
            maxSyncDrift = deviation
        }

        let currentDirection: Int
        if driftRate < 0.95 {
            currentDirection = -1
        } else if driftRate > 1.05 {
            currentDirection = 1
        } else {
            currentDirection = 0
        }

        if currentDirection != 0 && currentDirection == lastDriftDirection {
            consecutiveDriftCount += 1
            if consecutiveDriftCount >= 3 {
                syncDriftAlerts += 1
                let direction = currentDirection < 0 ? "slow" : "fast"
                playerDebugLog(
                    "📊 [Jitter] ⚠️ Sustained sync drift (\(direction)): \(String(format: "%.1f", driftRate * 100))% " +
                    "(wall: \(String(format: "%.0f", wallDelta * 1000))ms, sync: \(String(format: "%.0f", syncDelta * 1000))ms)"
                )
                consecutiveDriftCount = 0
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
        let fps: Double
        if expectedFrameDuration > 0 {
            fps = 1.0 / expectedFrameDuration
        } else if avgGap > 0 {
            fps = 1.0 / avgGap
        } else {
            fps = 0
        }

        let n = Double(max(framesSinceReport - 1, 1))
        let variance = max(0, (ptsGapSumSquared / n) - (avgGap * avgGap))
        let stdDev = sqrt(variance)

        var syncAvg: Double = 1.0
        var syncStdDev: Double = 0
        if !syncDriftSamples.isEmpty {
            syncAvg = syncDriftSamples.reduce(0, +) / Double(syncDriftSamples.count)
            let syncVariance = syncDriftSamples.reduce(0) { $0 + ($1 - syncAvg) * ($1 - syncAvg) } / Double(syncDriftSamples.count)
            syncStdDev = sqrt(syncVariance)
        }

        let hasIssues = droppedFrameGaps > 0 || bufferUnderruns > 0 || videoEnqueueStalls > 0 || syncDriftAlerts > 0
        let icon = hasIssues ? "⚠️" : "✅"

        playerDebugLog(
            "📊 [Jitter] \(icon) \(totalVideoFrames) frames | \(String(format: "%.1f", fps))fps | " +
            "gaps: avg=\(String(format: "%.1f", avgGap * 1000))ms σ=\(String(format: "%.2f", stdDev * 1000))ms max=\(String(format: "%.1f", maxPTSGap * 1000))ms | " +
            "drops: \(droppedFrameGaps) | underruns: \(bufferUnderruns) (\(String(format: "%.1f", totalUnderrunDuration * 1000))ms) | " +
            "stalls: \(videoEnqueueStalls) (max=\(String(format: "%.1f", maxStallDuration * 1000))ms total=\(String(format: "%.1f", totalStallDuration * 1000))ms) | " +
            "sync: \(String(format: "%.1f", syncAvg * 100))%±\(String(format: "%.1f", syncStdDev * 100))% alerts:\(syncDriftAlerts)"
        )

        lastReportTime = now
        lastReportFrameCount = totalVideoFrames
        return true
    }

    // MARK: - Health Snapshot

    /// Returns current jitter metrics for use in health reports.
    func healthSnapshot() -> JitterSnapshot {
        let frameCount = totalVideoFrames
        let avgGap: TimeInterval = frameCount > 1 ? ptsGapSum / Double(frameCount - 1) : 0
        let fps: Double
        if expectedFrameDuration > 0 {
            fps = 1.0 / expectedFrameDuration
        } else if avgGap > 0 {
            fps = 1.0 / avgGap
        } else {
            fps = 0
        }

        let n = Double(max(frameCount - 1, 1))
        let variance = max(0, (ptsGapSumSquared / n) - (avgGap * avgGap))
        let stdDev = sqrt(variance)

        var syncAvg: Double = 1.0
        if !syncDriftSamples.isEmpty {
            syncAvg = syncDriftSamples.reduce(0, +) / Double(syncDriftSamples.count)
        }

        return JitterSnapshot(
            fps: fps,
            gapMaxMs: maxPTSGap * 1000,
            gapStdDevMs: stdDev * 1000,
            droppedFrameGaps: droppedFrameGaps,
            syncDriftPercent: (syncAvg - 1.0) * 100,
            syncDriftAlerts: syncDriftAlerts
        )
    }
}

// MARK: - Health Report Types

/// Snapshot of jitter metrics for health reporting.
struct JitterSnapshot {
    let fps: Double
    let gapMaxMs: Double
    let gapStdDevMs: Double
    let droppedFrameGaps: Int
    let syncDriftPercent: Double
    let syncDriftAlerts: Int
}

/// Aggregated playback health report with computed verdict.
struct PlaybackHealthReport {
    // Timeline
    let playbackTime: TimeInterval
    let fps: Double
    let wallRate: Double

    // Video health
    let lateFrames: Int
    let droppedFrames: Int
    let resyncs: Int
    let slowFrames: Int

    // Audio health
    let audioStatus: Int  // 0=unknown, 1=rendering, 2=failed
    let audioPullMode: Bool
    let audioAhead: TimeInterval
    let audioDrops: Int
    let audioPath: AudioPath  // decode vs passthrough
    let audioRoute: AudioRoute  // output destination
    let audioPullDeliveries: Int  // total pull-mode deliveries this period

    // Display
    let displayErrors: Int

    // Frame timing (from jitter stats)
    let gapMaxMs: Double
    let gapStdDevMs: Double
    let syncDriftPercent: Double

    enum AudioPath: String {
        case passthrough    // compressed audio sent directly to renderer
        case clientDecode = "decode"  // decoded to PCM by FFmpeg
    }

    enum AudioRoute: String {
        case airPlay = "airplay"
        case hdmi = "hdmi"
        case speaker = "speaker"
    }

    enum Verdict: String {
        case good = "GOOD"
        case warn = "WARN"
        case bad = "BAD"
    }

    var verdict: Verdict {
        // BAD: critical failures — actively losing frames or broken output
        if droppedFrames > 1 { return .bad }
        if resyncs > 0 { return .bad }
        if audioStatus != 1 { return .bad }
        if displayErrors > 0 { return .bad }
        // AirPlay + passthrough = silent audio (renderer accepts but no sound)
        if audioRoute == .airPlay && audioPath == .passthrough { return .bad }
        // Pipeline slow AND buffer exhausted (display layer likely frozen)
        if wallRate < 0.90 && audioAhead < -3.0 { return .bad }

        // WARN: minor issues — pipeline slow or degraded but not catastrophic
        if wallRate < 0.90 { return .warn }
        if lateFrames > 0 { return .warn }
        if droppedFrames > 0 { return .warn }
        // Only warn on negative audioAhead if pipeline isn't recovering
        if audioAhead < 0 && wallRate < 1.0 { return .warn }
        // PTS gaps between consecutive packets can be large due to B-frame reordering
        // (HEVC 7-frame GOPs produce ~290ms gaps at 24fps). Use 500ms as a more
        // meaningful threshold that catches actual decode stalls.
        if gapMaxMs > 500 { return .warn }
        // AirPlay with no pull deliveries AND renderer not rendering = audio stalled
        // (zero deliveries alone is normal — renderer batches requests when it has enough buffered)
        if audioRoute == .airPlay && audioPullMode && audioPullDeliveries == 0 && audioStatus != 1 && playbackTime > 5 { return .warn }

        return .good
    }

    /// Single-line log string for automated parsing.
    var logLine: String {
        "[PlaybackHealth] t=\(f1(playbackTime))s fps=\(f1(fps)) wall=\(f3(wallRate))x " +
        "late=\(lateFrames) drops=\(droppedFrames) resyncs=\(resyncs) slowFrames=\(slowFrames) " +
        "audioStatus=\(audioStatus) audioPull=\(audioPullMode) audioPath=\(audioPath.rawValue) " +
        "audioRoute=\(audioRoute.rawValue) audioAhead=\(f1(audioAhead))s audioDrops=\(audioDrops) " +
        "audioPullDel=\(audioPullDeliveries) displayErr=\(displayErrors) " +
        "gapMax=\(f0(gapMaxMs))ms gapσ=\(f1(gapStdDevMs))ms syncDrift=\(f1(syncDriftPercent))% " +
        "verdict=\(verdict.rawValue)"
    }

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func f3(_ v: Double) -> String { String(format: "%.3f", v) }
}
