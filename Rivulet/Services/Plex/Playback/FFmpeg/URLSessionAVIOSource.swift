//
//  URLSessionAVIOSource.swift
//  Rivulet
//
//  Bridges Apple's URLSession into FFmpeg's libavformat via a custom
//  AVIOContext. Replaces libavformat's built-in HTTP protocol, which was
//  observed to cap at ~7 Mbps per connection on tvOS while URLSession can
//  saturate the link at the same URL when fed enough parallelism.
//
//  Design:
//   - Byte fetches are broken into fixed-size `Segment`s (e.g. 4 MB each).
//     We keep up to `maxConcurrentSegments` active simultaneously for
//     consecutive byte ranges. Each segment is its own URLSessionDataTask.
//   - FFmpeg reads sequentially from the head segment; when it drains we
//     promote the next segment to head and kick off a new tail segment.
//     Behind the scenes multiple TCP connections are delivering bytes in
//     parallel, which lets us exceed a per-connection throughput cap.
//   - Backpressure: we cap the buffered byte window ahead of the current
//     read position, so memory stays O(targetBufferedBytes).
//   - `seek(offset:whence:)` cancels every in-flight segment and restarts
//     the pipeline at the new offset. Small forward seeks that land within
//     already-buffered bytes just advance the cursor.
//   - Unexpected short responses on a segment trigger a silent per-segment
//     re-fetch at the current position. Bounded retries prevent infinite
//     loops if the server is permanently broken.
//

import Foundation

#if RIVULET_FFMPEG
import Libavformat
import Libavutil

