//
//  PlexThumbnailService.swift
//  Rivulet
//
//  Service for fetching video thumbnails from Plex BIF (Base Index Frames) files
//

import Foundation
import UIKit

/// Service for fetching video preview thumbnails from Plex
@MainActor
final class PlexThumbnailService {
    static let shared = PlexThumbnailService()

    // Cache of loaded BIF data keyed by part ID
    private var bifCache: [Int: BIFData] = [:]
    private var loadingTasks: [Int: Task<BIFData?, Never>] = [:]
    private var unavailableParts: Set<Int> = []  // Parts that returned 404

    private init() {}

    /// Get thumbnail for a specific time in the video
    func getThumbnail(partId: Int, time: TimeInterval, serverURL: String, authToken: String) async -> UIImage? {
        // Skip if we already know this part has no BIF
        if unavailableParts.contains(partId) {
            return nil
        }

        // Try to get from cache first
        if let bifData = bifCache[partId] {
            return bifData.thumbnail(at: time)
        }

        // Check if already loading
        if let task = loadingTasks[partId] {
            let result = await task.value
            return result?.thumbnail(at: time)
        }

        // Start loading
        let task = Task<BIFData?, Never> {
            await loadBIF(partId: partId, serverURL: serverURL, authToken: authToken)
        }
        loadingTasks[partId] = task

        let result = await task.value
        loadingTasks[partId] = nil

        if let data = result {
            bifCache[partId] = data
            return data.thumbnail(at: time)
        } else {
            // Mark as unavailable so we don't keep trying
            unavailableParts.insert(partId)
        }

        return nil
    }

    /// Preload BIF data for a part
    func preloadBIF(partId: Int, serverURL: String, authToken: String) {
        guard bifCache[partId] == nil,
              loadingTasks[partId] == nil,
              !unavailableParts.contains(partId) else { return }

        let task = Task<BIFData?, Never> {
            await loadBIF(partId: partId, serverURL: serverURL, authToken: authToken)
        }
        loadingTasks[partId] = task

        Task {
            if let result = await task.value {
                bifCache[partId] = result
            } else {
                unavailableParts.insert(partId)
            }
            loadingTasks[partId] = nil
        }
    }

    private func loadBIF(partId: Int, serverURL: String, authToken: String) async -> BIFData? {
        // print("🖼️ Loading BIF for part \(partId) from \(serverURL)")

        // Try SD first (smaller, faster to load), fall back to HD
        for quality in ["sd", "hd"] {
            let urlString = "\(serverURL)/library/parts/\(partId)/indexes/\(quality)"
            // print("🖼️ Trying BIF URL: \(urlString)")

            guard var urlComponents = URLComponents(string: urlString) else {
                print("⚠️ Failed to create URL components")
                continue
            }
            urlComponents.queryItems = [
                URLQueryItem(name: "X-Plex-Token", value: authToken)
            ]

            guard let url = urlComponents.url else {
                print("⚠️ Failed to create URL from components")
                continue
            }

            do {
                // Use custom URLSession that accepts self-signed certs
                let session = createTrustingSession()
                var request = URLRequest(url: url)
                request.setValue(authToken, forHTTPHeaderField: "X-Plex-Token")

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("⚠️ Not an HTTP response")
                    continue
                }

                // print("🖼️ BIF response status: \(httpResponse.statusCode), size: \(data.count) bytes")

                guard httpResponse.statusCode == 200 else {
                    print("⚠️ BIF request failed with status \(httpResponse.statusCode)")
                    continue
                }

                if let bifData = BIFData(data: data) {
                    // print("✅ Loaded BIF thumbnails (\(quality)): \(bifData.frameCount) frames, interval: \(bifData.intervalMs)ms")
                    // Debug: Check first 5 frames and a few later ones
                    for i in [0, 1, 2, 3, 4, 10, 50, 100] {
                        if i < bifData.frames.count {
                            // print("🖼️ Frame[\(i)]: timestamp=\(frame.timestamp)ms, size=\(frame.imageData.count) bytes")
                        }
                    }
                    return bifData
                } else {
                    print("⚠️ Failed to parse BIF data (size: \(data.count) bytes)")
                    // Log first few bytes to debug
                }
            } catch {
                print("⚠️ Failed to load BIF (\(quality)): \(error.localizedDescription)")
                continue
            }
        }

