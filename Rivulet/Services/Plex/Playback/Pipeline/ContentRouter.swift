//
//  ContentRouter.swift
//  Rivulet
//
//  Decides whether content should use DirectPlay (FFmpeg demuxer) or HLS
//  (server-side processing) based on audio codec compatibility and content type.
//

import Foundation

/// The ingestion path for a piece of content.
enum PlaybackRoute: Sendable, CustomStringConvertible {
    /// Direct play via FFmpeg demuxer — raw file streaming, no server processing
    case directPlay(url: URL, headers: [String: String]?)

    /// HLS via server-side remux/transcode — for incompatible audio or live TV
    case hls(url: URL, headers: [String: String]?)

    var description: String {
        switch self {
        case .directPlay: return "DirectPlay"
        case .hls: return "HLS"
        }
    }
}

/// Playback policy for routed startup and fallback behavior.
enum PlaybackPolicy: String, Sendable {
    case directPlayFirst

    static let `default`: PlaybackPolicy = .directPlayFirst
}

/// Classification of direct-play failures used for fallback decisions and diagnostics.
enum DirectPlayFailureKind: String, Sendable {
    case unsupportedCodec
    case demuxInit
    case decodeInit
    case runtimeFatal
    case network
    case unknown
}

/// Playback startup plan with primary route, fallback routes, and routing reasons.
struct PlaybackPlan: Sendable, CustomStringConvertible {
    let policy: PlaybackPolicy
    let primary: PlaybackRoute
    let fallbacks: [PlaybackRoute]
    let reasoning: [String]

    var description: String {
        let fallbackSummary = fallbacks.map(\.description).joined(separator: ",")
        return "policy=\(policy.rawValue) primary=\(primary.description) fallbacks=[\(fallbackSummary)]"
    }
}

/// Content routing configuration
struct ContentRoutingContext: Sendable {
    let metadata: PlexMetadata
    let serverURL: URL
    let authToken: String

    /// Whether this is live TV content
    var isLiveTV: Bool = false

    /// Force HLS even if direct play is possible (for fallback)
    var forceHLS: Bool = false

    /// Whether DV profile conversion is needed
    var requiresProfileConversion: Bool = false

    /// Preferred playback policy. Defaults to direct-play-first for VOD.
    var playbackPolicy: PlaybackPolicy = .default
}

/// Analyzes media metadata to choose the optimal playback pipeline.
struct ContentRouter {

    // MARK: - Audio Codec Compatibility

