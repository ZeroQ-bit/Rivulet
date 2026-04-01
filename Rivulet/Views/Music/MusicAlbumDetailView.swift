//
//  MusicAlbumDetailView.swift
//  Rivulet
//
//  Album detail matching Apple Music tvOS: artwork left, metadata + tracks right.
//

import SwiftUI

struct MusicAlbumDetailView: View {
    let album: PlexMetadata

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

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
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            // Left: Album artwork only
            artwork
                .padding(.leading, 70)

            // Right: Metadata + buttons + track list
            rightColumn
        }
        .padding(.top, 60)
        .task {
            await loadTracks()
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 50))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Right Column

    private var rightColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Album title
                Text(album.title ?? "Unknown Album")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                // Artist
                Text(artistName)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)

                // Genre · Year
                if !metadataLine.isEmpty {
                    Text(metadataLine)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                // Action buttons
                actionRow
                    .padding(.top, 22)

                // Track list
                trackList
                    .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 60)
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button {
                musicQueue.playAlbum(tracks: tracks, startingAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .disabled(tracks.isEmpty)

            Button {
                var shuffled = tracks; shuffled.shuffle()
                musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
            }
            .disabled(tracks.isEmpty)

            Button { } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
            }
            .contextMenu {
                Button { musicQueue.playAlbum(tracks: tracks, startingAt: 0) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    var s = tracks; s.shuffle()
                    musicQueue.playAlbum(tracks: s, startingAt: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                Divider()
                Button {
                    for t in tracks.reversed() { musicQueue.addNext(track: t) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { musicQueue.addToEnd(tracks: tracks) } label: {
                    Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
    }

    // MARK: - Track List

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                    let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey

                    Button {
                        musicQueue.playAlbum(tracks: tracks, startingAt: index)
                    } label: {
                        HStack(spacing: 14) {
                            // Currently playing dot or track number
                            if isCurrent {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 7, height: 7)
                                    .frame(width: 24)
                            } else {
                                Text("\(track.index ?? (index + 1))")
                                    .font(.system(size: 17).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }

                            Text(track.title ?? "Track \(index + 1)")
                                .font(.system(size: 19, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Spacer()

                            if let duration = track.duration {
                                Text(formatDuration(duration))
                                    .font(.system(size: 17).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { musicQueue.addNext(track: track) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { musicQueue.addToEnd(track: track) } label: {
                            Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    }

                    if index < tracks.count - 1 {
                        Divider()
                            .background(.white.opacity(0.08))
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = album.ratingKey else {
            isLoading = false
            return
        }
        do {
            tracks = try await networkManager.getChildren(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
        } catch {
            print("MusicAlbumDetail: Failed to load tracks: \(error)")
        }
        isLoading = false
    }

    private func formatDuration(_ ms: Int) -> String {
        let s = ms / 1000
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
