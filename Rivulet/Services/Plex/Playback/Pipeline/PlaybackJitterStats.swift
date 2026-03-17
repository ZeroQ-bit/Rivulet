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
            print(
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
            print("📊 [Jitter] ⏱️ Enqueue stall: \(String(format: "%.0f", duration * 1000))ms (frame \(totalVideoFrames))")
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
                print(
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

        print(
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
}