    /// Audio codecs that Apple TV can decode natively via AudioToolbox.
    /// Content with these codecs can use DirectPlay (FFmpeg demuxes, AudioToolbox decodes).
    static let nativeAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "ec-3",     // Dolby formats
        "flac",                             // Lossless
        "alac",                             // Apple Lossless
        "mp3", "mp2",                       // MPEG audio
        "pcm", "pcm_s16le", "pcm_s24le",  // PCM variants
    ]

    /// Audio codecs that require server-side transcode UNLESS FFmpeg audio decoding is available.
    /// When FFmpegAudioDecoder is linked, these are decoded client-side to PCM instead.
    static let transcodeRequiredCodecs: Set<String> = [
        "dts", "dca",                           // DTS Core
        "dts-hd", "dtshd",                      // DTS-HD (MA and HRA)
        "truehd", "mlp",                        // Dolby TrueHD / MLP
    ]

    /// Audio codecs that can be decoded client-side via FFmpegAudioDecoder.
    /// These overlap with transcodeRequiredCodecs — when FFmpeg is available,
    /// client-side decoding takes priority over HLS transcode.
    static let clientDecodableCodecs: Set<String> = [
        "dts", "dca",                           // DTS Core
        "dts-hd", "dtshd",                      // DTS-HD (MA and HRA)
        "truehd", "mlp",                        // Dolby TrueHD / MLP
    ]

    // MARK: - Route Decision

    /// Determine the primary playback route for the given content.
    /// Maintained for compatibility with existing call sites.
    static func route(for context: ContentRoutingContext) -> PlaybackRoute {
        plan(for: context).primary
    }

    /// Determine the playback startup/fallback plan for the given content.
    static func plan(for context: ContentRoutingContext) -> PlaybackPlan {
        let audioCodec = primaryAudioCodec(from: context.metadata) ?? "unknown"
        let container = context.metadata.Media?.first?.container ?? "unknown"
        var reasoning: [String] = []

        // Live TV always uses HLS
        if context.isLiveTV {
            reasoning.append("live_tv_requires_hls")
            let hls = buildHLSRoute(context: context)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (live TV)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hls,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        // Force HLS fallback
        if context.forceHLS {
            reasoning.append("force_hls_requested")
            let hls = buildHLSRoute(context: context)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (forced)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hls,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        // FFmpeg not available — can't do direct play
        if !FFmpegDemuxer.isAvailable {
            reasoning.append("ffmpeg_unavailable")
            let hls = buildHLSRoute(context: context)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (FFmpeg unavailable)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hls,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        if shouldPreferHLSForDVConversion(context: context, primaryAudioCodec: audioCodec) {
            reasoning.append("dv_conversion_prefers_hls_for_client_decode_only_audio:\(audioCodec)")
            let hls = buildHLSRoute(context: context)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (DV conversion + no native audio fallback)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hls,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        // Direct-play-first policy for VOD:
        // if we can build a direct-play URL, try it first regardless of audio codec.
        if let direct = buildDirectPlayRouteIfPossible(context: context) {
            reasoning.append("direct_play_first_vod")
            let hlsFallback = buildHLSRoute(context: context)
            if requiresTranscode(audioCodec: audioCodec) {
                reasoning.append("audio_codec_client_decode_expected:\(audioCodec)")
            } else if !isNativeAudioCodec(audioCodec) {
                reasoning.append("audio_codec_unverified_but_direct_play_attempted:\(audioCodec)")
            } else {
                reasoning.append("audio_codec_native:\(audioCodec)")
            }
            print("[ContentRouter] \(container) | audio=\(audioCodec) → DirectPlay (policy=\(context.playbackPolicy.rawValue), fallback=HLS)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: direct,
                fallbacks: [hlsFallback],
                reasoning: reasoning
            )
        }

        // Hard blocker: no direct-play source available.
        reasoning.append("direct_play_source_unavailable")
        let hls = buildHLSRoute(context: context)
        print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (no direct-play source)")
        return PlaybackPlan(
            policy: context.playbackPolicy,
            primary: hls,
            fallbacks: [],
            reasoning: reasoning
        )
    }

    /// Check if a specific audio codec requires server-side transcode.
    static func requiresTranscode(audioCodec: String) -> Bool {
        let normalized = audioCodec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return transcodeRequiredCodecs.contains(where: { codec in
            let normalizedCodec = codec.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            return normalized == normalizedCodec || normalized.hasPrefix(normalizedCodec)
        })
    }

    /// Check if the audio codec can be decoded client-side via FFmpegAudioDecoder.
    static func isClientDecodable(audioCodec: String) -> Bool {
        let normalized = audioCodec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return clientDecodableCodecs.contains(where: { codec in
            let normalizedCodec = codec.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            return normalized == normalizedCodec || normalized.hasPrefix(normalizedCodec)
        })
    }

    /// Check if the audio codec is natively supported.
    static func isNativeAudioCodec(_ codec: String) -> Bool {
        let lower = codec.lowercased()
        if lower == "opus" || lower.hasPrefix("opus") {
            if #available(tvOS 17.0, iOS 17.0, *) {
                return true
            }
            return false
        }
        return nativeAudioCodecs.contains(lower) ||
               nativeAudioCodecs.contains(where: { lower.hasPrefix($0) })
    }

    // MARK: - Private: Audio Analysis

    /// Extract the primary audio codec from PlexMetadata.
    private static func primaryAudioCodec(from metadata: PlexMetadata) -> String? {
        // First try media-level audioCodec
        if let media = metadata.Media?.first, let codec = media.audioCodec {
            return codec
        }

        // Fall back to first audio stream's codec
        if let part = metadata.Media?.first?.Part?.first,
           let audioStream = part.Stream?.first(where: { $0.isAudio }) {
            return audioStream.codec
        }

        return nil
    }

    // MARK: - Private: Route Building

    private static func buildDirectPlayRouteIfPossible(context: ContentRoutingContext) -> PlaybackRoute? {
        // Build direct play URL: raw file access via Plex
        // Uses the part key to get the raw file bytes
        guard let media = context.metadata.Media?.first,
              let part = media.Part?.first else {
            return nil
        }

        var components = URLComponents(url: context.serverURL, resolvingAgainstBaseURL: false)!
        components.path = part.key

        // Add auth as query parameter (FFmpeg will send it)
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.authToken))
        components.queryItems = queryItems

        guard let url = components.url else {
            return nil
        }

        // Also pass auth in headers for redundancy
        let headers = [
            "X-Plex-Token": context.authToken
        ]

        return .directPlay(url: url, headers: headers)
    }

    private static func shouldPreferHLSForDVConversion(
        context: ContentRoutingContext,
        primaryAudioCodec: String
    ) -> Bool {
        guard context.requiresProfileConversion else { return false }
        guard isClientDecodable(audioCodec: primaryAudioCodec) || requiresTranscode(audioCodec: primaryAudioCodec) else {
            return false
        }

        let audioStreams = context.metadata.Media?
            .first?
            .Part?
            .first?
            .Stream?
            .filter(\.isAudio) ?? []

        // Without detailed stream metadata we keep the existing optimistic DirectPlay path.
        guard !audioStreams.isEmpty else { return false }

        let hasNativeFallback = audioStreams.contains { stream in
            guard let codec = stream.codec else { return false }
            return isNativeAudioCodec(codec)
        }
        return !hasNativeFallback
    }

    private static func buildHLSRoute(context: ContentRoutingContext) -> PlaybackRoute {
        // HLS URL building is handled by PlexNetworkManager.buildHLSDirectPlayURL()
        // or buildDirectStreamURL() — the caller provides the final URL.
        // This is a placeholder that signals HLS should be used.
        // The actual URL construction happens in RivuletPlayer.load() which
        // calls PlexNetworkManager for the appropriate HLS URL.
        return .hls(url: context.serverURL, headers: ["X-Plex-Token": context.authToken])
    }

}