/// Feeds bytes from URLSession into an FFmpeg AVIOContext.
/// The object is retained by the AVIOContext's opaque pointer for its
/// lifetime; `freeAVIOContext(_:)` releases the retain.
nonisolated final class URLSessionAVIOSource: NSObject, @unchecked Sendable {

    // MARK: - Config

    private let url: URL
    private let headers: [String: String]?
    /// Size of a single pipeline segment. Smaller = more overhead but
    /// finer-grained pipelining; larger = less overhead but slower head
    /// promotion.
    private let segmentSize: Int64
    /// Number of segments we try to keep in flight simultaneously. `1`
    /// disables parallelism and behaves like the original single-task
    /// implementation.
    private let maxConcurrentSegments: Int
    /// Maximum byte window we try to keep allocated ahead of the current
    /// read position. This can exceed `maxConcurrentSegments × segmentSize`
    /// because completed tail segments may stay queued while the head is
    /// still being consumed.
    private let targetBufferedBytes: Int64

    // MARK: - Segment

    private final class Segment {
        /// Monotonic ID — matches `taskDescription` on the URLSession task
        /// so delegate callbacks can find their segment cheaply.
        let id: UInt64
        /// Absolute byte offset of the first byte in this segment.
        let startOffset: Int64
        /// Number of bytes we expect this segment to deliver. Bounded by
        /// the resource's declared total length.
        var length: Int64
        /// Data chunks received but not yet consumed. Drained via
        /// `chunksHead` rather than `removeFirst()`.
        var chunks: [Data] = []
        var chunksHead: Int = 0
        var firstChunkCursor: Int = 0
        /// Bytes currently sitting in `chunks` but not yet consumed.
        var bytesInBuffer: Int = 0
        /// Total bytes delivered by URLSession for this segment so far
        /// (both consumed and still buffered).
        var bytesDelivered: Int64 = 0
        var task: URLSessionDataTask?
        var isComplete: Bool = false
        var fetchError: Error?
        var retryCount: Int = 0

        init(id: UInt64, startOffset: Int64, length: Int64) {
            self.id = id
            self.startOffset = startOffset
            self.length = length
        }

        /// Byte offset one past the last byte that the head-position
        /// tracking has already advanced over (the caller's absolute read
        /// position, relative to this segment).
        var nextUnreadOffsetInSegment: Int64 {
            length - Int64(bytesInBuffer) - (bytesDelivered - Int64(bytesInBuffer) - Int64(bytesInBuffer))
        }
    }

    // MARK: - State (guarded by `condition`)

    private let condition = NSCondition()
    /// In-flight segments in ascending byte order. Index 0 is the head.
    private var segments: [Segment] = []
    /// Byte offset immediately after the tail of the last queued segment.
    /// Initialized to the pipeline start offset.
    private var nextSegmentStart: Int64 = 0
    /// Absolute byte offset of the next byte FFmpeg will read.
    private var absolutePosition: Int64 = 0
    /// Total size of the resource; -1 until learned from a response header.
    private var totalContentLength: Int64 = -1
    /// Monotonically increasing segment ID, used as `taskDescription` so
    /// delegate callbacks can locate their segment cheaply.
    private var nextSegmentID: UInt64 = 0
    /// Bumped whenever we re-kick the pipeline (seek or close). Segments
    /// from earlier generations are treated as cancelled.
    private var pipelineGeneration: UInt64 = 0
    private var closed: Bool = false

    /// Assigned in `init` after `super.init()` completes so URLSession can
    /// capture `self` as its delegate.
    private var session: URLSession!

    // Diagnostics
    private var totalBytesDelivered: Int64 = 0
    private var totalBytesConsumed: Int64 = 0
    private var totalReadCalls: Int = 0
    private var totalReadWaitMicros: Int64 = 0
    private var totalReadCopyMicros: Int64 = 0
    private var totalReadZeroWaitCalls: Int = 0
    private var totalSeekCount: Int = 0
    private var totalSegmentStarts: Int = 0
    private var totalSegmentRetries: Int = 0
    private var totalDelegateDeliveries: Int = 0
    private var totalDelegateInterArrivalMicros: Int64 = 0
    private var lastDelegateDeliveryWall: CFAbsoluteTime = 0
    private var maxDelegateChunkBytes: Int = 0
    private var minDelegateChunkBytes: Int = Int.max
    private var diagLastReportWall: CFAbsoluteTime = 0
    private var diagLastDeliveredBytes: Int64 = 0
    private var diagLastConsumedBytes: Int64 = 0
    private var diagLastDeliveries: Int = 0
    private var diagStartWall: CFAbsoluteTime = 0
    private static let diagReportIntervalSeconds: Double = 2.0
    private static let maxSegmentRetries: Int = 5

    // MARK: - Init

    nonisolated init(url: URL,
         headers: [String: String]? = nil,
         segmentSize: Int64 = 4 * 1024 * 1024,
         maxConcurrentSegments: Int = 8,
         targetBufferedBytes: Int64 = 64 * 1024 * 1024) {
        self.url = url
        self.headers = headers
        self.segmentSize = segmentSize
        self.maxConcurrentSegments = maxConcurrentSegments
        self.targetBufferedBytes = max(targetBufferedBytes, segmentSize * Int64(maxConcurrentSegments))
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.networkServiceType = .avStreaming
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        // Allow enough parallel connections for the pipeline + any other
        // in-flight requests against the same host.
        config.httpMaximumConnectionsPerHost = max(8, maxConcurrentSegments * 2)

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "rivulet.urlsession-avio.delegate"

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        playerDebugLog(String(
            format: "[URLSessionAVIO] Config: segment=%.1fMB activeReq=%d targetWindow=%.1fMB",
            Double(segmentSize) / (1024 * 1024),
            maxConcurrentSegments,
            Double(self.targetBufferedBytes) / (1024 * 1024)
        ))

        kickoffPipeline(atOffset: 0)
    }

    deinit {
        close()
    }

    // MARK: - Pipeline management

    /// Cancel every segment and start a fresh pipeline at `offset`.
    private func kickoffPipeline(atOffset offset: Int64) {
        condition.lock()
        pipelineGeneration &+= 1
        for seg in segments {
            seg.task?.cancel()
        }
        segments.removeAll(keepingCapacity: true)
        absolutePosition = offset
        nextSegmentStart = offset
        condition.unlock()

        refillPipeline()
    }

    /// Number of requests that still have an active URLSession task.
    /// Call under `condition.lock()`.
    private func activeRequestCountLocked() -> Int {
        segments.reduce(0) { partial, seg in
            partial + ((seg.task != nil && !seg.isComplete) ? 1 : 0)
        }
    }

    /// Total byte window currently covered from the next FFmpeg read
    /// position to the tail of the last queued segment.
    /// Call under `condition.lock()`.
    private func bufferedWindowBytesLocked() -> Int64 {
        max(0, nextSegmentStart - absolutePosition)
    }

    /// Allocate another tail segment if we still need more parallel work
    /// or more covered bytes ahead of the read head.
    /// Call under `condition.lock()`.
    private func makeNextSegmentTaskLockedIfPossible() -> URLSessionDataTask? {
        if closed { return nil }
        if activeRequestCountLocked() >= maxConcurrentSegments { return nil }
        if totalContentLength >= 0 && nextSegmentStart >= totalContentLength { return nil }

        let windowBytes = bufferedWindowBytesLocked()
        if windowBytes >= targetBufferedBytes { return nil }

        let start = nextSegmentStart
        var len = min(segmentSize, targetBufferedBytes - windowBytes)
        if totalContentLength >= 0 {
            len = min(len, totalContentLength - start)
        }
        guard len > 0 else { return nil }

        nextSegmentID &+= 1
        let id = nextSegmentID
        let gen = pipelineGeneration
        let segment = Segment(id: id, startOffset: start, length: len)
        segments.append(segment)
        nextSegmentStart = start + len
        totalSegmentStarts += 1
        let task = makeDataTask(for: segment, generation: gen)
        segment.task = task
        return task
    }

    /// Start tail segments until both the active-request count and the
    /// buffered byte window are topped up.
    private func refillPipeline() {
        var tasks: [URLSessionDataTask] = []
        condition.lock()
        while let task = makeNextSegmentTaskLockedIfPossible() {
            tasks.append(task)
        }
        condition.unlock()

        for task in tasks {
            task.resume()
        }
    }

    /// Replace the head segment with a fresh re-fetch from the current
    /// absolute read position. Called when the head segment ends before
    /// delivering `length` bytes (observed: Plex sometimes closes
    /// `Range: bytes=N-` responses early).
    private func retryHeadSegment() {
        condition.lock()
        guard !segments.isEmpty, !closed else { condition.unlock(); return }
        let head = segments[0]
        let alreadyConsumedInHead = absolutePosition - head.startOffset
        let remaining = head.length - alreadyConsumedInHead
        guard remaining > 0 else { condition.unlock(); return }
        head.task?.cancel()
        head.chunks.removeAll(keepingCapacity: true)
        head.chunksHead = 0
        head.firstChunkCursor = 0
        head.bytesInBuffer = 0
        head.bytesDelivered = 0
        head.isComplete = false
        head.fetchError = nil
        head.retryCount += 1
        totalSegmentRetries += 1
        let newStart = absolutePosition
        let newLen = remaining
        nextSegmentID &+= 1
        head.task = nil
        // We can't reassign `head` fields, so rewrite in place:
        let replacement = Segment(id: nextSegmentID, startOffset: newStart, length: newLen)
        replacement.retryCount = head.retryCount
        segments[0] = replacement
        let gen = pipelineGeneration
        condition.unlock()

        playerDebugLog(String(
            format: "[URLSessionAVIO] Head segment truncated — retrying start=%lld len=%lld attempt=%d",
            newStart, newLen, replacement.retryCount
        ))
        let task = makeDataTask(for: replacement, generation: gen)
        condition.lock()
        // Only attach if the pipeline wasn't re-kicked meanwhile.
        if !segments.isEmpty && segments[0].id == replacement.id && pipelineGeneration == gen {
            segments[0].task = task
        } else {
            task.cancel()
            condition.unlock()
            return
        }
        condition.unlock()
        task.resume()
    }

    private func makeDataTask(for segment: Segment, generation: UInt64) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let rangeEnd = segment.startOffset + segment.length - 1
        request.addValue("bytes=\(segment.startOffset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        if let headers {
            for (k, v) in headers {
                request.addValue(v, forHTTPHeaderField: k)
            }
        }
        let task = session.dataTask(with: request)
        // `gen:segmentID` lets the delegate filter out both stale
        // generations and any cancelled segments from previous retries.
        task.taskDescription = "\(generation):\(segment.id)"
        return task
    }

    /// Advance past any fully-drained head segments and top the pipeline
    /// back up to the concurrency limit.
    ///
    /// Call under `condition.lock()`; returns with the lock still held.
    private func advanceHeadIfDrainedLocked() {
        while !segments.isEmpty {
            let head = segments[0]
            let fullyReceived = head.isComplete && head.bytesDelivered >= head.length
            let fullyDrained = head.bytesInBuffer == 0
            if !fullyReceived || !fullyDrained { return }
            segments.removeFirst()
        }
    }

    /// Cancel every task and release URLSession. Safe to call multiple times.
    func close() {
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        closed = true
        pipelineGeneration &+= 1
        let toCancel = segments.compactMap { $0.task }
        segments.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()

        for task in toCancel { task.cancel() }
        session?.invalidateAndCancel()
    }

    // MARK: - FFmpeg entry points

    /// Synchronously read up to `size` bytes into `buf`. Blocks until at
    /// least one byte is available, the head segment errors out, or the
    /// resource is fully drained. Returns the number of bytes copied, or
    /// `AVERROR_EOF_VALUE` on EOF.
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int) -> Int32 {
        guard size > 0 else { return 0 }

        let callStart = CFAbsoluteTimeGetCurrent()
        var hadDataImmediately = false
        var afterWait: CFAbsoluteTime = 0

        // Outer loop: if the head segment finishes short of its declared
        // length, retry it at `absolutePosition` and keep going. Retries
        // are bounded per segment.
        while true {
            condition.lock()

            // Discard any fully-drained head segments before deciding
            // whether to wait.
            advanceHeadIfDrainedLocked()

            if segments.isEmpty {
                // Either fully EOF or we've never started. If we've reached
                // the declared end, return EOF; otherwise try to kick off a
                // new pipeline segment.
                if totalContentLength >= 0 && absolutePosition >= totalContentLength {
                    condition.unlock()
                    return AVERROR_EOF_VALUE
                }
                if closed {
                    condition.unlock()
                    return AVERROR_EOF_VALUE
                }
                condition.unlock()
                refillPipeline()
                continue
            }

            let head = segments[0]
            hadDataImmediately = head.bytesInBuffer > 0
            while head.bytesInBuffer == 0 && !head.isComplete && head.fetchError == nil && !closed {
                condition.wait()
            }
            afterWait = CFAbsoluteTimeGetCurrent()

            if head.bytesInBuffer > 0 {
                break  // proceed to copy
            }

            // Buffer empty. Complete + short = retry. Complete + full =
            // advance. Error = propagate.
            if head.fetchError != nil && head.retryCount >= Self.maxSegmentRetries {
                condition.unlock()
                return AVERROR_EOF_VALUE
            }
            if head.isComplete {
                if head.bytesDelivered >= head.length {
                    condition.unlock()
                    // advanceHead on next iteration will drop it.
                    continue
                }
                // Short delivery — retry this segment unless we've already
                // retried too many times.
                if head.retryCount >= Self.maxSegmentRetries {
                    condition.unlock()
                    return AVERROR_EOF_VALUE
                }
                condition.unlock()
                retryHeadSegment()
                continue
            }
            condition.unlock()
        }

        // We are holding the lock and the head segment has bytes.
        let head = segments[0]
        var bytesCopied = 0
        var destCursor = buf
        while bytesCopied < size && head.chunksHead < head.chunks.count {
            let chunk = head.chunks[head.chunksHead]
            let available = chunk.count - head.firstChunkCursor
            let toCopy = min(available, size - bytesCopied)
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(destCursor, base.advanced(by: head.firstChunkCursor), toCopy)
            }
            destCursor = destCursor.advanced(by: toCopy)
            bytesCopied += toCopy
            head.firstChunkCursor += toCopy
            if head.firstChunkCursor >= chunk.count {
                head.chunksHead += 1
                head.firstChunkCursor = 0
            }
        }
        head.bytesInBuffer -= bytesCopied
        absolutePosition += Int64(bytesCopied)

        if head.chunksHead >= head.chunks.count {
            head.chunks.removeAll(keepingCapacity: true)
            head.chunksHead = 0
        }

        let fullyDrained = head.isComplete && head.bytesDelivered >= head.length && head.bytesInBuffer == 0
        if fullyDrained {
            advanceHeadIfDrainedLocked()
        }
        let callEnd = CFAbsoluteTimeGetCurrent()
        totalBytesConsumed += Int64(bytesCopied)
        totalReadCalls += 1
        totalReadWaitMicros += Int64((afterWait - callStart) * 1_000_000)
        totalReadCopyMicros += Int64((callEnd - afterWait) * 1_000_000)
        if hadDataImmediately { totalReadZeroWaitCalls += 1 }

        emitThroughputDiagIfNeededLocked()

        condition.unlock()

        refillPipeline()
        return Int32(bytesCopied)
    }

    /// Called under `condition.lock()`.
    private func emitThroughputDiagIfNeededLocked() {
        let now = CFAbsoluteTimeGetCurrent()
        if diagStartWall == 0 { diagStartWall = now }
        if diagLastReportWall == 0 { diagLastReportWall = now }
        let elapsed = now - diagLastReportWall
        if elapsed < Self.diagReportIntervalSeconds { return }

        let deliveredDelta = totalBytesDelivered - diagLastDeliveredBytes
        let consumedDelta = totalBytesConsumed - diagLastConsumedBytes
        let deliveredMbps = Double(deliveredDelta) * 8 / 1_000_000 / elapsed
        let consumedMbps = Double(consumedDelta) * 8 / 1_000_000 / elapsed
        let avgWaitMs = totalReadCalls > 0
            ? Double(totalReadWaitMicros) / Double(totalReadCalls) / 1000
            : 0
        let blockingRatio = totalReadCalls > 0
            ? 1.0 - Double(totalReadZeroWaitCalls) / Double(totalReadCalls)
            : 0
        let bufferedMB = Double(segments.reduce(0) { $0 + $1.bytesInBuffer }) / (1024 * 1024)
        let windowMB = Double(bufferedWindowBytesLocked()) / (1024 * 1024)
        let activeReqs = activeRequestCountLocked()
        let retainedSegments = segments.count
        let deliveriesDelta = totalDelegateDeliveries - diagLastDeliveries
        let deliveryRatePerSec = Double(deliveriesDelta) / elapsed
        let avgChunkBytes = deliveriesDelta > 0 ? deliveredDelta / Int64(deliveriesDelta) : 0

        playerDebugLog(String(
            format: "[URLSessionAVIODiag] delivered=%.1fMbps consumed=%.1fMbps bufferedMB=%.2f windowMB=%.2f activeReq=%d retained=%d reads=%d avgWait=%.2fms blockRatio=%.0f%% deliveries/s=%.0f avgChunk=%lldB minChunk=%dB maxChunk=%dB segStarts=%d segRetries=%d seeks=%d",
            deliveredMbps, consumedMbps, bufferedMB, windowMB, activeReqs, retainedSegments, totalReadCalls,
            avgWaitMs, blockingRatio * 100,
            deliveryRatePerSec, avgChunkBytes,
            minDelegateChunkBytes == Int.max ? 0 : minDelegateChunkBytes,
            maxDelegateChunkBytes,
            totalSegmentStarts, totalSegmentRetries, totalSeekCount
        ))

        diagLastReportWall = now
        diagLastDeliveredBytes = totalBytesDelivered
        diagLastConsumedBytes = totalBytesConsumed
        diagLastDeliveries = totalDelegateDeliveries
    }

    /// Seek to an absolute byte position. Implements `SEEK_SET`,
    /// `SEEK_CUR`, `SEEK_END`, and `AVSEEK_SIZE`. Returns the new position
    /// or -1 on failure.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        if (whence & AVSEEK_SIZE_VALUE) != 0 {
            condition.lock()
            let len = totalContentLength
            condition.unlock()
            return len >= 0 ? len : -1
        }

        let mode = whence & ~AVSEEK_FORCE_VALUE
        var newOffset: Int64 = -1
        condition.lock()
        let currentPos = absolutePosition
        let contentLen = totalContentLength
        condition.unlock()

        switch mode {
        case Int32(SEEK_SET): newOffset = offset
        case Int32(SEEK_CUR): newOffset = currentPos + offset
        case Int32(SEEK_END):
            guard contentLen >= 0 else { return -1 }
            newOffset = contentLen + offset
        default: return -1
        }
        guard newOffset >= 0 else { return -1 }
        if newOffset == currentPos { return newOffset }

        let delta = newOffset - currentPos

        // Forward drain within the head segment's pending buffer.
        if delta > 0 {
            condition.lock()
            if let head = segments.first, Int64(head.bytesInBuffer) >= delta {
                // Skip `delta` bytes from head by advancing the cursor.
                var remaining = Int(delta)
                while remaining > 0 && head.chunksHead < head.chunks.count {
                    let chunk = head.chunks[head.chunksHead]
                    let available = chunk.count - head.firstChunkCursor
                    let toSkip = min(available, remaining)
                    head.firstChunkCursor += toSkip
                    head.bytesInBuffer -= toSkip
                    remaining -= toSkip
                    if head.firstChunkCursor >= chunk.count {
                        head.chunksHead += 1
                        head.firstChunkCursor = 0
                    }
                }
                absolutePosition += delta
                if head.chunksHead >= head.chunks.count {
                    head.chunks.removeAll(keepingCapacity: true)
                    head.chunksHead = 0
                }
                advanceHeadIfDrainedLocked()
                condition.unlock()
                refillPipeline()
                return newOffset
            }
            condition.unlock()
        }

        playerDebugLog(String(
            format: "[URLSessionAVIOSeek] from=%lld to=%lld Δ=%+.2fMB restarting",
            currentPos, newOffset, Double(delta) / (1024 * 1024)
        ))

        condition.lock()
        totalSeekCount += 1
        condition.unlock()
        kickoffPipeline(atOffset: newOffset)
        return newOffset
    }

    // MARK: - Delegate helpers

    /// Find segment by the (generation, id) encoded in taskDescription.
    /// Call under `condition.lock()`.
    private func findSegmentForTaskLocked(_ task: URLSessionTask) -> Segment? {
        guard let tag = task.taskDescription else { return nil }
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let gen = UInt64(parts[0]),
              let id = UInt64(parts[1]) else { return nil }
        if gen != pipelineGeneration { return nil }
        return segments.first(where: { $0.id == id })
    }
}

