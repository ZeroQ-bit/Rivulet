//
//  MusicAlbumDetailView.swift
//  Rivulet
//
//  Album detail page matching Apple Music tvOS design.
//  Large artwork left, metadata + plain track list right.
//

import SwiftUI

/// Album detail with artwork, metadata, action buttons, and plain track list.
/// Pushed via NavigationStack — no fullScreenCover.
struct MusicAlbumDetailView: View {
    let album: PlexMetadata

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

    @FocusState private var focusedElement: AlbumFocusElement?

    private enum AlbumFocusElement: Hashable {
        case play
        case shuffle
        case more
        case track(String)
    }

    private let networkManager = PlexNetworkManager.shared

    // MARK: - Computed Properties

    private var artworkURL: URL? {
        guard let thumb = album.thumb ?? album.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var artistName: String {
        album.parentTitle ?? album.grandparentTitle ?? "Unknown Artist"
    }

    private var genreText: String? {
        guard let genres = album.Genre, !genres.isEmpty else { return nil }
        return genres.compactMap(\.tag).joined(separator: ", ")
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let genre = genreText { parts.append(genre) }
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var totalDuration: String {
        let totalMs = tracks.compactMap(\.duration).reduce(0, +)
        let totalSeconds = totalMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    private func isCurrentTrack(_ track: PlexMetadata) -> Bool {
        guard let currentKey = musicQueue.currentTrack?.ratingKey,
              let trackKey = track.ratingKey else { return false }
        return currentKey == trackKey
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Subtle blurred artwork backdrop
            backdrop

            // Content
            HStack(alignment: .top, spacing: 50) {
                // Left: Album artwork
                leftColumn
                    .frame(width: 340)

                // Right: Track list
                rightColumn
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
        }
        .onAppear {
            focusedElement = .play
        }
        .task {
            await loadTracks()
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        GeometryReader { geo in
            CachedAsyncImage(url: artworkURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 60)
                        .opacity(0.15)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Large album art
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Album title
            Text(album.title ?? "Unknown Album")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            // Artist name
            Text(artistName)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))

            // Genre + Year
            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Action buttons
            actionRow

            // Summary stats
            if !tracks.isEmpty {
                Text("\(tracks.count) tracks, \(totalDuration)")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 12) {
            // Play
            Button {
                musicQueue.playAlbum(tracks: tracks, startingAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 100, height: 44)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .play,
                isPrimary: true
            ))
            .focused($focusedElement, equals: .play)
            .disabled(tracks.isEmpty)

            // Shuffle
            Button {
                var shuffled = tracks
                shuffled.shuffle()
                musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 110, height: 44)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .shuffle,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .shuffle)
            .disabled(tracks.isEmpty)

            // More (...) button with native context menu
            Button {
                // No-op: context menu is triggered by the system
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .more,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .more)
            .contextMenu {
                Button {
                    musicQueue.playAlbum(tracks: tracks, startingAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    musicQueue.playAlbum(tracks: shuffled, startingAt: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }

                Divider()

                Button {
                    musicQueue.addToEnd(tracks: tracks)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }

                if let firstTrack = tracks.first {
                    Button {
                        for track in tracks.reversed() {
                            musicQueue.addNext(track: track)
                        }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }
        }
    }

    // MARK: - Right Column (Track List)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if tracks.isEmpty {
                VStack {
                    Spacer()
                    Text("No tracks found")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                            let isCurrent = isCurrentTrack(track)
                            let isPlaying = isCurrent && musicQueue.playbackState == .playing

                            Button {
                                musicQueue.playAlbum(tracks: tracks, startingAt: index)
                            } label: {
                                HStack(spacing: 14) {
                                    // Track number or playback indicator
                                    if isCurrent {
                                        PlaybackIndicator(isPlaying: isPlaying, size: .small)
                                            .frame(width: 28, alignment: .center)
                                    } else {
                                        Text("\(track.index ?? (index + 1))")
                                            .font(.system(size: 20).monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.4))
                                            .frame(width: 28, alignment: .center)
                                    }

                                    // Track title
                                    Text(track.title ?? "Track \(index + 1)")
                                        .font(.system(size: 22, weight: isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.9))
                                        .lineLimit(1)

                                    Spacer()

                                    // Duration
                                    if let duration = track.duration {
                                        Text(formatDuration(duration))
                                            .font(.system(size: 18).monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            .focused($focusedElement, equals: .track(track.ratingKey ?? ""))
                            .contextMenu {
                                Button {
                                    musicQueue.addNext(track: track)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }

                                Button {
                                    musicQueue.addToEnd(track: track)
                                } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                            }

                            // Separator
                            if index < tracks.count - 1 {
                                Divider()
                                    .background(.white.opacity(0.06))
                                    .padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.bottom, musicQueue.isActive ? 120 : 40)
                }
                .focusSection()
            }
        }
    }

    // MARK: - Data Loading

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
            isLoading = false
        } catch {
            print("MusicAlbumDetailView: Failed to load tracks: \(error.localizedDescription)")
            isLoading = false
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
