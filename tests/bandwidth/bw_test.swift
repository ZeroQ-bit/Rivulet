#!/usr/bin/env swift
//
// URLSession throughput test harness.
//
// Isolates the throughput behavior of URLSessionAVIOSource from FFmpeg
// and all the player machinery. Runs entirely against a local HTTP server
// so the network is not in the picture — any slowness is client-side.
//
// Experiments (pick via CLI args):
//   plain    — URLSession.dataTask completion-handler. Ceiling measurement.
//   delegate — URLSessionDataDelegate didReceive data: only. Chunk delivery.
//   avio     — The URLSessionAVIOSource pattern: chunk queue + NSCondition
//              + consumer thread reading in 1 MB slices.
//   avio-ff  — Same as avio but with simulated FFmpeg processing time
//              (sleep) between reads to model the real read loop.
//   all      — Run all of the above, print a summary table.
//
// Each test downloads `downloadBytes` from `testURL` and reports Mbps
// from first-byte to last-byte.
//

import Foundation

// MARK: - Config

let testURL: URL = {
    if let s = ProcessInfo.processInfo.environment["BW_TEST_URL"],
       let u = URL(string: s) {
        return u
    }
    return URL(string: "http://127.0.0.1:18420/testfile.bin")!
}()

let downloadBytes: Int64 = {
    if let s = ProcessInfo.processInfo.environment["BW_TEST_BYTES"],
       let n = Int64(s) {
        return n
    }
    return 100 * 1024 * 1024
}()

let simulatedFFmpegProcessingMsPerMB: Double = {
    if let s = ProcessInfo.processInfo.environment["BW_TEST_FF_MS_PER_MB"],
       let d = Double(s) {
        return d
    }
    return 20.0
}()

// MARK: - Helpers

struct TestResult {
    let name: String
    let bytes: Int64
    let elapsed: Double
    var mbps: Double { Double(bytes) * 8 / 1_000_000 / elapsed }
    var mbPerSec: Double { Double(bytes) / 1_000_000 / elapsed }
}

func makeConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = .infinity
    config.waitsForConnectivity = true
    config.urlCache = nil
    return config
}

func rangedRequest(offset: Int64 = 0) -> URLRequest {
    var r = URLRequest(url: testURL)
    r.httpMethod = "GET"
    r.addValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
    return r
}

// MARK: - Test 1: plain dataTask with completion handler

func testPlain() -> TestResult {
    let sem = DispatchSemaphore(value: 0)
    var bytes: Int64 = 0
    var firstByte: Date?
    var lastByte: Date?

    let config = makeConfig()
    let session = URLSession(configuration: config)

    let start = Date()
    let task = session.dataTask(with: rangedRequest()) { data, _, error in
        if let error = error {
            print("  ERROR: \(error.localizedDescription)")
        }
        if let data = data {
            bytes = Int64(data.count)
        }
        lastByte = Date()
        sem.signal()
    }
    task.resume()
    sem.wait()

    // completion-handler mode can't give us a true "first byte", so use start.
    firstByte = start
    let elapsed = (lastByte ?? Date()).timeIntervalSince(firstByte!)
    session.invalidateAndCancel()
    return TestResult(name: "plain", bytes: bytes, elapsed: elapsed)
}

// MARK: - Test 2: URLSessionDataDelegate — raw chunk delivery rate

final class DelegateOnly: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var bytes: Int64 = 0
    var chunks: Int = 0
    var firstByte: Date?
    var lastByte: Date?
    let sem = DispatchSemaphore(value: 0)
    let stopAt: Int64

    init(stopAt: Int64) { self.stopAt = stopAt }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if firstByte == nil { firstByte = Date() }
        bytes += Int64(data.count)
        chunks += 1
        lastByte = Date()
        if bytes >= stopAt {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sem.signal()
    }
}

func testDelegate() -> TestResult {
    let delegate = DelegateOnly(stopAt: downloadBytes)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let config = makeConfig()
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)

    let task = session.dataTask(with: rangedRequest())
    task.resume()
    delegate.sem.wait()

    let elapsed = (delegate.lastByte ?? Date()).timeIntervalSince(delegate.firstByte ?? Date())
    print("  chunks=\(delegate.chunks) avgChunk=\(delegate.chunks > 0 ? delegate.bytes / Int64(delegate.chunks) : 0)B")
    session.invalidateAndCancel()
    return TestResult(name: "delegate", bytes: delegate.bytes, elapsed: max(elapsed, 0.0001))
}

// MARK: - Test 3: Our AVIO pattern — chunk queue + NSCondition + consumer thread

