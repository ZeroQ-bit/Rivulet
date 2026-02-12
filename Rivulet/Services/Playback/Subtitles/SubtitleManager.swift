//
//  SubtitleManager.swift
//  Rivulet
//
//  Manages subtitle loading, parsing, and current cue selection.
//

import Foundation
import Combine

/// Manages subtitle loading and provides current cues based on playback time
@MainActor
final class SubtitleManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentCues: [SubtitleCue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    // MARK: - Private State

    private var currentTrack: SubtitleTrack = .empty
    private var lastUpdateTime: TimeInterval = -1
    private let updateThreshold: TimeInterval = 0.05  // 50ms threshold to avoid excessive updates

    // MARK: - Loading

    /// Load subtitles from a URL with authentication headers
    func load(url: URL, headers: [String: String], format: SubtitleFormat? = nil) async {
        isLoading = true
        error = nil
        currentTrack = .empty
        currentCues = []

        do {
            let content = try await fetchSubtitleContent(url: url, headers: headers)
            let detectedFormat = format ?? SubtitleFormat(fromURL: url)

            guard let parser = detectedFormat.parser else {
                // Try to auto-detect from content
                let track = try parseWithAutoDetect(content)
                currentTrack = track
                isLoading = false
                return
            }

            let track = try parser.parse(content)
            currentTrack = track
        } catch {
            self.error = error
            print("🎬 [Subtitles] ❌ Failed to load: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Load subtitles from raw content string
    func load(content: String, format: SubtitleFormat) {
        error = nil
        currentTrack = .empty
        currentCues = []

        guard let parser = format.parser else {
            print("🎬 [Subtitles] ❌ No parser for format")
            return
        }

        do {
            let track = try parser.parse(content)
            currentTrack = track
        } catch {
            self.error = error
            print("🎬 [Subtitles] ❌ Parse error: \(error.localizedDescription)")
        }
    }

    /// Clear current subtitles
    func clear() {
        currentTrack = .empty
        currentCues = []
        error = nil
        lastUpdateTime = -1
    }

    // MARK: - Time Updates

    /// Update current cues based on playback time
    /// Call this from your time observer (typically 4-10 times per second)
    func update(time: TimeInterval) {
        // Skip if time hasn't changed significantly
        guard abs(time - lastUpdateTime) > updateThreshold else { return }
        lastUpdateTime = time

        let newCues = currentTrack.activeCues(at: time)

        // Only update if cues actually changed
        if newCues.map(\.id) != currentCues.map(\.id) {
            currentCues = newCues
        }
    }

    /// Seek occurred - force update on next time update
    func didSeek() {
        lastUpdateTime = -1
    }

    // MARK: - Private

    private func fetchSubtitleContent(url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SubtitleLoadError.httpError(httpResponse.statusCode)
        }

        // Try UTF-8 first, then Latin-1 as fallback (common for older SRT files)
        if let content = String(data: data, encoding: .utf8) {
            return content
        }
        if let content = String(data: data, encoding: .isoLatin1) {
            return content
        }
        if let content = String(data: data, encoding: .windowsCP1252) {
            return content
        }

        throw SubtitleLoadError.invalidEncoding
    }

    private func parseWithAutoDetect(_ content: String) throws -> SubtitleTrack {
        // Try VTT first (has explicit header)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            return try VTTParser().parse(content)
        }

        // Try SRT
        do {
            return try SRTParser().parse(content)
        } catch {
            throw SubtitleLoadError.unsupportedFormat
        }
    }
}

// MARK: - Errors

enum SubtitleLoadError: Error, LocalizedError {
    case httpError(Int)
    case invalidEncoding
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidEncoding: return "Could not decode subtitle file"
        case .unsupportedFormat: return "Unsupported subtitle format"
        }
    }
}
