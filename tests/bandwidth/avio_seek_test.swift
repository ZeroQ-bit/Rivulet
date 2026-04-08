#!/usr/bin/env swift
//
// Reproduces URLSessionAVIOSource's seek/drain/auto-restart behavior in a
// standalone Swift script so we can test the production logic against
// mock_plex_server without needing FFmpeg or a device. Content verification
// piggybacks on the server's deterministic byte pattern (pos & 0xFF), so a
// bad seek surfaces as a byte-mismatch assertion.
//
// Test scenarios (picked via CLI arg):
//   healthy     — straight sequential read from a healthy server.
//   truncating  — server closes the response after N bytes; we should
//                 auto-restart and still read the full file.
//   slow        — server rate-limited to 50 Mbps; sanity check throughput.
//   seeky       — simulates matroska's small-forward-skip pattern: read
//                 1 MB, seek forward by 100 KB, read 1 MB, seek forward by
//                 50 KB, etc. Measures whether drain-forward avoids the
//                 per-seek GET overhead.
//   seeky-noop  — same as seeky but uses the legacy path (always cancels
//                 and restarts) for comparison.
//
// Usage:
//   swift mock_plex_server.swift &       # start server in another terminal
//   swift avio_seek_test.swift healthy
//

import Foundation

// MARK: - Config

let baseURL = URL(string: ProcessInfo.processInfo.environment["AVIO_TEST_URL"]
                  ?? "http://127.0.0.1:18421/testfile.bin")!
let targetBytes: Int64 = Int64(ProcessInfo.processInfo.environment["AVIO_TEST_BYTES"] ?? "") ?? (50 * 1024 * 1024)
let verifyBytes = (ProcessInfo.processInfo.environment["AVIO_TEST_VERIFY"] ?? "1") == "1"

// MARK: - AVIO source (adapted copy of the production class)

