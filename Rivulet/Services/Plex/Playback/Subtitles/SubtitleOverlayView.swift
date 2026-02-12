//
//  SubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay view for rendering subtitles.
//

import SwiftUI

/// Overlay view that displays current subtitle cues
struct SubtitleOverlayView: View {
    @ObservedObject var subtitleManager: SubtitleManager

    /// Vertical offset from bottom (for player controls)
    var bottomOffset: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()

                if !subtitleManager.currentCues.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(subtitleManager.currentCues) { cue in
                            SubtitleTextView(text: cue.text)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.bottom, bottomOffset)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)  // Don't interfere with player controls
    }
}

/// Individual subtitle text with styling
private struct SubtitleTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.75))
            )
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
    }

    private var subtitleFontSize: CGFloat {
        #if os(tvOS)
        return 42
        #else
        return 24
        #endif
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray

        SubtitleOverlayView(
            subtitleManager: {
                let manager = SubtitleManager()
                // Note: In real usage, cues come from parsed subtitle file
                return manager
            }()
        )
    }
}
