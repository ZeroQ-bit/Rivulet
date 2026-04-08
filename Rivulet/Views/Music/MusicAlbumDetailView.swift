//
//  MusicAlbumDetailView.swift
//  Rivulet
//
//  Album detail tuned to the Apple Music tvOS layout.
//

import SwiftUI

struct MusicAlbumDetailView: View {
    let album: PlexMetadata

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

    @FocusState private var initialFocus: AlbumDetailFocus?

    private enum AlbumDetailFocus: Hashable {
        case play
    }

    private let networkManager = PlexNetworkManager.shared

    private var artworkURL: URL? {
        guard let thumb = album.thumb ?? album.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var artistName: String {
        album.parentTitle ?? album.grandparentTitle ?? "Unknown Artist"
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let genres = album.Genre, let first = genres.first?.tag {
            parts.append(first)
        }
        if let year = album.year {
            parts.append(String(year))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            backgroundView

            HStack(alignment: .top, spacing: 72) {
                artwork
                rightColumn
            }
            .padding(.leading, 80)
            .padding(.trailing, 80)
            .padding(.top, 100)
            .padding(.bottom, 60)
        }
        .task {
            await loadTracks()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                initialFocus = .play
            }
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.21, blue: 0.25),
                Color(red: 0.1, green: 0.11, blue: 0.14),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.12)
        }
        .ignoresSafeArea()
    }

    // MARK: - Artwork

    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 96, weight: .regular))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 660, maxHeight: 660)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 18)
    }

    // MARK: - Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(album.title ?? "Unknown Album")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text(artistName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 10)
                .lineLimit(1)

            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 6)
                    .lineLimit(1)
            }

            actionRow
                .padding(.top, 32)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
            } else {
                trackList
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                if !tracks.isEmpty {
                    musicQueue.playAlbum(tracks: tracks, startingAt: 0)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.18))
            .disabled(tracks.isEmpty)
            .focused($initialFocus, equals: .play)

            Button {
                guard !tracks.isEmpty else { return }
                var shuffled = tracks
                shuffled.shuffle()
                musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.14))
            .disabled(tracks.isEmpty)

            Spacer(minLength: 16)

            Button { } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(Color.white.opacity(0.18))
            .contextMenu {
                Button {
                    if !tracks.isEmpty {
                        musicQueue.playAlbum(tracks: tracks, startingAt: 0)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button {
                    guard !tracks.isEmpty else { return }
                    var shuffled = tracks
                    shuffled.shuffle()
                    musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }

                Divider()

                Button {
                    for track in tracks.reversed() {
                        musicQueue.addNext(track: track)
                    }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    musicQueue.addToEnd(tracks: tracks)
                } label: {
                    Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
    }

    // MARK: - Track list

    private var trackList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    MusicAlbumTrackRow(
                        track: track,
                        displayNumber: track.index ?? (index + 1),
                        isCurrent: musicQueue.currentTrack?.ratingKey == track.ratingKey,
                        isFavorite: (track.userRating ?? 0) > 0,
                        durationText: track.duration.map(formatDuration),
                        onSelect: { musicQueue.playAlbum(tracks: tracks, startingAt: index) },
                        onPlayNext: { musicQueue.addNext(track: track) },
                        onPlayAfter: { musicQueue.addToEnd(track: track) }
                    )
                }
            }
            .padding(.bottom, 60)
        }
    }

    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = album.ratingKey else {
            isLoading = false
            return
        }

        do {
            tracks = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
        } catch {
            print("MusicAlbumDetail: Failed to load tracks: \(error)")
        }

        isLoading = false
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

// MARK: - MusicAlbumTrackRow

/// Track row for the album detail view.
/// - Star (favorite) is rendered as an overlay so it doesn't push the track number column.
/// - Custom focus tint avoids the oversized native white focus highlight; we drive it from
///   `@FocusState` and apply a subtle white background only when the row is focused.
private struct MusicAlbumTrackRow: View {
    let track: PlexMetadata
    let displayNumber: Int
    let isCurrent: Bool
    let isFavorite: Bool
    let durationText: String?
    let onSelect: () -> Void
    let onPlayNext: () -> Void
    let onPlayAfter: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 18) {
                // Now-playing dot OR track number — fixed slot, never shifts.
                // Star (favorite) is overlaid to the left of this slot so it never
                // pushes the number/title columns.
                Group {
                    if isCurrent {
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                    } else {
                        Text("\(displayNumber)")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 36, alignment: .trailing)
                .overlay(alignment: .leading) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .offset(x: -22)
                    }
                }

                Text(track.title ?? "Unknown")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 16)

                if let durationText {
                    Text(durationText)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.10 : 0))
            }
        }
        .buttonStyle(CardButtonStyle())
        .hoverEffectDisabled()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .contextMenu {
            Button(action: onPlayNext) {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button(action: onPlayAfter) {
                Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
    }
}
