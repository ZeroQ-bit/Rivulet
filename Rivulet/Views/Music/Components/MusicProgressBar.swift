//
//  MusicProgressBar.swift
//  Rivulet
//
//  Slim progress bar for music playback with scrub support.
//

import SwiftUI

/// A thin progress bar for music playback.
/// Expands when focused for scrubbing via Siri Remote.
struct MusicProgressBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isExpanded: Bool
    var onSeek: ((TimeInterval) -> Void)?

    @FocusState private var isFocused: Bool
    @State private var scrubPosition: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return (scrubPosition ?? currentTime) / duration
    }

    var body: some View {
        VStack(spacing: 8) {
            // Progress track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(.white.opacity(0.15))

                    // Filled progress
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(.white.opacity(isFocused ? 0.9 : 0.6))
                        .frame(width: max(0, geometry.size.width * progress))
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: barHeight + (isFocused ? 12 : 0))

            // Time labels (only when expanded)
            if isExpanded {
                HStack {
                    Text(formatTime(scrubPosition ?? currentTime))
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    Text("-\(formatTime(max(0, duration - (scrubPosition ?? currentTime))))")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .focusable(isExpanded)
        .focused($isFocused)
        .digitalCrownRotation(
            Binding(
                get: { scrubPosition ?? currentTime },
                set: { newValue in
                    let clamped = max(0, min(duration, newValue))
                    scrubPosition = clamped
                }
            ),
            from: 0,
            through: duration,
            sensitivity: .medium
        )
        .onMoveCommand { direction in
            guard isExpanded, isFocused else { return }
            let step: TimeInterval = 10
            let current = scrubPosition ?? currentTime
            switch direction {
            case .left:
                scrubPosition = max(0, current - step)
            case .right:
                scrubPosition = min(duration, current + step)
            default:
                break
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused, let position = scrubPosition {
                onSeek?(position)
                scrubPosition = nil
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private var barHeight: CGFloat {
        isFocused ? 8 : (isExpanded ? 4 : 2)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
