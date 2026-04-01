//
//  PlaybackIndicator.swift
//  Rivulet
//
//  Animated "now playing" bars indicator (like Apple Music's equalizer icon).
//

import SwiftUI

/// Animated vertical bars indicating active music playback.
/// Pauses animation when music is paused.
struct PlaybackIndicator: View {
    let isPlaying: Bool
    var barCount: Int = 3
    var size: IndicatorSize = .small

    enum IndicatorSize {
        case small   // For track rows (12pt)
        case medium  // For queue items (16pt)
        case large   // For Now Playing (24pt)

        var height: CGFloat {
            switch self {
            case .small: return 12
            case .medium: return 16
            case .large: return 24
            }
        }

        var barWidth: CGFloat {
            switch self {
            case .small: return 2
            case .medium: return 3
            case .large: return 4
            }
        }

        var spacing: CGFloat {
            switch self {
            case .small: return 1.5
            case .medium: return 2
            case .large: return 3
            }
        }
    }

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                PlaybackBar(
                    isAnimating: isPlaying,
                    delay: Double(index) * 0.15,
                    barWidth: size.barWidth,
                    maxHeight: size.height
                )
            }
        }
        .frame(width: CGFloat(barCount) * (size.barWidth + size.spacing) - size.spacing,
               height: size.height)
    }
}

/// Individual animated bar
private struct PlaybackBar: View {
    let isAnimating: Bool
    let delay: Double
    let barWidth: CGFloat
    let maxHeight: CGFloat

    @State private var heightFraction: CGFloat = 0.3

    var body: some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(.white)
            .frame(width: barWidth, height: max(barWidth, maxHeight * heightFraction))
            .frame(height: maxHeight, alignment: .bottom)
            .onAppear {
                guard isAnimating else { return }
                startAnimation()
            }
            .onChange(of: isAnimating) { _, animating in
                if animating {
                    startAnimation()
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        heightFraction = 0.3
                    }
                }
            }
    }

    private func startAnimation() {
        withAnimation(
            .easeInOut(duration: 0.4 + Double.random(in: 0...0.2))
            .repeatForever(autoreverses: true)
            .delay(delay)
        ) {
            heightFraction = CGFloat.random(in: 0.5...1.0)
        }
    }
}
