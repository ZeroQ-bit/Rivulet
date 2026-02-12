//
//  MPVPlayerWrapper.swift
//  Rivulet
//
//  MPV-based video player implementing PlayerProtocol
//

import Foundation
import Combine
import UIKit
import Sentry

@MainActor
final class MPVPlayerWrapper: NSObject, PlayerProtocol, MPVPlayerDelegate {

    // MARK: - MPV Components

    private(set) var playerController: MPVMetalViewController?

    // MARK: - State

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private let tracksSubject = PassthroughSubject<Void, Never>()

    private var _duration: TimeInterval = 0
    private var _audioTracks: [MediaTrack] = []
    private var _subtitleTracks: [MediaTrack] = []
    private var _currentAudioTrackId: Int?
    private var _currentSubtitleTrackId: Int?

    // MARK: - URL and Headers (for deferred loading)

    private var pendingURL: URL?
    private var pendingHeaders: [String: String]?
    private var pendingStartTime: TimeInterval?

    /// The URL that was actually loaded into MPV (preserved for error reporting)
    private var loadedURL: URL?
    private let debugId = String(UUID().uuidString.prefix(8))

    // MARK: - Publishers

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    /// Fires when track lists are updated (audio/subtitle tracks available)
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    var isPlaying: Bool {
        playerController?.isPlaying ?? false
    }

    var currentTime: TimeInterval {
        playerController?.currentTime ?? 0
    }

    var duration: TimeInterval {
        _duration
    }

    var bufferedTime: TimeInterval {
        // MPV doesn't expose buffered time easily
        0
    }

    var playbackRate: Float {
        get { playerController?.playbackRate ?? 1.0 }
        set { playerController?.playbackRate = newValue }
    }

    // MARK: - Track State

    var audioTracks: [MediaTrack] { _audioTracks }
    var subtitleTracks: [MediaTrack] { _subtitleTracks }
    var currentAudioTrackId: Int? { _currentAudioTrackId }
    var currentSubtitleTrackId: Int? { _currentSubtitleTrackId }

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Playback Controls

    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        playbackStateSubject.send(.loading)

        // Log load attempt (GitHub #64 - DVB diagnostics)
        let streamType = classifyStreamType(url: url)
        let breadcrumb = Breadcrumb(level: .info, category: "mpv_player")
        breadcrumb.message = "MPV load started"
        breadcrumb.data = [
            "stream_type": streamType,
            "url_host": url.host ?? "unknown",
            "url_path": url.path,
            "url_scheme": url.scheme ?? "unknown",
            "has_controller": playerController != nil,
            "is_deferred": playerController == nil,
            "start_time": startTime ?? 0,
            "has_headers": headers?.isEmpty == false
        ]
        SentrySDK.addBreadcrumb(breadcrumb)

        // Store for when controller is ready
        pendingURL = url
        pendingHeaders = headers
        pendingStartTime = startTime