final class TestAVIOSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingChunks: [Data] = []
    private var pendingChunksHead: Int = 0
    private var pendingChunkBytes: Int = 0
    private var firstChunkCursor: Int = 0
    private var absolutePosition: Int64 = 0
    private var totalContentLength: Int64 = -1
    private var generation: UInt64 = 0
    private var isComplete: Bool = false
    private var fetchError: Error?
    private var isTaskSuspended: Bool = false
    private var currentTask: URLSessionDataTask?
    private var closed: Bool = false
    private var session: URLSession!
    private let url: URL
    private let highWaterMark: Int
    private let lowWaterMark: Int

    /// When true, forward seeks that land within the already-buffered
    /// data advance a cursor instead of issuing a new HTTP request.
    /// Anything beyond the buffer always restarts.
    var enableForwardDrain: Bool = true

    // Diagnostics
    var totalBytesDelivered: Int64 = 0
    var totalBytesConsumed: Int64 = 0
    var totalSuspends: Int = 0
    var totalResumes: Int = 0
    var totalSeeks: Int = 0
    var totalRestartsForTruncation: Int = 0
    var totalDrainedSeeks: Int = 0
    var totalRestartedSeeks: Int = 0

    init(url: URL,
         highWaterMark: Int = 32 * 1024 * 1024,
         lowWaterMark: Int = 8 * 1024 * 1024) {
        self.url = url
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = .infinity
        cfg.urlCache = nil
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "test-avio-delegate"
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
        start(atOffset: 0)
    }

    private func start(atOffset offset: Int64) {
        condition.lock()
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunksHead = 0
        pendingChunkBytes = 0
        firstChunkCursor = 0
        absolutePosition = offset
        isComplete = false
        fetchError = nil
        isTaskSuspended = false
        generation &+= 1
        let gen = generation
        condition.unlock()

        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.addValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: r)
        task.taskDescription = String(gen)
        condition.lock()
        self.currentTask = task
        condition.unlock()
        task.resume()
    }

    func close() {
        condition.lock()
        if closed { condition.unlock(); return }
        closed = true
        let t = self.currentTask
        self.currentTask = nil
        isComplete = true
        condition.broadcast()
        condition.unlock()
        t?.cancel()
        session.invalidateAndCancel()
    }

    /// Read up to `size` bytes into `buf`. Returns bytes copied, or -1 on EOF.
    /// Silently auto-restarts the fetch on unexpected short responses.
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        guard size > 0 else { return 0 }
        var autoRestartAttempts = 0
        let maxRestarts = 5

        while true {
            condition.lock()
            while pendingChunkBytes == 0 && !isComplete && fetchError == nil && !closed {
                condition.wait()
            }
            if pendingChunkBytes > 0 { break }

            let reachedEnd = totalContentLength >= 0 && absolutePosition >= totalContentLength
            let canRestart = isComplete && fetchError == nil && !closed && !reachedEnd
                && autoRestartAttempts < maxRestarts
            if !canRestart { condition.unlock(); return -1 }
            let restartAt = absolutePosition
            condition.unlock()
            autoRestartAttempts += 1
            totalRestartsForTruncation += 1
            start(atOffset: restartAt)
        }

        var bytesCopied = 0
        var dst = buf
        while bytesCopied < size && pendingChunksHead < pendingChunks.count {
            let chunk = pendingChunks[pendingChunksHead]
            let available = chunk.count - firstChunkCursor
            let toCopy = min(available, size - bytesCopied)
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst, base.advanced(by: firstChunkCursor), toCopy)
            }
            dst = dst.advanced(by: toCopy)
            bytesCopied += toCopy
            firstChunkCursor += toCopy
            if firstChunkCursor >= chunk.count {
                pendingChunksHead += 1
                firstChunkCursor = 0
            }
        }
        pendingChunkBytes -= bytesCopied
        absolutePosition += Int64(bytesCopied)
        totalBytesConsumed += Int64(bytesCopied)

        if pendingChunksHead >= pendingChunks.count {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingChunksHead = 0
        }

        if isTaskSuspended && pendingChunkBytes <= lowWaterMark {
            isTaskSuspended = false
            totalResumes += 1
            currentTask?.resume()
        }

        condition.unlock()
        return bytesCopied
    }

    /// Seek the underlying stream. Returns the new position, or -1 on
    /// failure. Short forward seeks are satisfied by draining the buffer
    /// instead of restarting, controlled by `enableForwardDrain`.
    func seek(to offset: Int64) -> Int64 {
        condition.lock()
        let currentPos = absolutePosition
        condition.unlock()

        if offset == currentPos { return currentPos }
        let delta = offset - currentPos

        if enableForwardDrain && delta > 0 {
            condition.lock()
            let canDrainInBuffer = Int64(pendingChunkBytes) >= delta
            condition.unlock()
            if canDrainInBuffer {
                let drained = drainForward(byteCount: delta)
                if drained == delta {
                    totalDrainedSeeks += 1
                    return offset
                }
            }
        }

        condition.lock()
        let oldTask = self.currentTask
        self.currentTask = nil
        totalSeeks += 1
        totalRestartedSeeks += 1
        condition.unlock()
        oldTask?.cancel()
        start(atOffset: offset)
        return offset
    }

    private func drainForward(byteCount: Int64) -> Int64 {
        var remaining = byteCount
        condition.lock()
        defer { condition.unlock() }
        while remaining > 0 {
            while pendingChunkBytes == 0 && !isComplete && fetchError == nil && !closed {
                condition.wait()
            }
            if pendingChunkBytes == 0 { break }
            while remaining > 0 && pendingChunksHead < pendingChunks.count {
                let chunk = pendingChunks[pendingChunksHead]
                let available = chunk.count - firstChunkCursor
                let toSkip = Int(min(Int64(available), remaining))
                firstChunkCursor += toSkip
                pendingChunkBytes -= toSkip
                absolutePosition += Int64(toSkip)
                remaining -= Int64(toSkip)
                if firstChunkCursor >= chunk.count {
                    pendingChunksHead += 1
                    firstChunkCursor = 0
                }
            }
            if pendingChunksHead >= pendingChunks.count {
                pendingChunks.removeAll(keepingCapacity: true)
                pendingChunksHead = 0
            }
            if isTaskSuspended && pendingChunkBytes <= lowWaterMark {
                isTaskSuspended = false
                totalResumes += 1
                currentTask?.resume()
            }
        }
        return byteCount - remaining
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let tag = dataTask.taskDescription,
              let taskGen = UInt64(tag) else { completionHandler(.cancel); return }
        condition.lock()
        let isCurrent = taskGen == generation
        condition.unlock()
        guard isCurrent else { completionHandler(.cancel); return }

        if let http = response as? HTTPURLResponse {
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slashIdx = range.lastIndex(of: "/") {
                let totalStr = range[range.index(after: slashIdx)...]
                if let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                    condition.lock()
                    totalContentLength = total
                    condition.unlock()
                }
            } else if http.expectedContentLength > 0 {
                condition.lock()
                totalContentLength = http.expectedContentLength + absolutePosition
                condition.unlock()
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let tag = dataTask.taskDescription,
              let taskGen = UInt64(tag) else { return }
        condition.lock()
        guard taskGen == generation, !closed else {
            condition.unlock(); return
        }
        pendingChunks.append(data)
        pendingChunkBytes += data.count
        totalBytesDelivered += Int64(data.count)
        if pendingChunkBytes >= highWaterMark && !isTaskSuspended {
            isTaskSuspended = true
            totalSuspends += 1
            dataTask.suspend()
        }
        condition.signal()
        condition.unlock()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let tag = task.taskDescription,
              let taskGen = UInt64(tag) else { return }
        condition.lock()
        guard taskGen == generation else { condition.unlock(); return }
        isComplete = true
        if let error, (error as NSError).code != NSURLErrorCancelled {
            fetchError = error
        }
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - Content verification

func verifyRegion(buffer: UnsafeMutablePointer<UInt8>, length: Int, startingAt position: Int64) {
    guard verifyBytes else { return }
    for i in 0..<length {
        let expected = UInt8((position + Int64(i)) & 0xFF)
        if buffer[i] != expected {
            print("!! MISMATCH at pos=\(position + Int64(i)) expected=\(expected) got=\(buffer[i])")
            exit(2)
        }
    }
}

// MARK: - Tests

struct ScenarioResult {
    let scenario: String
    let bytesConsumed: Int64
    let elapsed: Double
    let drainedSeeks: Int
    let restartedSeeks: Int
    let autoRestarts: Int
    var mbps: Double { Double(bytesConsumed) * 8 / 1_000_000 / elapsed }
}

func runHealthy(source: TestAVIOSource) -> ScenarioResult {
    let bufSize = 1024 * 1024
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    var total: Int64 = 0
    let start = Date()
    while total < targetBytes {
        let n = source.read(into: buf, size: bufSize)
        if n <= 0 { break }
        verifyRegion(buffer: buf, length: n, startingAt: total)
        total += Int64(n)
    }
    let elapsed = Date().timeIntervalSince(start)
    return ScenarioResult(
        scenario: "sequential",
        bytesConsumed: total, elapsed: elapsed,
        drainedSeeks: source.totalDrainedSeeks,
        restartedSeeks: source.totalRestartedSeeks,
        autoRestarts: source.totalRestartsForTruncation
    )
}

/// Simulates matroska's small-forward-skip pattern.
/// Read 1 MB, forward-seek 200 KB, read 1 MB, forward-seek 100 KB, repeat.
func runSeeky(source: TestAVIOSource) -> ScenarioResult {
    let bufSize = 1024 * 1024
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    var pos: Int64 = 0
    var total: Int64 = 0
    let seekDistances: [Int64] = [200 * 1024, 100 * 1024, 400 * 1024, 50 * 1024, 150 * 1024]
    var seekIdx = 0
    let start = Date()
    while total < targetBytes {
        let n = source.read(into: buf, size: bufSize)
        if n <= 0 { break }
        verifyRegion(buffer: buf, length: n, startingAt: pos)
        pos += Int64(n)
        total += Int64(n)

        // Forward-seek after each 1 MB read to emulate matroska walker
        let skip = seekDistances[seekIdx % seekDistances.count]
        seekIdx += 1
        let target = pos + skip
        let newPos = source.seek(to: target)
        if newPos != target { break }
        pos = newPos
    }
    let elapsed = Date().timeIntervalSince(start)
    return ScenarioResult(
        scenario: "seeky",
        bytesConsumed: total, elapsed: elapsed,
        drainedSeeks: source.totalDrainedSeeks,
        restartedSeeks: source.totalRestartedSeeks,
        autoRestarts: source.totalRestartsForTruncation
    )
}

// MARK: - Driver

let scenario = CommandLine.arguments.dropFirst().first ?? "healthy"
print("=== avio_seek_test scenario=\(scenario) url=\(baseURL.absoluteString) target=\(targetBytes) ===")

let source = TestAVIOSource(url: baseURL)
let result: ScenarioResult

switch scenario {
case "healthy", "truncating", "slow":
    result = runHealthy(source: source)
case "seeky":
    source.enableForwardDrain = true
    result = runSeeky(source: source)
case "seeky-noop":
    source.enableForwardDrain = false
    result = runSeeky(source: source)
default:
    print("Unknown scenario: \(scenario)")
    exit(1)
}

source.close()

print(String(
    format: "result: scenario=%@  bytes=%.1f MB  elapsed=%.2fs  mbps=%.1f  drainedSeeks=%d  restartedSeeks=%d  autoRestarts=%d  delivered=%.1f MB",
    result.scenario,
    Double(result.bytesConsumed) / 1_000_000,
    result.elapsed, result.mbps,
    result.drainedSeeks, result.restartedSeeks, result.autoRestarts,
    Double(source.totalBytesDelivered) / 1_000_000
))
