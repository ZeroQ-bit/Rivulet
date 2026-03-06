//
//  EpisodeSummaryOverlay.swift
//  Rivulet
//
//  Post-video overlay for TV episodes showing next episode info and autoplay countdown
//

import SwiftUI

struct EpisodeSummaryOverlay: View {
    @ObservedObject var viewModel: UniversalPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    // Focus namespace for default focus control
    @Namespace private var buttonNamespace
    @FocusState private var focusedButton: PostVideoFocusTarget?
    @State private var hasConsumedInitialFocus = false

    private var hasNextEpisode: Bool {
        viewModel.nextEpisode != nil
    }

    private var countdownActive: Bool {
        viewModel.countdownSeconds > 0 && !viewModel.isCountdownPaused
    }

    private var autoplayEnabled: Bool {
        // Default to enabled (5 seconds) if key doesn't exist
        if UserDefaults.standard.object(forKey: "autoplayCountdown") == nil {
            return true
        }
        return UserDefaults.standard.integer(forKey: "autoplayCountdown") > 0
    }

    private func setDefaultFocus() {
        focusedButton = hasNextEpisode ? .playNext : .close
    }

    /// Cancel countdown on any user interaction
    private func cancelCountdownOnInteraction() {
        // Ignore the first auto-focus when the overlay appears
        if !hasConsumedInitialFocus {
            hasConsumedInitialFocus = true
            return
        }

        if countdownActive {
            viewModel.cancelCountdown()
        }
    }

    /// Background image (art preferred, fallback to thumb)
    private var backgroundImage: UIImage? {
        viewModel.loadingArtImage ?? viewModel.loadingThumbImage
    }

    var body: some View {
        ZStack {
            // Blurred background image (or solid black fallback)
            if let image = backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 50)
                    .overlay(Color.black.opacity(0.5))
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer()

                // Main content area - centered
                VStack(spacing: 32) {
                    // Header
                    if hasNextEpisode {
                        Text("Up Next")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        VStack(spacing: 8) {
                            Text("End of Series")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)

                            Text("You've watched all available episodes")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    // Next episode card
                    if let nextEpisode = viewModel.nextEpisode {
                        NextEpisodeCard(
                            episode: nextEpisode,
                            serverURL: viewModel.serverURL,
                            authToken: viewModel.authToken
                        )
                        .frame(maxWidth: 700)
                    }

                    // Countdown and buttons
                    HStack(spacing: 40) {
                        if hasNextEpisode {
                            // Countdown ring (only if autoplay enabled)
                            if autoplayEnabled && countdownActive {
                                CountdownRing(
                                    totalSeconds: UserDefaults.standard.integer(forKey: "autoplayCountdown"),
                                    remainingSeconds: viewModel.countdownSeconds,
                                    isPaused: viewModel.isCountdownPaused
                                )
                            }

                            // Play Next button
                            PostVideoButton(
                                title: countdownActive ? "Play Now" : "Play Next",
                                icon: "play.fill",
                                isPrimary: true,
                                isFocused: focusedButton == .playNext,
                                onFocusChange: cancelCountdownOnInteraction
                            ) {
                                Task { await viewModel.playNextEpisode() }
                            }
                            .prefersDefaultFocus(in: buttonNamespace)
                            .focused($focusedButton, equals: .playNext)

                            // Dismiss button (only if countdown active)
                            if countdownActive {
                                PostVideoButton(
                                    title: "Dismiss",
                                    icon: nil,
                                    isPrimary: false,
                                    isFocused: focusedButton == .cancel,
                                    onFocusChange: cancelCountdownOnInteraction
                                ) {
                                    viewModel.cancelCountdown()
                                }
                                .focused($focusedButton, equals: .cancel)
                            }
                        }

                        // Dismiss button - returns to fullscreen video
                        if !hasNextEpisode || !countdownActive {
                            PostVideoButton(
                                title: "Dismiss",
                                icon: "xmark",
                                isPrimary: !hasNextEpisode,  // Primary if no next episode
                                isFocused: focusedButton == .close,
                                onFocusChange: cancelCountdownOnInteraction
                            ) {
                                viewModel.dismissPostVideo()
                            }
                            .prefersDefaultFocus(!hasNextEpisode, in: buttonNamespace)
                            .focused($focusedButton, equals: .close)
                        }
                    }

                    // Navigation buttons (Go to Season / Go to Show)
                    HStack(spacing: 24) {
                        if viewModel.metadata.parentRatingKey != nil {
                            PostVideoButton(
                                title: "Go to Season",
                                icon: "list.number",
                                isPrimary: false,
                                isFocused: focusedButton == .season,
                                onFocusChange: cancelCountdownOnInteraction
                            ) {
                                viewModel.navigateToSeason()
                                dismiss()
                            }
                            .focused($focusedButton, equals: .season)
                        }

                        if viewModel.metadata.grandparentRatingKey != nil {
                            PostVideoButton(
                                title: "Go to Show",
                                icon: "tv",
                                isPrimary: false,
                                isFocused: focusedButton == .show,
                                onFocusChange: cancelCountdownOnInteraction
                            ) {
                                viewModel.navigateToShow()
                                dismiss()
                            }
                            .focused($focusedButton, equals: .show)
                        }
                    }

                    // Episode summary
                    if let summary = viewModel.metadata.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("About This Episode")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))

                            Text(summary)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: 800, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 80)

                Spacer()
            }
        }
        .focusScope(buttonNamespace)
        .focusSection()
        .onAppear {
            hasConsumedInitialFocus = false
            setDefaultFocus()
        }
        .onChange(of: hasNextEpisode) { _, _ in
            setDefaultFocus()
        }
        .onExitCommand {
            // Back button returns to fullscreen video, doesn't exit player
            viewModel.dismissPostVideo()
        }
        .onPlayPauseCommand {
            if hasNextEpisode {
                Task { await viewModel.playNextEpisode() }
            }
        }
    }
}

// MARK: - Post Video Button

struct PostVideoButton: View {
    let title: String
    let icon: String?
    let isPrimary: Bool
    var isFocused: Bool = false
    var onFocusChange: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: isPrimary ? 22 : 18, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: isPrimary ? 24 : 22, weight: isPrimary ? .semibold : .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isPrimary ? 32 : 28)
            .padding(.vertical, isPrimary ? 16 : 14)
            .background(
                Capsule()
                    .fill(buttonBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(buttonBorder, lineWidth: isFocused ? 3 : 1)
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
        }
        .buttonStyle(CardButtonStyle())
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocusChange?()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var buttonBackground: some ShapeStyle {
        if isPrimary {
            return AnyShapeStyle(isFocused ? Color.white.opacity(0.22) : Color.white.opacity(0.12))
        }
        return AnyShapeStyle(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
    }

    private var buttonBorder: Color {
        let focusedOpacity = isPrimary ? 0.35 : 0.25
        return isFocused ? .white.opacity(focusedOpacity) : .white.opacity(0.08)
    }
}

#Preview {
    EpisodeSummaryOverlay(
        viewModel: {
            let vm = UniversalPlayerViewModel(
                metadata: PlexMetadata(ratingKey: "1", type: "episode", title: "Test Episode"),
                serverURL: "http://localhost:32400",
                authToken: "test"
            )
            return vm
        }()
    )
}
