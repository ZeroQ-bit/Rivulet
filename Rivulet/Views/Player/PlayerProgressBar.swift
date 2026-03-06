//
//  PlayerProgressBar.swift
//  Rivulet
//
//  Focusable progress bar for video playback with Siri Remote support
//

import SwiftUI

struct PlayerProgressBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @FocusState private var isFocused: Bool
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var body: some View {
        VStack(spacing: 12) {
            // Progress Track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background Track
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(height: isFocused ? 12 : 6)

                    // Buffered indicator (optional - could add later)

                    // Progress Fill
                    Capsule()
                        .fill(isFocused ? Color.white : Color.white.opacity(0.8))
                        .frame(
                            width: geometry.size.width * (isSeeking ? seekPosition : progress),
                            height: isFocused ? 12 : 6
                        )

                    // Seek Thumb (when focused)
                    if isFocused {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .offset(x: geometry.size.width * (isSeeking ? seekPosition : progress) - 12)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .frame(height: 24)

            // Time Labels
            HStack {
                Text(formatTime(isSeeking ? duration * seekPosition : currentTime))
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Spacer()

                Text("-\(formatTime(duration - (isSeeking ? duration * seekPosition : currentTime)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 4)
        .focusable()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                seekPosition = progress
                isSeeking = false
            } else if isSeeking {
                // Commit seek on focus loss
                onSeek(duration * seekPosition)
                isSeeking = false
            }
        }
        .onMoveCommand { direction in
            guard isFocused else { return }
            isSeeking = true

            let stepSmall = 0.005  // ~0.5% per tap for fine control

            switch direction {
            case .left:
                seekPosition = max(0, seekPosition - stepSmall)
            case .right:
                seekPosition = min(1, seekPosition + stepSmall)
            default:
                break
            }
        }
        .onPlayPauseCommand {
            if isSeeking {
                onSeek(duration * seekPosition)
                isSeeking = false
            }
        }
        .onExitCommand {
            if isSeeking {
                // Cancel seek, revert to current position
                seekPosition = progress
                isSeeking = false
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.1), value: seekPosition)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }

        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        PlayerProgressBar(
            currentTime: 1234,
            duration: 7200,
            onSeek: { time in
            }
        )
        .padding(40)
    }
}
