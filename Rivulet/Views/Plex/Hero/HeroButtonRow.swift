//
//  HeroButtonRow.swift
//  Rivulet
//
//  The focusable action row for the hero carousel: Play, Watchlist, Info,
//  Next. Mirrors the `AppStoreActionButtonStyle` pattern used by
//  `PlexDetailView` for consistent focus treatment across the app.
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
    let isOnWatchlist: Bool
    let canAdvance: Bool

    @FocusState.Binding var focusedButton: HeroButton?

    let onPlay: () -> Void
    let onToggleWatchlist: () -> Void
    let onInfo: () -> Void
    let onNext: () -> Void

    // Match detail view button sizing for visual consistency.
    private let pillButtonHeight: CGFloat = 66
    private let circleButtonSize: CGFloat = 66

    var body: some View {
        HStack(spacing: 16) {
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
            .padding(.horizontal, 32)
            .frame(height: pillButtonHeight)
        }
        .buttonStyle(AppStoreActionButtonStyle(
            isFocused: focusedButton == .play,
            cornerRadius: pillButtonHeight / 2
        ))
        .focused($focusedButton, equals: .play)
    }

    // MARK: - Secondary Circle Buttons

    private var watchlistButton: some View {
        Button(action: onToggleWatchlist) {
            Image(systemName: isOnWatchlist ? "bookmark.fill" : "bookmark")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(AppStoreActionButtonStyle(
            isFocused: focusedButton == .watchlist,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .watchlist)
        .accessibilityLabel(isOnWatchlist ? "Remove from Watchlist" : "Add to Watchlist")
    }

    private var infoButton: some View {
        Button(action: onInfo) {
            Image(systemName: "info.circle")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(AppStoreActionButtonStyle(
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
        .buttonStyle(AppStoreActionButtonStyle(
            isFocused: focusedButton == .next,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .next)
        .accessibilityLabel("Next featured item")
    }
}
