//
//  HeroButtonRow.swift
//  Rivulet
//
//  The focusable action row for the hero carousel: Play, Watchlist (mark
//  watched), Info, Next. Mirrors the `AppStoreActionButtonStyle` pattern
//  used by `PlexDetailView` for consistent focus treatment across the app.
//

import SwiftUI

enum HeroButton: Hashable {
    case play
    case watchlist
    case info
    case next
}

struct HeroButtonRow: View {
    let isResolvingPlay: Bool
    let isWatched: Bool
    let canAdvance: Bool

    @FocusState.Binding var focusedButton: HeroButton?

    let onPlay: () -> Void
    let onToggleWatched: () -> Void
    let onInfo: () -> Void
    let onNext: () -> Void

    // Match detail view button sizing for visual consistency.
    private let pillButtonHeight: CGFloat = 68
    private let circleButtonSize: CGFloat = 68

    var body: some View {
        HStack(spacing: 18) {
            playButton
            watchlistButton
            infoButton
            if canAdvance {
                nextButton
            }
        }
    }

    // MARK: - Primary Play

    private var playButton: some View {
        Button(action: { if !isResolvingPlay { onPlay() } }) {
            HStack(spacing: 10) {
                if isResolvingPlay {
                    ProgressView()
                        .tint(focusedButton == .play ? .black : .white)
                } else {
                    Image(systemName: "play.fill")
                }
                Text("Play")
            }
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 34)
            .frame(minWidth: 150)
            .frame(height: pillButtonHeight)
        }
        .buttonStyle(HeroActionButtonStyle(
            isFocused: focusedButton == .play,
            cornerRadius: pillButtonHeight / 2
        ))
        .focused($focusedButton, equals: .play)
    }

    // MARK: - Secondary Circle Buttons

    private var watchlistButton: some View {
        Button(action: onToggleWatched) {
            Image(systemName: isWatched ? "checkmark" : "plus")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(HeroActionButtonStyle(
            isFocused: focusedButton == .watchlist,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .watchlist)
        .accessibilityLabel(isWatched ? "Mark unwatched" : "Mark watched")
    }

    private var infoButton: some View {
        Button(action: onInfo) {
            Image(systemName: "info.circle")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(HeroActionButtonStyle(
            isFocused: focusedButton == .info,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .info)
        .accessibilityLabel("More info")
    }

    private var nextButton: some View {
        Button(action: onNext) {
            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(HeroActionButtonStyle(
            isFocused: focusedButton == .next,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .next)
        .accessibilityLabel("Next featured item")
    }
}

private struct HeroActionButtonStyle: ButtonStyle {
    var isFocused: Bool
    var cornerRadius: CGFloat
    var isPrimary: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isFocused ? .white : .white.opacity(isPrimary ? 0.18 : 0.12))
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(isFocused ? 0 : 0.9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isFocused ? .white.opacity(0.55) : .white.opacity(0.22), lineWidth: isFocused ? 1.2 : 0.7)
            )
            .shadow(color: .black.opacity(0.35), radius: isFocused ? 18 : 10, x: 0, y: isFocused ? 8 : 4)
            .shadow(color: .white.opacity(isFocused ? 0.22 : 0), radius: 24, x: 0, y: 0)
            .scaleEffect(isFocused ? 1.09 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .hoverEffectDisabled()
            .focusEffectDisabled()
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isFocused)
            .animation(.spring(response: 0.16, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