// MARK: - URLSessionDataDelegate

extension URLSessionAVIOSource: URLSessionDataDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock()
        guard findSegmentForTaskLocked(dataTask) != nil else {
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        if let http = response as? HTTPURLResponse {
            if totalContentLength < 0,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slashIdx = range.lastIndex(of: "/") {
                let totalStr = range[range.index(after: slashIdx)...]
                if let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                    totalContentLength = total
                }
            }
        }
        condition.unlock()
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession,
                                dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        condition.lock()
        guard let segment = findSegmentForTaskLocked(dataTask), !closed else {
            condition.unlock()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if lastDelegateDeliveryWall > 0 {
            totalDelegateInterArrivalMicros += Int64((now - lastDelegateDeliveryWall) * 1_000_000)
        }
        lastDelegateDeliveryWall = now
        totalDelegateDeliveries += 1
        if data.count > maxDelegateChunkBytes { maxDelegateChunkBytes = data.count }
        if data.count < minDelegateChunkBytes { minDelegateChunkBytes = data.count }

        segment.chunks.append(data)
        segment.bytesInBuffer += data.count
        segment.bytesDelivered += Int64(data.count)
        totalBytesDelivered += Int64(data.count)
        condition.signal()
        condition.unlock()
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        condition.lock()
        guard let segment = findSegmentForTaskLocked(task) else {
            condition.unlock()
            return
        }
        segment.isComplete = true
        if let error, (error as NSError).code != NSURLErrorCancelled {
            segment.fetchError = error
            playerDebugLog("[URLSessionAVIO] Segment id=\(segment.id) error: \(error.localizedDescription)")
        }
        condition.broadcast()
        condition.unlock()

        // If the segment was NOT the head, no action needed — read() will
        // advance through it eventually. If it WAS the head and delivered
        // everything, read() will advance to the next segment on its next
        // call. Either way we want to top up the pipeline.
        refillPipeline()
    }
}

