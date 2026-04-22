//
//  StreamInfo.swift
//  Rivulet
//
//  Result of provider.resolveStream(for:sourceID:). The chosen MediaSource
//  with streamURL materialized, plus per-session metadata for progress
//  reporting.
//

import Foundation

struct StreamInfo: Sendable {
    let source: MediaSource
    let playSessionID: String?
    /// false during HLS transcode where tracks come from the manifest, not from MediaSource fields.
    let trackInfoAvailable: Bool
}