        // If controller already exists, load directly
        if let controller = playerController {
            loadedURL = url  // Preserve for error reporting
            controller.httpHeaders = headers
            controller.startTime = startTime
            controller.loadFile(url)
        }
        // Otherwise, loading will happen when controller is set via setPlayerController
    }

    /// Called when the view creates the player controller
    func setPlayerController(_ controller: MPVMetalViewController) {
        self.playerController = controller
        controller.delegate = self

        // If we have a pending URL, load it now
        if let url = pendingURL {
            // Log deferred load execution (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .info, category: "mpv_player")
            breadcrumb.message = "MPV executing deferred load"
            breadcrumb.data = [
                "stream_type": classifyStreamType(url: url),
                "url_host": url.host ?? "unknown",
                "url_path": url.path
            ]
            SentrySDK.addBreadcrumb(breadcrumb)

            loadedURL = url  // Preserve for error reporting
            controller.httpHeaders = pendingHeaders
            controller.startTime = pendingStartTime
            controller.loadFile(url)
            pendingURL = nil
            pendingHeaders = nil
            pendingStartTime = nil
        }
    }

    func play() {
        playerController?.play()
    }

    func pause() {
        playerController?.pause()
    }

    func stop() {
        // Clear delegate first to prevent callbacks during shutdown
        playerController?.delegate = nil
        playerController?.stop()
        playerController = nil
        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        playerController?.seek(to: time)
        timeSubject.send(time)
    }

    func seekRelative(by seconds: TimeInterval) async {
        playerController?.seekRelative(by: seconds)
    }

    // MARK: - Track Management

    /// Request track enumeration (lazy loading for faster startup).
    /// Should be called when info panel/track picker is opened.
    func requestTrackEnumeration() {
        playerController?.enumerateTracksIfNeeded()
    }

    func selectAudioTrack(id: Int) {
        playerController?.selectAudioTrack(id)
        _currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        playerController?.selectSubtitleTrack(id)
        _currentSubtitleTrackId = id
    }

    func disableSubtitles() {
        playerController?.disableSubtitles()
        _currentSubtitleTrackId = nil
    }

    // MARK: - Audio Control

    var isMuted: Bool {
        playerController?.isMuted ?? false
    }

    func setMuted(_ muted: Bool) {
        playerController?.setMuted(muted)
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        _audioTracks = []
        _subtitleTracks = []
        _currentAudioTrackId = nil
        _currentSubtitleTrackId = nil
        _duration = 0
        loadedURL = nil
        playbackStateSubject.send(.idle)
        timeSubject.send(0)
    }

    deinit {
    }

    // MARK: - MPVPlayerDelegate

    func mpvPlayerDidChangeState(_ state: MPVPlayerState) {
        let previousState = playbackStateSubject.value
        let universalState: UniversalPlaybackState
        switch state {
        case .idle:
            universalState = .idle
        case .loading:
            universalState = .loading
        case .playing:
            universalState = .playing
        case .paused:
            universalState = .paused
        case .buffering:
            universalState = .buffering
        case .ended:
            universalState = .ended
        case .error(let message):
            let lowered = message.lowercased()
            if lowered.contains("loading failed") || lowered.contains("failed to open") {
                universalState = .failed(.loadFailed(message))
            } else if lowered.contains("network") || lowered.contains("connection") || lowered.contains("timed out") {
                universalState = .failed(.networkError(message))
            } else {
                universalState = .failed(.unknown(message))
            }
        }

        // Log state transitions for debugging (GitHub #64 - DVB diagnostics)
        let streamType = classifyStreamType(url: loadedURL)
        let breadcrumb = Breadcrumb(level: universalState.isFailed ? .error : .info, category: "mpv_player")
        breadcrumb.message = "MPV state transition: \(previousState) → \(universalState)"
        breadcrumb.data = [
            "previous_state": String(describing: previousState),
            "new_state": String(describing: universalState),
            "stream_type": streamType,
            "stream_host": loadedURL?.host ?? "unknown",
            "has_controller": playerController != nil,
            "duration": _duration
        ]
        SentrySDK.addBreadcrumb(breadcrumb)

        playbackStateSubject.send(universalState)
    }

    func mpvPlayerTimeDidChange(current: Double, duration: Double) {
        timeSubject.send(current)
        if duration > 0 {
            _duration = duration
        }
    }

    func mpvPlayerDidUpdateTracks(audio: [MPVTrack], subtitles: [MPVTrack]) {
        _audioTracks = audio.map { track in
            MediaTrack(
                id: track.id,
                name: track.displayName,
                language: track.language,
                languageCode: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                channels: track.channels
            )
        }

        _subtitleTracks = subtitles.map { track in
            MediaTrack(
                id: track.id,
                name: track.displayName,
                language: track.language,
                languageCode: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced
            )
        }

        // Update selected track IDs
        _currentAudioTrackId = audio.first(where: { $0.isSelected })?.id
        _currentSubtitleTrackId = subtitles.first(where: { $0.isSelected })?.id

        // Notify subscribers that tracks are available
       // print("🎬 [MPV] Tracks updated: \(audio.count) audio, \(subtitles.count) subtitles")
        tracksSubject.send()
    }

    func mpvPlayerDidEncounterError(_ message: String) {
        errorSubject.send(.unknown(message))

        // Extract additional context from URL
        let fileExtension = loadedURL?.pathExtension.lowercased() ?? "unknown"
        let urlScheme = loadedURL?.scheme ?? "unknown"
        let port = loadedURL?.port
        let streamType = classifyStreamType(url: loadedURL)
        let errorCategory = categorizeMPVError(message)

        // Log breadcrumb before error event (GitHub #64 - DVB diagnostics)
        let breadcrumb = Breadcrumb(level: .error, category: "mpv_player")
        breadcrumb.message = "MPV playback error: \(errorCategory)"
        breadcrumb.data = [
            "error_message": message,
            "error_category": errorCategory,
            "stream_type": streamType,
            "stream_host": loadedURL?.host ?? "unknown",
            "stream_path": loadedURL?.path ?? "unknown",
            "file_extension": fileExtension,
            "url_scheme": urlScheme
        ]
        SentrySDK.addBreadcrumb(breadcrumb)

        // For "loading failed" AND "unrecognized format" errors, probe the URL to get more info
        // Extended to cover "loading failed" for DVB debugging (GitHub #64)
        if (errorCategory == "unrecognized-format" || errorCategory == "loading-failed"), let url = loadedURL {
            Task {
                let probeResult = await probeStreamURL(url)
                logMPVErrorToSentry(
                    message: message,
                    fileExtension: fileExtension,
                    urlScheme: urlScheme,
                    port: port,
                    streamType: streamType,
                    errorCategory: errorCategory,
                    probeResult: probeResult
                )
            }
        } else {
            logMPVErrorToSentry(
                message: message,
                fileExtension: fileExtension,
                urlScheme: urlScheme,
                port: port,
                streamType: streamType,
                errorCategory: errorCategory,
                probeResult: nil
            )
        }
    }

    /// Probe a stream URL to diagnose why it might not be recognized as media.
    /// For Plex transcode URLs, uses GET to capture response body (error messages).
    /// For other URLs, uses HEAD to avoid consuming the stream.
    private func probeStreamURL(_ url: URL) async -> [String: Any] {
        var result: [String: Any] = [:]

        let isTranscodeURL = url.path.contains("/transcode/")

        // For transcode URLs, use GET to capture Plex error response body (GitHub #64)
        // For other URLs, use HEAD to avoid consuming the stream
        var request = URLRequest(url: url)
        request.httpMethod = isTranscodeURL ? "GET" : "HEAD"
        request.timeoutInterval = 10

        // Add headers if we have them stored
        if let headers = pendingHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                result["http_status"] = httpResponse.statusCode
                result["content_type"] = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                result["content_length"] = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "unknown"

                // Check if server returned an error page
                let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if contentType.contains("text/html") || contentType.contains("text/plain") {
                    result["likely_error_page"] = true

                    // Capture response body for error pages (first 2KB, GitHub #64 - DVB diagnostics)
                    if !data.isEmpty {
                        let bodyPreview = String(data: data.prefix(2048), encoding: .utf8) ?? "<binary>"
                        result["response_body_preview"] = bodyPreview
                    }
                }

                // For non-success responses, always capture body
                if httpResponse.statusCode >= 400 {
                    result["http_error"] = true
                    if !data.isEmpty {
                        let bodyPreview = String(data: data.prefix(2048), encoding: .utf8) ?? "<binary>"
                        result["response_body_preview"] = bodyPreview
                    }
                }

                // For transcode URLs, log first bytes to check if it's valid HLS
                if isTranscodeURL && httpResponse.statusCode == 200 && !data.isEmpty {
                    let prefix = String(data: data.prefix(128), encoding: .utf8) ?? "<binary>"
                    result["response_starts_with"] = prefix
                    result["is_valid_hls"] = prefix.contains("#EXTM3U")
                }
            }
        } catch {
            result["probe_error"] = error.localizedDescription
        }

        return result
    }

    /// Log MPV error to Sentry with optional probe results
    private func logMPVErrorToSentry(
        message: String,
        fileExtension: String,
        urlScheme: String,
        port: Int?,
        streamType: String,
        errorCategory: String,
        probeResult: [String: Any]?
    ) {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "MPV Playback Error: \(message)")

        var extras: [String: Any] = [
            "error_message": message,
            "stream_url": redactToken(in: loadedURL?.absoluteString ?? "none"),
            "stream_host": loadedURL?.host ?? "unknown",
            "stream_path": loadedURL?.path ?? "unknown",
            "stream_type": streamType,
            "file_extension": fileExtension,
            "url_scheme": urlScheme,
            "port": port ?? 0,
            "has_controller": playerController != nil,
            "duration": _duration,
            "current_time": playerController?.currentTime ?? 0
        ]

        // For transcode URLs, log query params (redacted) to diagnose DVB issues (GitHub #64)
        if let url = loadedURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let redactedParams = (components.queryItems ?? []).map { item in
                if item.name.contains("Token") || item.name.contains("token") {
                    return "\(item.name)=<redacted>"
                }
                return "\(item.name)=\(item.value ?? "")"
            }
            extras["query_params_redacted"] = redactedParams.joined(separator: "&")
        }

        // Add probe results if available (for format errors)
        if let probe = probeResult {
            for (key, value) in probe {
                extras["probe_\(key)"] = value
            }
        }

        event.extra = extras

        var tags: [String: String] = [
            "component": "mpv_player",
            "stream_host": loadedURL?.host ?? "unknown",
            "file_extension": fileExtension,
            "stream_type": streamType
        ]

        // Add probe-derived tags for filtering
        if let probe = probeResult {
            if let status = probe["http_status"] as? Int {
                tags["http_status"] = String(status)
            }
            if let isErrorPage = probe["likely_error_page"] as? Bool, isErrorPage {
                tags["likely_error_page"] = "true"
            }
            if let contentType = probe["content_type"] as? String {
                // Simplify content type for tag
                if contentType.contains("html") {
                    tags["content_type"] = "text/html"
                } else if contentType.contains("video") {
                    tags["content_type"] = "video"
                } else if contentType.contains("audio") {
                    tags["content_type"] = "audio"
                }
            }
        }

        event.tags = tags
        event.fingerprint = ["mpv", errorCategory]

        SentrySDK.capture(event: event)
    }

    /// Classifies the stream type based on URL patterns
    private func classifyStreamType(url: URL?) -> String {
        guard let url = url else { return "unknown" }
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        if path.contains("/library/parts/") {
            return "plex_direct"
        } else if path.contains("/video/:/transcode/") {
            return "plex_transcode"
        } else if path.contains("/live/") || path.hasSuffix(".ts") || path.contains(".m3u") {
            return "iptv"
        } else if path.contains("/proxy/") {
            return "proxy"
        } else if host.contains("plex.direct") {
            return "plex_relay"
        } else {
            return "other"
        }
    }

    /// Redact Plex auth tokens from a string for safe logging
    private func redactToken(in string: String) -> String {
        // Redact X-Plex-Token=... values
        string.replacingOccurrences(
            of: "(X-Plex-Token=)[^&]+",
            with: "$1<redacted>",
            options: .regularExpression
        )
    }

    /// Categorizes MPV error messages for Sentry fingerprinting
    private func categorizeMPVError(_ message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("loading failed") {
            return "loading-failed"
        } else if lowercased.contains("unrecognized file format") || lowercased.contains("unknown format") {
            return "unrecognized-format"
        } else if lowercased.contains("network") || lowercased.contains("connection") {
            return "network-error"
        } else if lowercased.contains("demuxer") {
            return "demuxer-error"
        } else if lowercased.contains("codec") || lowercased.contains("decode") {
            return "codec-error"
        } else if lowercased.contains("audio") {
            return "audio-error"
        } else if lowercased.contains("video") {
            return "video-error"
        } else {
            return "unknown"
        }
    }
}
