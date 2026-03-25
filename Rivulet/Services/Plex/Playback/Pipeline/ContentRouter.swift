//
//  ContentRouter.swift
//  Rivulet
//
//  Decides the playback path for content:
//    1. AVPlayer direct — MP4/MOV with native audio, no DV P7
//    2. Local remux — DV P7 only (Plex can't do P7→P8.1 conversion)
//    3. Plex HLS — MKV remux, DTS/TrueHD transcode, live TV, or fallback
//

import Foundation

/// The ingestion path for a piece of content.
enum PlaybackRoute: Sendable, CustomStringConvertible {
    /// AVPlayer opens Plex URL directly — MP4/MOV with native audio
    case avPlayerDirect(url: URL, headers: [String: String]?)

    /// Local remux server — DV P7 remuxed to HLS fMP4 with P8.1 conversion
    case localRemux(url: URL, headers: [String: String]?, analysis: RemuxAnalysis)

    /// HLS via server-side remux/transcode — MKV remux, DTS transcode, live TV
    case hls(url: URL, headers: [String: String]?)

    var description: String {
        switch self {
        case .avPlayerDirect: return "AVPlayerDirect"
        case .localRemux: return "LocalRemux"
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
    ///
    /// Three paths:
    /// 1. **AVPlayer direct** — MP4/MOV with native audio, no DV P7
    /// 2. **Local remux** — DV P7 only (Plex can't do P7→P8.1 conversion)
    /// 3. **Plex HLS** — MKV remux, DTS/TrueHD transcode, live TV, or fallback
    static func plan(for context: ContentRoutingContext) -> PlaybackPlan {
        let audioCodec = primaryAudioCodec(from: context.metadata) ?? "unknown"
        let container = context.metadata.Media?.first?.container ?? "unknown"
        var reasoning: [String] = []

        // Live TV always uses Plex HLS
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

        // Analyze content for remux requirements
        let analysis = RemuxContentAnalyzer.analyze(metadata: context.metadata)
        let hlsFallback = buildHLSRoute(context: context)

        // FFmpeg not available — can't do remux, and AVPlayer direct only works for native containers
        if !FFmpegDemuxer.isAvailable {
            if !analysis.needsRemux, let direct = buildAVPlayerDirectRoute(context: context) {
                reasoning.append("ffmpeg_unavailable_but_native_container")
                print("[ContentRouter] \(container) | audio=\(audioCodec) → AVPlayerDirect (FFmpeg unavailable, native container)")
                return PlaybackPlan(
                    policy: context.playbackPolicy,
                    primary: direct,
                    fallbacks: [hlsFallback],
                    reasoning: reasoning
                )
            }
            reasoning.append("ffmpeg_unavailable")
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (FFmpeg unavailable)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hlsFallback,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        // Path 1: AVPlayer direct — native container + native audio + no DV P7
        if !analysis.needsRemux, let direct = buildAVPlayerDirectRoute(context: context) {
            reasoning.append(contentsOf: analysis.reasoning)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → AVPlayerDirect")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: direct,
                fallbacks: [hlsFallback],
                reasoning: reasoning
            )
        }

        // Path 2: Local remux — ONLY for DV P7→P8.1 conversion (Plex can't do this)
        if analysis.needsDVConversion, let remuxRoute = buildLocalRemuxRoute(context: context, analysis: analysis) {
            reasoning.append(contentsOf: analysis.reasoning)
            print("[ContentRouter] \(container) | audio=\(audioCodec) → LocalRemux (DV P7 conversion)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: remuxRoute,
                fallbacks: [hlsFallback],
                reasoning: reasoning
            )
        }

        // Path 3: Plex HLS — server remuxes MKV→fMP4, transcodes DTS/TrueHD, etc.
        if analysis.needsRemux {
            reasoning.append(contentsOf: analysis.reasoning)
            reasoning.append("plex_server_remux")
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (server remux)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hlsFallback,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        // Path 4: Plex HLS fallback
        reasoning.append("fallback_to_hls")
        print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (fallback)")
        return PlaybackPlan(
            policy: context.playbackPolicy,
            primary: hlsFallback,
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

    /// Build direct Plex URL for raw file access (used by both AVPlayer direct and local remux).
    private static func buildDirectPlayURL(context: ContentRoutingContext) -> (url: URL, headers: [String: String])? {
        guard let media = context.metadata.Media?.first,
              let part = media.Part?.first else {
            return nil
        }

        var components = URLComponents(url: context.serverURL, resolvingAgainstBaseURL: false)!
        components.path = part.key

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.authToken))
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        let headers = ["X-Plex-Token": context.authToken]
        return (url, headers)
    }

    /// Build AVPlayer direct route — AVPlayer opens Plex URL directly.
    private static func buildAVPlayerDirectRoute(context: ContentRoutingContext) -> PlaybackRoute? {
        guard let (url, headers) = buildDirectPlayURL(context: context) else { return nil }
        return .avPlayerDirect(url: url, headers: headers)
    }

    /// Build local remux route — raw file URL passed to FFmpegRemuxSession.
    private static func buildLocalRemuxRoute(context: ContentRoutingContext, analysis: RemuxAnalysis) -> PlaybackRoute? {
        guard let (url, headers) = buildDirectPlayURL(context: context) else { return nil }
        return .localRemux(url: url, headers: headers, analysis: analysis)
    }

    private static func buildHLSRoute(context: ContentRoutingContext) -> PlaybackRoute {
        // HLS URL building is handled by PlexNetworkManager.
        // This signals that the HLS path should be used.
        return .hls(url: context.serverURL, headers: ["X-Plex-Token": context.authToken])
    }

}