        // print("❌ No BIF thumbnails available for part \(partId)")
        return nil
    }

    /// Creates a URLSession that trusts self-signed certificates
    private func createTrustingSession() -> URLSession {
        let config = URLSessionConfiguration.default
        let delegate = TrustingSessionDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Clear cache for a specific part
    func clearCache(partId: Int) {
        bifCache[partId] = nil
        unavailableParts.remove(partId)
    }

    /// Clear all cached data
    func clearAllCache() {
        bifCache.removeAll()
        unavailableParts.removeAll()
    }
}

// MARK: - SSL Trust Delegate

private class TrustingSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - BIF Data Structure

/// Parsed BIF (Base Index Frames) file data
struct BIFData {
    let intervalMs: UInt32
    let frames: [BIFFrame]

    var frameCount: Int { frames.count }

    struct BIFFrame {
        let timestamp: UInt32  // Milliseconds
        let imageData: Data
    }

    init?(data: Data) {
        // BIF format:
        // Bytes 0-7: Magic number (0x89 "BIF" 0x0D 0x0A 0x1A 0x0A)
        // Bytes 8-11: Version (little-endian UInt32)
        // Bytes 12-15: Frame count (little-endian UInt32)
        // Bytes 16-19: Interval in ms (little-endian UInt32, typically 10000 for 10s)
        // Bytes 20-63: Reserved
        // Bytes 64+: Frame index table (8 bytes per frame: 4 bytes timestamp, 4 bytes offset)
        // After index table: Frame data (JPEG images)

        guard data.count >= 64 else { return nil }

        // Check magic number
        let magic = data.prefix(8)
        let expectedMagic = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        guard magic == expectedMagic else { return nil }

        // Read header
        let frameCount = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 12, as: UInt32.self).littleEndian
        }

        var interval = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 16, as: UInt32.self).littleEndian
        }

        // BIF spec: timestamp multiplier of 0 means use default of 1000ms
        if interval == 0 {
            interval = 1000
        }

        self.intervalMs = interval

        // Read frame index
        let indexStart = 64
        let indexEnd = indexStart + Int(frameCount + 1) * 8  // +1 for end marker

        guard data.count >= indexEnd else { return nil }

        var frameInfos: [(timestamp: UInt32, offset: UInt32)] = []
        for i in 0..<Int(frameCount) {
            let entryOffset = indexStart + i * 8
            let timestamp = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: entryOffset, as: UInt32.self).littleEndian
            }
            let offset = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: entryOffset + 4, as: UInt32.self).littleEndian
            }
            frameInfos.append((timestamp, offset))
        }

        // Read end marker for last frame size
        let endOffset = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: indexStart + Int(frameCount) * 8 + 4, as: UInt32.self).littleEndian
        }

        // Extract frame data
        var frames: [BIFFrame] = []
        for i in 0..<frameInfos.count {
            let info = frameInfos[i]
            let nextOffset = (i + 1 < frameInfos.count) ? frameInfos[i + 1].offset : endOffset

            let start = Int(info.offset)
            let end = Int(nextOffset)

            guard start < data.count, end <= data.count, start < end else { continue }

            let frameData = data.subdata(in: start..<end)
            frames.append(BIFFrame(timestamp: info.timestamp, imageData: frameData))
        }

        self.frames = frames
    }

    /// Get thumbnail for a specific time
    func thumbnail(at time: TimeInterval) -> UIImage? {
        let timeMs = UInt32(time * 1000)

        // Find the closest frame
        // BIF timestamps must be multiplied by intervalMs to get real time
        var bestFrame: BIFFrame?
        var bestDiff = UInt32.max

        for frame in frames {
            // Calculate the real timestamp for this frame
            let frameRealTimeMs = frame.timestamp * intervalMs
            let diff = timeMs > frameRealTimeMs ? timeMs - frameRealTimeMs : frameRealTimeMs - timeMs
            if diff < bestDiff {
                bestDiff = diff
                bestFrame = frame
            }
        }

        guard let frame = bestFrame else {
            return nil
        }

        return UIImage(data: frame.imageData)
    }
}
