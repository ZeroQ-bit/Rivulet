//
//  AudioQualityBadge.swift
//  Rivulet
//
//  Small pill badge showing audio codec quality.
//  Gold tint for hi-res, white for lossless, muted for lossy.
//

import SwiftUI

struct AudioQualityBadge: View {
    let quality: AudioQuality

    /// Initialize from a PlexMetadata track
    init(track: PlexMetadata) {
        self.quality = MusicAudioProcessor.audioQuality(for: track)
    }

    /// Initialize directly with audio quality
    init(quality: AudioQuality) {
        self.quality = quality
    }

    /// Initialize from explicit parameters
    init(codec: String?, bitrate: Int? = nil, sampleRate: Int? = nil) {
        self.quality = MusicAudioProcessor.audioQuality(
            codec: codec,
            bitrate: bitrate,
            sampleRate: sampleRate
        )
    }

    var body: some View {
        Text(quality.displayLabel)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
    }

    // MARK: - Colors

    private var labelColor: Color {
        if quality.isHiRes {
            return Color(red: 0.95, green: 0.8, blue: 0.3) // Gold
        } else if quality.isLossless {
            return .white.opacity(0.9)
        } else {
            return .white.opacity(0.5)
        }
    }

    private var backgroundColor: Color {
        if quality.isHiRes {
            return Color(red: 0.95, green: 0.8, blue: 0.3).opacity(0.15)
        } else if quality.isLossless {
            return .white.opacity(0.1)
        } else {
            return .white.opacity(0.06)
        }
    }

    private var borderColor: Color {
        if quality.isHiRes {
            return Color(red: 0.95, green: 0.8, blue: 0.3).opacity(0.3)
        } else if quality.isLossless {
            return .white.opacity(0.15)
        } else {
            return .white.opacity(0.08)
        }
    }
}
