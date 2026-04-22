//
//  MediaSource.swift
//  Rivulet
//
//  One playable variant of an item. Most items have exactly one;
//  Plex/Jellyfin return multiple when a title has multiple file versions
//  (4K + 1080p, etc.).
//

import Foundation

struct MediaSource: Hashable, Sendable, Identifiable {
    let id: String                 // provider-native (Plex Media.id / Jellyfin Id)
    let container: String?         // "mkv", "mp4", "ts", "m2ts", "webm"
    let duration: TimeInterval     // seconds
    let bitrate: Int?              // bits/second
    let fileSize: Int64?           // bytes; nil for transcoded streams
    let fileName: String?          // display name for source picker ("4K HDR", etc.)

    let videoTracks: [VideoTrack]  // usually 1, rarely more
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]

    let streamKind: StreamKind
    let streamURL: URL?            // nil until provider.resolveStream(for:) materializes it

    enum StreamKind: Sendable, Hashable, Codable {
        case directPlay
        case hlsTranscode
        case progressiveTranscode
    }
}

extension MediaSource {
    /// Display badges for the source picker / hero quality row.
    /// Returns labels like ["4K", "DV", "5.1"] derived from track metadata.
    /// Order is stable: resolution first, then HDR/range, then audio.
    func qualityBadges() -> [String] {
        var badges: [String] = []

        if let video = videoTracks.first {
            // Resolution
            if let height = video.height {
                if height >= 2000 { badges.append("4K") }
                else if height >= 1080 { badges.append("HD") }
                // 720 and below: no badge
            }

            // HDR / DV
            switch video.videoRange {
            case .dolbyVision: badges.append("DV")
            case .hdr10, .hdr10Plus: badges.append("HDR")
            case .hlg: badges.append("HLG")
            case .sdr: break
            }
        }

        if let audio = audioTracks.first {
            if let layout = audio.channelLayout, !layout.isEmpty {
                // Plex layouts: "5.1", "7.1", "Atmos", "Stereo".
                // Drop Stereo — uninteresting in a badge row.
                if layout.lowercased() != "stereo" {
                    badges.append(layout)
                }
            } else if let channels = audio.channels, channels >= 6 {
                badges.append("\(channels - 1).1")
            }
        }

        return badges
    }
}