final class AVIOPatternSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingChunks: [Data] = []
    private var pendingHead: Int = 0
    private var firstChunkCursor: Int = 0
    private var pendingBytes: Int = 0
    private var totalDelivered: Int64 = 0
    private var isComplete: Bool = false
    private var hasError: Bool = false
    private var isTaskSuspended: Bool = false
    private var currentTask: URLSessionDataTask?
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private var session: URLSession!

    // Stats
    var firstByteTime: Date?
    var lastReadTime: Date?
    var totalReadWaitMs: Double = 0
    var totalReadCopyMs: Double = 0
    var totalReadCalls: Int = 0
    var totalSuspends: Int = 0
    var totalResumes: Int = 0

    init(highWaterMark: Int = 32 * 1024 * 1024, lowWaterMark: Int = 8 * 1024 * 1024) {
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "avio-pattern-delegate"
        self.session = URLSession(configuration: makeConfig(), delegate: self, delegateQueue: queue)
    }

    func start() {
        let task = session.dataTask(with: rangedRequest(offset: 0))
        condition.lock()
        self.currentTask = task
        condition.unlock()
        task.resume()
    }

    func close() {
        condition.lock()
        isComplete = true
        let t = currentTask
        currentTask = nil
        condition.broadcast()
        condition.unlock()
        t?.cancel()
        session.invalidateAndCancel()
    }

    /// FFmpeg-style synchronous read. Returns bytes copied or -1 on EOF.
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        let waitStart = CFAbsoluteTimeGetCurrent()
        condition.lock()
        while pendingBytes == 0 && !isComplete && !hasError {
            condition.wait()
        }
        let waitEnd = CFAbsoluteTimeGetCurrent()

        if pendingBytes == 0 {
            condition.unlock()
            return -1
        }

        var bytesCopied = 0
        var dst = buf
        while bytesCopied < size && pendingHead < pendingChunks.count {
            let chunk = pendingChunks[pendingHead]
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
                pendingHead += 1
                firstChunkCursor = 0
            }
        }
        pendingBytes -= bytesCopied

        if pendingHead >= pendingChunks.count {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingHead = 0
        }

        if isTaskSuspended && pendingBytes <= lowWaterMark {
            isTaskSuspended = false
            totalResumes += 1
            currentTask?.resume()
        }

        let copyEnd = CFAbsoluteTimeGetCurrent()
        totalReadWaitMs += (waitEnd - waitStart) * 1000
        totalReadCopyMs += (copyEnd - waitEnd) * 1000
        totalReadCalls += 1
        lastReadTime = Date()

        condition.unlock()
        return bytesCopied
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        if firstByteTime == nil { firstByteTime = Date() }
        pendingChunks.append(data)
        pendingBytes += data.count
        totalDelivered += Int64(data.count)
        if pendingBytes >= highWaterMark && !isTaskSuspended {
            isTaskSuspended = true
            totalSuspends += 1
            dataTask.suspend()
        }
        condition.signal()
        condition.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        isComplete = true
        if let error, (error as NSError).code != NSURLErrorCancelled {
            hasError = true
        }
        condition.broadcast()
        condition.unlock()
    }
}

func testAVIOPattern(simulateFFmpeg: Bool) -> TestResult {
    let source = AVIOPatternSource()
    source.start()

    let bufferSize = 1024 * 1024  // 1 MB, same as our real AVIO
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var totalRead: Int64 = 0
    var firstReadBegan: Date?
    let startWall = Date()

    while totalRead < downloadBytes {
        if firstReadBegan == nil { firstReadBegan = Date() }
        let n = source.read(into: buffer, size: bufferSize)
        if n <= 0 { break }
        totalRead += Int64(n)
        if simulateFFmpeg {
            // Emulate FFmpeg spending a few ms per MB on matroska parsing,
            // side-data copies, etc. Matches order of magnitude of the
            // observed avReadAvg vs bytes/read pattern.
            let megabytes = Double(n) / (1024.0 * 1024.0)
            let sleepMs = megabytes * simulatedFFmpegProcessingMsPerMB
            if sleepMs > 0 {
                Thread.sleep(forTimeInterval: sleepMs / 1000.0)
            }
        }
    }

    source.close()
    let elapsed = Date().timeIntervalSince(firstReadBegan ?? startWall)

    let avgWaitMs = source.totalReadCalls > 0 ? source.totalReadWaitMs / Double(source.totalReadCalls) : 0
    let avgCopyMs = source.totalReadCalls > 0 ? source.totalReadCopyMs / Double(source.totalReadCalls) : 0
    print("  reads=\(source.totalReadCalls) avgWait=\(String(format: "%.2f", avgWaitMs))ms avgCopy=\(String(format: "%.2f", avgCopyMs))ms suspends=\(source.totalSuspends) resumes=\(source.totalResumes)")

    return TestResult(name: simulateFFmpeg ? "avio-ff" : "avio",
                      bytes: totalRead, elapsed: elapsed)
}

// MARK: - Driver

func formatResult(_ r: TestResult) -> String {
    let mbFormatted = String(format: "%6.1f MB", Double(r.bytes) / 1_000_000)
    let elapsedFormatted = String(format: "%5.2fs", r.elapsed)
    let mbpsFormatted = String(format: "%7.1f Mbps", r.mbps)
    return "\(r.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(mbFormatted)  \(elapsedFormatted)  \(mbpsFormatted)"
}

let args = CommandLine.arguments.dropFirst()
let tests: [String]
if args.isEmpty || args.contains("all") {
    tests = ["plain", "delegate", "avio", "avio-ff"]
} else {
    tests = Array(args)
}

print("BW test harness: url=\(testURL.absoluteString) target=\(downloadBytes / 1024 / 1024) MB  ffDelayPerMB=\(simulatedFFmpegProcessingMsPerMB) ms")
print(String(repeating: "-", count: 60))

var results: [TestResult] = []
for t in tests {
    print("\nRunning: \(t)")
    switch t {
    case "plain":    results.append(testPlain())
    case "delegate": results.append(testDelegate())
    case "avio":     results.append(testAVIOPattern(simulateFFmpeg: false))
    case "avio-ff":  results.append(testAVIOPattern(simulateFFmpeg: true))
    default:         print("Unknown test: \(t)")
    }
}

print("\n" + String(repeating: "=", count: 60))
print("Test       Bytes    Elapsed  Throughput")
print(String(repeating: "-", count: 60))
for r in results { print(formatResult(r)) }
