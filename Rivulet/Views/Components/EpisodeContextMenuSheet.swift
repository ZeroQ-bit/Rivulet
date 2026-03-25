//
//  EpisodeContextMenuSheet.swift
//  Rivulet
//
//  Context menu sheet for episode actions on tvOS
//

import SwiftUI


/// Context menu sheet for episode actions
struct EpisodeContextMenuSheet: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    let onDismiss: () -> Void
    let onWatchStatusChanged: ((Bool) -> Void)?
    let onPlayFromBeginning: (() -> Void)?

    @State private var isPerformingAction = false
    @State private var localIsWatched: Bool
    @FocusState private var focusedAction: String?

    private let networkManager = PlexNetworkManager.shared

    init(
        episode: PlexMetadata,
        serverURL: String,
        authToken: String,
        onDismiss: @escaping () -> Void,
        onWatchStatusChanged: ((Bool) -> Void)? = nil,
        onPlayFromBeginning: (() -> Void)? = nil
    ) {
        self.episode = episode
        self.serverURL = serverURL
        self.authToken = authToken
        self.onDismiss = onDismiss
        self.onWatchStatusChanged = onWatchStatusChanged
        self.onPlayFromBeginning = onPlayFromBeginning
        self._localIsWatched = State(initialValue: episode.isWatched)
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            // Sheet content
            VStack(spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 20)

                // Divider
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                // Actions
                VStack(spacing: 8) {
                    // Play from Beginning
                    if episode.isInProgress {
                        ContextMenuActionRow(
                            icon: "arrow.counterclockwise",
                            title: "Play from Beginning",
                            isFocused: focusedAction == "playFromBeginning",
                            isLoading: false
                        ) {
                            onPlayFromBeginning?()
                            onDismiss()
                        }
                        .focused($focusedAction, equals: "playFromBeginning")
                    }

                    // Mark as Watched / Unwatched
                    ContextMenuActionRow(
                        icon: localIsWatched ? "eye.slash.fill" : "eye.fill",
                        title: localIsWatched ? "Mark as Unwatched" : "Mark as Watched",
                        isFocused: focusedAction == "watchStatus",
                        isLoading: isPerformingAction
                    ) {
                        toggleWatchStatus()
                    }
                    .focused($focusedAction, equals: "watchStatus")

                    // Go to Episode Details
                    ContextMenuActionRow(
                        icon: "info.circle",
                        title: "Episode Details",
                        isFocused: focusedAction == "details",
                        isLoading: false
                    ) {
                        // TODO: Navigate to episode detail view
                        onDismiss()
                    }
                    .focused($focusedAction, equals: "details")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                // Divider
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                // Cancel button
                ContextMenuActionRow(
                    icon: "xmark",
                    title: "Cancel",
                    isFocused: focusedAction == "cancel",
                    isLoading: false,
                    isDestructive: false
                ) {
                    onDismiss()
                }
                .focused($focusedAction, equals: "cancel")
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 500)
            .padding(.horizontal, 80)
        }
        .onAppear {
            // Focus the first relevant action
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedAction = episode.isInProgress ? "playFromBeginning" : "watchStatus"
            }
        }
        .onExitCommand {
            onDismiss()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // Episode thumbnail
            CachedAsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    Rectangle()
                        .fill(Color(white: 0.2))
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if let epString = episode.episodeString {
                    Text(epString)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Text(episode.title ?? "Episode")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let duration = episode.durationFormatted {
                    Text(duration)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            // Watched indicator
            if localIsWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Actions

    private func toggleWatchStatus() {
        guard !isPerformingAction, let ratingKey = episode.ratingKey else { return }
        isPerformingAction = true

        Task {
            do {
                if localIsWatched {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: ratingKey
                    )
                } else {
                    try await networkManager.markWatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: ratingKey
                    )
                }

                await MainActor.run {
                    localIsWatched.toggle()
                    onWatchStatusChanged?(localIsWatched)
                    isPerformingAction = false
                }
            } catch {
                print("Failed to toggle watch status: \(error)")
                await MainActor.run {
                    isPerformingAction = false
                }
            }
        }
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Context Menu Action Row

private struct ContextMenuActionRow: View {
    let icon: String
    let title: String
    let isFocused: Bool
    let isLoading: Bool
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(width: 24)
                }

                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(textColor)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .disabled(isLoading)
    }

    private var iconColor: Color {
        if isDestructive {
            return isFocused ? .black : .red
        }
        return isFocused ? .black : .white.opacity(0.8)
    }

    private var textColor: Color {
        if isDestructive {
            return isFocused ? .black : .red
        }
        return isFocused ? .black : .white
    }
}