// MARK: - AVIOContext factory

extension URLSessionAVIOSource {

    /// Allocate an AVIOContext that reads from `source`. The returned
    /// context holds a retained reference via its opaque pointer; free
    /// with `freeAVIOContext(_:)`.
    nonisolated static func makeAVIOContext(for source: URLSessionAVIOSource) -> UnsafeMutablePointer<AVIOContext>? {
        let bufferSize = 1 * 1024 * 1024
        guard let rawBuffer = av_malloc(bufferSize) else { return nil }
        let buffer = rawBuffer.assumingMemoryBound(to: UInt8.self)
        let opaque = Unmanaged.passRetained(source).toOpaque()

        guard let ctx = avio_alloc_context(
            buffer,
            Int32(bufferSize),
            0,
            opaque,
            { opaquePtr, buf, bufSize -> Int32 in
                guard let opaque = opaquePtr, let buf = buf, bufSize > 0 else {
                    return AVERROR_EOF_VALUE
                }
                let src = Unmanaged<URLSessionAVIOSource>.fromOpaque(opaque).takeUnretainedValue()
                return src.read(into: buf, size: Int(bufSize))
            },
            nil,
            { opaquePtr, offset, whence -> Int64 in
                guard let opaque = opaquePtr else { return -1 }
                let src = Unmanaged<URLSessionAVIOSource>.fromOpaque(opaque).takeUnretainedValue()
                return src.seek(offset: offset, whence: whence)
            }
        ) else {
            av_free(rawBuffer)
            Unmanaged<URLSessionAVIOSource>.fromOpaque(opaque).release()
            return nil
        }
        return ctx
    }

    nonisolated static func freeAVIOContext(_ ctx: UnsafeMutablePointer<AVIOContext>) {
        let opaque = ctx.pointee.opaque
        var mutableCtx: UnsafeMutablePointer<AVIOContext>? = ctx
        avio_context_free(&mutableCtx)
        if let opaque {
            let src = Unmanaged<URLSessionAVIOSource>.fromOpaque(opaque).takeRetainedValue()
            src.close()
        }
    }
}

// MARK: - AVERROR / AVSEEK shims

nonisolated private let AVERROR_EOF_VALUE: Int32 = {
    let tag = Int32(bitPattern:
        (UInt32(Character("E").asciiValue!) |
        (UInt32(Character("O").asciiValue!) << 8) |
        (UInt32(Character("F").asciiValue!) << 16) |
        (UInt32(Character(" ").asciiValue!) << 24)))
    return -tag
}()

nonisolated private let AVSEEK_SIZE_VALUE: Int32 = 0x10000
nonisolated private let AVSEEK_FORCE_VALUE: Int32 = 0x20000

#endif  // RIVULET_FFMPEG
