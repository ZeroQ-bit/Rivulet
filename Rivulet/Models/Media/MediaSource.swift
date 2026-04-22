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
