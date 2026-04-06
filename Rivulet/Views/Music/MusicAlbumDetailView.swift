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

            HStack(alignment: .top, spacing: 48) {
                artwork
                    .padding(.top, 72)

                rightColumn
                    .padding(.top, 72)
            }
            .padding(.horizontal, 72)
            .padding(.bottom, 42)
        }
        .task {
            await loadTracks()
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

    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(album.title ?? "Unknown Album")
                .font(.system(size: 31, weight: .bold))
                .lineLimit(2)

            Text(artistName)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.82))
                .padding(.top, 4)

            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            actionRow
                .padding(.top, 22)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                trackList
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                if !tracks.isEmpty {
                    musicQueue.playAlbum(tracks: tracks, startingAt: 0)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.18))
            .disabled(tracks.isEmpty)

            Button {
                guard !tracks.isEmpty else { return }
                var shuffled = tracks
                shuffled.shuffle()
                musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.14))
            .disabled(tracks.isEmpty)

            Button { } label: {
                Image(systemName: "ellipsis")
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

    private var trackList: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                trackRow(track: track, index: index)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackRow(track: PlexMetadata, index: Int) -> some View {
        let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey

        return Button {
            musicQueue.playAlbum(tracks: tracks, startingAt: index)
        } label: {
            HStack(spacing: 16) {
                if isCurrent {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .frame(width: 20, alignment: .leading)
                } else {
                    Text("\(track.index ?? (index + 1))")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }

                Text(track.title ?? "Track \(index + 1)")
                    .font(.system(size: 19, weight: .regular))
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let duration = track.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                musicQueue.addNext(track: track)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                musicQueue.addToEnd(track: track)
            } label: {
                Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
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
