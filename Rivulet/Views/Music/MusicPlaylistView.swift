//
//  MusicPlaylistView.swift
//  Rivulet
//
//  Playlist detail view showing tracks with play/shuffle actions.
//

import SwiftUI

struct MusicPlaylistView: View {
    let playlist: PlexMetadata
    @StateObject private var authManager = PlexAuthManager.shared

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var error: String?
    @FocusState private var focusedItem: PlaylistFocusItem?

    enum PlaylistFocusItem: Hashable {
        case play
        case shuffle
        case track(String) // ratingKey
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(error)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                contentView
            }
        }
        .task {
            await loadTracks()
        }
    }

    // MARK: - Content

    private var contentView: some View {
        HStack(alignment: .top, spacing: 60) {
            // Left: Playlist info
            playlistInfo
                .frame(width: 360)
                .padding(.top, 80)

            // Right: Track list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                        trackRow(track: track, number: index + 1)
                    }
                }
                .padding(.vertical, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Playlist Info

    private var playlistInfo: some View {
        VStack(spacing: 24) {
            // Artwork
            playlistArtView
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)

            // Title
            VStack(spacing: 8) {
                Text(playlist.title ?? "Playlist")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if !tracks.isEmpty {
                    Text("\(tracks.count) tracks \u{2022} \(totalDuration)")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let summary = playlist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }

            // Action buttons
            VStack(spacing: 12) {
                actionButton(
                    icon: "play.fill",
                    label: "Play",
                    item: .play
                ) {
                    MusicQueue.shared.playAlbum(tracks: tracks)
                }

                actionButton(
                    icon: "shuffle",
                    label: "Shuffle",
                    item: .shuffle
                ) {
                    var shuffled = tracks
                    shuffled.shuffle()
                    MusicQueue.shared.playAlbum(tracks: shuffled)
                }
            }
        }
    }

    // MARK: - Action Button

    private func actionButton(
        icon: String,
        label: String,
        item: PlaylistFocusItem,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedItem == item
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(isFocused ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? .white : .white.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .focused($focusedItem, equals: item)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    // MARK: - Track Row

    private func trackRow(track: PlexMetadata, number: Int) -> some View {
        let isCurrent = MusicQueue.shared.currentTrack?.ratingKey == track.ratingKey
        let isFocused = focusedItem == .track(track.ratingKey ?? "")

        return Button {
            MusicQueue.shared.playAlbum(tracks: tracks, startingAt: number - 1)
        } label: {
            HStack(spacing: 16) {
                // Track number or playing indicator
                if isCurrent {
                    PlaybackIndicator(
                        isPlaying: MusicQueue.shared.playbackState == .playing,
                        size: .small
                    )
                    .frame(width: 28)
                } else {
                    Text("\(number)")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 28)
                }

                // Track info
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title ?? "Unknown")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(isCurrent ? 1.0 : 0.9))
                        .lineLimit(1)

                    Text(track.grandparentTitle ?? track.parentTitle ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                // Duration
                if let duration = track.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(
                GlassRowBackground(isFocused: isFocused, cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .focused($focusedItem, equals: .track(track.ratingKey ?? ""))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    // MARK: - Artwork

    private var playlistArtView: some View {
        Group {
            if let url = playlistArtURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        compositeArtPlaceholder
                    }
                }
            } else if tracks.count >= 4 {
                // Composite artwork from first 4 tracks
                compositeArt
            } else {
                compositeArtPlaceholder
            }
        }
    }

    private var compositeArt: some View {
        let artTracks = Array(tracks.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(artTracks, id: \.ratingKey) { track in
                if let url = artURL(for: track) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Rectangle().fill(Color(white: 0.15))
                        }
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                } else {
                    Rectangle().fill(Color(white: 0.15))
                        .aspectRatio(1, contentMode: .fill)
                }
            }
        }
    }

    private var compositeArtPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.12))
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    // MARK: - Helpers

    private var playlistArtURL: URL? {
        guard let thumb = playlist.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private func artURL(for track: PlexMetadata) -> URL? {
        guard let thumb = track.thumb ?? track.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var totalDuration: String {
        let totalMs = tracks.compactMap(\.duration).reduce(0, +)
        let totalMinutes = totalMs / 1000 / 60
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(totalMinutes) min"
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = playlist.ratingKey else {
            error = "Unable to load playlist"
            isLoading = false
            return
        }

        do {
            tracks = try await PlexNetworkManager.shared.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            isLoading = false

            if focusedItem == nil {
                focusedItem = .play
            }
        } catch {
            self.error = "Failed to load tracks"
            isLoading = false
        }
    }
}
