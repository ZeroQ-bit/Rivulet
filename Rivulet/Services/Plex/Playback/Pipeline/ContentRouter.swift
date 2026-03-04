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

    /// Determine the playback route for the given content.
    static func route(for context: ContentRoutingContext) -> PlaybackRoute {
        let audioCodec = primaryAudioCodec(from: context.metadata) ?? "unknown"
        let container = context.metadata.Media?.first?.container ?? "unknown"

        // Live TV always uses HLS
        if context.isLiveTV {
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (live TV)")
            return buildHLSRoute(context: context)
        }

        // Force HLS fallback
        if context.forceHLS {
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (forced)")
            return buildHLSRoute(context: context)
        }

        // FFmpeg not available — can't do direct play
        if !FFmpegDemuxer.isAvailable {
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (FFmpeg unavailable)")
            return buildHLSRoute(context: context)
        }

        // If audio requires transcode (DTS/TrueHD), check if we can decode client-side first.
        // DV content needing profile conversion is allowed — the DirectPlay pipeline uses a
        // buffered video conversion task that decouples conversion from the read loop, with
        // auto-fallback to HDR10 if conversion can't sustain real-time throughput.
        if requiresTranscode(audioCodec: audioCodec) {
            if isClientDecodable(audioCodec: audioCodec) && FFmpegAudioDecoder.isAvailable {
                let dvNote = context.requiresProfileConversion ? " + DV conversion" : ""
                print("[ContentRouter] \(container) | audio=\(audioCodec)\(dvNote) → DirectPlay (client-side audio decode)")
                return buildDirectPlayRoute(context: context)
            }
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (audio needs transcode)")
            return buildHLSRoute(context: context)
        }

        // Keep direct play only for codecs verified as native on this OS.
        // If codec support is uncertain, prefer Plex audio remux/transcode.
        if !isNativeAudioCodec(audioCodec) {
            print("[ContentRouter] \(container) | audio=\(audioCodec) → HLS (audio codec not verified on current tvOS)")
            return buildHLSRoute(context: context)
        }

        // Audio is compatible — use direct play via FFmpeg
        print("[ContentRouter] \(container) | audio=\(audioCodec) → DirectPlay")
        return buildDirectPlayRoute(context: context)
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

    private static func buildDirectPlayRoute(context: ContentRoutingContext) -> PlaybackRoute {
        // Build direct play URL: raw file access via Plex
        // Uses the part key to get the raw file bytes
        guard let media = context.metadata.Media?.first,
              let part = media.Part?.first else {
            // No media info — fall back to HLS
            return buildHLSRoute(context: context)
        }

        var components = URLComponents(url: context.serverURL, resolvingAgainstBaseURL: false)!
        components.path = part.key

        // Add auth as query parameter (FFmpeg will send it)
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.authToken))
        components.queryItems = queryItems

        guard let url = components.url else {
            return buildHLSRoute(context: context)
        }

        // Also pass auth in headers for redundancy
        let headers = [
            "X-Plex-Token": context.authToken
        ]

        return .directPlay(url: url, headers: headers)
    }

    private static func buildHLSRoute(context: ContentRoutingContext) -> PlaybackRoute {
        // HLS URL building is handled by PlexNetworkManager.buildHLSDirectPlayURL()
        // or buildDirectStreamURL() — the caller provides the final URL.
        // This is a placeholder that signals HLS should be used.
        // The actual URL construction happens in RivuletPlayer.load() which
        // calls PlexNetworkManager for the appropriate HLS URL.
        return .hls(url: context.serverURL, headers: ["X-Plex-Token": context.authToken])
    }

    // MARK: - Diagnostic Info

    /// Human-readable explanation of why a particular route was chosen.
    static func routingExplanation(for context: ContentRoutingContext) -> String {
        if context.isLiveTV {
            return "Live TV → HLS (already HLS from source)"
        }
        if context.forceHLS {
            return "Forced HLS fallback"
        }

        let audioCodec = primaryAudioCodec(from: context.metadata) ?? "unknown"
        if requiresTranscode(audioCodec: audioCodec) {
            if isClientDecodable(audioCodec: audioCodec) && FFmpegAudioDecoder.isAvailable {
                let dvNote = context.requiresProfileConversion ? " + DV conversion (buffered)" : ""
                return "\(audioCodec) audio decoded client-side\(dvNote) → DirectPlay (FFmpeg decodes to PCM)"
            }
            return "\(audioCodec) audio requires transcode → HLS (Plex transcodes audio, copies video)"
        }
        if !isNativeAudioCodec(audioCodec) {
            return "\(audioCodec) audio support uncertain on current tvOS → HLS (prefer built-in pipeline compatibility)"
        }

        return "\(audioCodec) audio natively supported → DirectPlay (FFmpeg demuxes, VideoToolbox decodes)"
    }
}
