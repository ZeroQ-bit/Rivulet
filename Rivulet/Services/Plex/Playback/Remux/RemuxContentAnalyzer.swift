//
//  RemuxContentAnalyzer.swift
//  Rivulet
//
//  Analyzes PlexMetadata to decide whether content needs local remuxing
//  and what processing operations are required.
//

import Foundation

/// Analysis result for content routing decisions.
struct RemuxAnalysis: Sendable {
    /// Whether content needs local remux (false = AVPlayer can play directly)
    let needsRemux: Bool
    /// Whether audio needs transcoding (DTS/TrueHD → EAC3)
    let needsAudioTranscode: Bool
    /// Whether DV profile conversion is needed (P7/P8.6 → P8.1)
    let needsDVConversion: Bool
    /// Source container format
    let container: String
    /// Primary audio codec
    let audioCodec: String
    /// Reason for the routing decision
    let reasoning: [String]
}

/// Analyzes media metadata to determine remux requirements.
struct RemuxContentAnalyzer {

    /// Audio codecs AVPlayer can play natively in fMP4/HLS
    private static let avPlayerNativeAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "ec-3",
        "flac", "alac",
        "mp3", "mp2",
    ]

    /// Containers AVPlayer can open directly
    private static let avPlayerNativeContainers: Set<String> = [
        "mp4", "mov", "m4v",
    ]

    /// Audio codecs that require transcoding (AVPlayer can't decode them)
    private static let transcodeRequiredAudioCodecs: Set<String> = [
        "dts", "dca",
        "dts-hd", "dtshd",
        "truehd", "mlp",
    ]

    /// Analyze content to determine the optimal playback path.
    static func analyze(metadata: PlexMetadata) -> RemuxAnalysis {
        let container = metadata.Media?.first?.container?.lowercased() ?? "unknown"
        let audioCodec = primaryAudioCodec(from: metadata)?.lowercased() ?? "unknown"
        var reasoning: [String] = []

        // Check container compatibility
        let containerNative = avPlayerNativeContainers.contains(container)

        // Check audio compatibility
        let audioNative = isNativeAudioCodec(audioCodec)
        let audioNeedsTranscode = isTranscodeRequired(audioCodec)

        // Check DV profile
        let dvProfile = detectDVProfile(from: metadata)
        let needsDVConversion = dvProfile == 7

        // Routing decision
        let needsRemux: Bool
        if !containerNative {
            needsRemux = true
            reasoning.append("container_not_native:\(container)")
        } else if audioNeedsTranscode {
            needsRemux = true
            reasoning.append("audio_needs_transcode:\(audioCodec)")
        } else if needsDVConversion {
            needsRemux = true
            reasoning.append("dv_p7_needs_conversion")
        } else if !audioNative {
            // Unknown audio codec — try remux to be safe
            needsRemux = true
            reasoning.append("audio_codec_unknown:\(audioCodec)")
        } else {
            needsRemux = false
            reasoning.append("avplayer_direct:container=\(container),audio=\(audioCodec)")
        }

        return RemuxAnalysis(
            needsRemux: needsRemux,
            needsAudioTranscode: audioNeedsTranscode,
            needsDVConversion: needsDVConversion,
            container: container,
            audioCodec: audioCodec,
            reasoning: reasoning
        )
    }

    // MARK: - Private

    private static func primaryAudioCodec(from metadata: PlexMetadata) -> String? {
        if let media = metadata.Media?.first, let codec = media.audioCodec {
            return codec
        }
        if let part = metadata.Media?.first?.Part?.first,
           let audioStream = part.Stream?.first(where: { $0.isAudio }) {
            return audioStream.codec
        }
        return nil
    }

    private static func isNativeAudioCodec(_ codec: String) -> Bool {
        let normalized = codec.lowercased()
        return avPlayerNativeAudioCodecs.contains(normalized) ||
               avPlayerNativeAudioCodecs.contains(where: { normalized.hasPrefix($0) })
    }

    private static func isTranscodeRequired(_ codec: String) -> Bool {
        let normalized = codec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return transcodeRequiredAudioCodecs.contains(where: { target in
            let normalizedTarget = target
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            return normalized == normalizedTarget || normalized.hasPrefix(normalizedTarget)
        })
    }

    private static func detectDVProfile(from metadata: PlexMetadata) -> UInt8? {
        guard let part = metadata.Media?.first?.Part?.first,
              let videoStream = part.Stream?.first(where: { $0.isVideo }) else {
            return nil
        }

        // Plex exposes DOVIProfile in the stream metadata
        if let profile = videoStream.DOVIProfile {
            return UInt8(profile)
        }

        return nil
    }
}
