#!/usr/bin/env swift
//
// Mock HTTP server that models Plex's observed quirks so we can reproduce
// the URLSessionAVIOSource bottleneck locally. Serves a deterministic byte
// stream (not a real file — bytes are position == (pos & 0xFF)) so the
// client can cheaply verify it received the right bytes after a seek.
//
// Knobs (via env vars):
//   MOCK_PORT            port to listen on (default 18421)
//   MOCK_TOTAL_BYTES     total resource size (default 1 GiB)
//   MOCK_TRUNCATE_AFTER  close the connection after N bytes (default 0 = no trunc)
//   MOCK_RATE_BPS        target throughput per connection in bytes/sec
//                        (default 0 = unlimited)
//   MOCK_FIRST_DELAY_MS  artificial delay before the first byte is sent
//                        (models slow-start / TCP negotiation; default 0)
//
// Only supports GET, `Range: bytes=N-` requests, HTTP/1.1, non-keepalive.
// That's enough to exercise our AVIO source.
//

import Foundation
import Network

let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["MOCK_PORT"] ?? "18421") ?? 18421
let totalBytes: Int64 = Int64(ProcessInfo.processInfo.environment["MOCK_TOTAL_BYTES"] ?? "") ?? (1024 * 1024 * 1024)
let truncateAfter: Int64 = Int64(ProcessInfo.processInfo.environment["MOCK_TRUNCATE_AFTER"] ?? "0") ?? 0
let rateBps: Int64 = Int64(ProcessInfo.processInfo.environment["MOCK_RATE_BPS"] ?? "0") ?? 0
let firstDelayMs: Int = Int(ProcessInfo.processInfo.environment["MOCK_FIRST_DELAY_MS"] ?? "0") ?? 0

print("mock_plex_server listening on 127.0.0.1:\(port)")
print("  total=\(totalBytes) truncateAfter=\(truncateAfter) rateBps=\(rateBps) firstDelayMs=\(firstDelayMs)")

let listener = try NWListener(
    using: .tcp,
    on: NWEndpoint.Port(rawValue: port)!
)

let queue = DispatchQueue(label: "mock-plex-server")

func byteAt(_ position: Int64) -> UInt8 {
    return UInt8(position & 0xFF)
}

func handleConnection(_ conn: NWConnection) {
    conn.start(queue: queue)
    var requestBuffer = Data()

    func closeGracefully() {
        conn.cancel()
    }

    func readRequest() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                requestBuffer.append(data)
                if let terminator = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(data: requestBuffer.subdata(in: 0..<terminator.lowerBound), encoding: .utf8) ?? ""
                    dispatchRequest(headers: headerText)
                    return
                }
                readRequest()
                return
            }
            if isComplete || error != nil {
                closeGracefully()
            }
        }
    }

    func dispatchRequest(headers: String) {
        // Parse Range header, default to bytes=0-
        var rangeStart: Int64 = 0
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("range:") {
                // Range: bytes=N-
                if let eq = line.firstIndex(of: "=") {
                    let after = line[line.index(after: eq)...]
                    if let dash = after.firstIndex(of: "-"),
                       let n = Int64(after[..<dash]) {
                        rangeStart = n
                    }
                }
            }
        }

        guard rangeStart >= 0 && rangeStart < totalBytes else {
            let body = "bad range".data(using: .utf8)!
            let resp = httpHeader(status: 416, headers: [
                "Content-Type": "text/plain",
                "Content-Length": "\(body.count)",
                "Connection": "close"
            ])
            conn.send(content: resp + body, completion: .contentProcessed { _ in closeGracefully() })
            return
        }

        let bytesRemaining = totalBytes - rangeStart
        let willSendTotal: Int64 = (truncateAfter > 0 && truncateAfter < bytesRemaining)
            ? truncateAfter : bytesRemaining

        let status: Int
        var hdrs: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(willSendTotal)",
            "Accept-Ranges": "bytes",
            "Connection": "close"
        ]
        if rangeStart > 0 {
            status = 206
            hdrs["Content-Range"] = "bytes \(rangeStart)-\(rangeStart + willSendTotal - 1)/\(totalBytes)"
        } else {
            status = 206  // Always use 206 so the client has Content-Range for the real total
            hdrs["Content-Range"] = "bytes \(rangeStart)-\(rangeStart + willSendTotal - 1)/\(totalBytes)"
        }

        let respHeader = httpHeader(status: status, headers: hdrs)

        print("  request start=\(rangeStart) sending=\(willSendTotal) total=\(totalBytes)")

        func sendHeader() {
            conn.send(content: respHeader, completion: .contentProcessed { _ in
                if firstDelayMs > 0 {
                    queue.asyncAfter(deadline: .now() + .milliseconds(firstDelayMs)) {
                        streamBody(from: rangeStart, remaining: willSendTotal)
                    }
                } else {
                    streamBody(from: rangeStart, remaining: willSendTotal)
                }
            })
        }

        sendHeader()
    }

    func streamBody(from startPos: Int64, remaining: Int64) {
        var pos = startPos
        var left = remaining
        let chunkSize: Int = 64 * 1024

        // Compute chunk delay for rate limit: bytes/sec → sec/byte → sec/chunk
        let perChunkDelayNs: UInt64 = rateBps > 0
            ? UInt64(Double(chunkSize) / Double(rateBps) * 1_000_000_000)
            : 0

        func sendChunk() {
            if left <= 0 {
                closeGracefully()
                return
            }
            let sz = Int(min(Int64(chunkSize), left))
            var buffer = Data(count: sz)
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<sz {
                    ptr[i] = UInt8((pos + Int64(i)) & 0xFF)
                }
            }
            pos += Int64(sz)
            left -= Int64(sz)

            conn.send(content: buffer, completion: .contentProcessed { err in
                if err != nil { closeGracefully(); return }
                if perChunkDelayNs > 0 {
                    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(perChunkDelayNs))) {
                        sendChunk()
                    }
                } else {
                    sendChunk()
                }
            })
        }

        sendChunk()
    }

    readRequest()
}

func httpHeader(status: Int, headers: [String: String]) -> Data {
    let statusText: String = {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 416: return "Requested Range Not Satisfiable"
        default:  return "Unknown"
        }
    }()
    var lines = ["HTTP/1.1 \(status) \(statusText)"]
    for (k, v) in headers { lines.append("\(k): \(v)") }
    lines.append("")
    lines.append("")
    return lines.joined(separator: "\r\n").data(using: .utf8)!
}

listener.newConnectionHandler = { conn in
    handleConnection(conn)
}
listener.start(queue: queue)

RunLoop.main.run()
