//
//  AudioTrack.swift
//  Rivulet
//
//  Per-audio-stream metadata for the audio picker.
//

import Foundation

struct AudioTrack: Hashable, Sendable, Identifiable {
    let id: String
    let index: Int                 // stream index in the container (AVPlayer track index)
    let codec: String              // "eac3", "dts", "truehd", "aac", "opus"
    let channels: Int?             // 2, 6, 8
    let channelLayout: String?     // "5.1", "7.1", "Atmos" if present
    let language: String?          // "en", "ja"
    let title: String?             // displayable (e.g. "English Commentary")
    let bitrate: Int?
    let samplingRate: Int?
    let isDefault: Bool
    let isForced: Bool
}
