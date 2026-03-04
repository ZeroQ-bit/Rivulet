//
//  SegmentBuffer.swift
//  Rivulet
//
//  Thread-safe bounded buffer for producer/consumer pipeline.
//  Producer (downloader) waits when full; consumer (enqueuer) waits when empty.
//

import Foundation

/// Bounded async buffer for transferring downloaded segments from producer to consumer.
/// Call `cancel()` before discarding to safely resume any pending continuations.
actor SegmentBuffer {
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
    private var producerContinuation: CheckedContinuation<Bool, Never>?
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
        while items.count >= capacity && !isCancelled {
            let shouldContinue = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                producerContinuation = cont
            }
            if !shouldContinue { return false }
        }

        guard !isCancelled else { return false }

        let item = Item.segment(index: index, data: data)

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
            if let producer = producerContinuation {
                producerContinuation = nil
                producer.resume(returning: true)
            }
            return item
        }

        if isFinished {
            return .finished
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Item, Never>) in
            consumerContinuation = cont
        }
    }
}
