//
//  MusicAlbumDetailView.swift
//  Rivulet
//
//  Dedicated album detail page with artwork, track list, and playback actions
//

import SwiftUI

/// Full-screen album detail with large artwork, track listing, and action buttons.
struct MusicAlbumDetailView: View {
    let album: PlexMetadata
    @Binding var isPresented: Bool

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

    @FocusState private var focusedElement: AlbumFocusElement?

    private enum AlbumFocusElement: Hashable {
        case play
        case shuffle
        case addToQueue
        case track(String) // ratingKey
    }

    private let networkManager = PlexNetworkManager.shared

    /// Album art URL
    private var artworkURL: URL? {
        guard let thumb = album.thumb ?? album.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Artist name from various metadata fields
    private var artistName: String {
        album.parentTitle ?? album.grandparentTitle ?? "Unknown Artist"
    }

    /// Genre string
    private var genreText: String? {
        guard let genres = album.Genre, !genres.isEmpty else { return nil }
        return genres.compactMap(\.tag).joined(separator: ", ")
    }

    /// Total duration of all tracks
    private var totalDuration: Int {
        tracks.compactMap(\.duration).reduce(0, +)
    }

    /// Formatted total duration
    private var formattedTotalDuration: String {
        let totalSeconds = totalDuration / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }

    /// Check if a track is currently playing
    private func isCurrentTrack(_ track: PlexMetadata) -> Bool {
        guard let currentKey = musicQueue.currentTrack?.ratingKey,
              let trackKey = track.ratingKey else { return false }
        return currentKey == trackKey
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()

            // Subtle blurred artwork backdrop
            backdrop

            // Content
            HStack(alignment: .top, spacing: 60) {
                // Left: Album art + metadata
                leftColumn
                    .frame(width: 400)

                // Right: Track list
                rightColumn
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
        }
        .onAppear {
            focusedElement = .play
        }
        .onExitCommand {
            isPresented = false
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
                        .opacity(0.2)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Large album art
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                case .failure:
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                }
            }
            .frame(width: 350, height: 350)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )

            // Album title
            Text(album.title ?? "Unknown Album")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            // Artist name
            Text(artistName)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))

            // Year + Genre
            HStack(spacing: 12) {
                if let year = album.year {
                    Text(String(year))
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let genre = genreText {
                    if album.year != nil {
                        Text("*")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Text(genre)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            // Action buttons
            actionRow

            // Summary stats
            if !tracks.isEmpty {
                Text("\(tracks.count) tracks, \(formattedTotalDuration)")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 16) {
            // Play
            Button {
                musicQueue.playAlbum(tracks: tracks, startingAt: 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 120, height: 48)
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
                HStack(spacing: 8) {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 140, height: 48)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .shuffle,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .shuffle)
            .disabled(tracks.isEmpty)

            // Add to Queue
            Button {
                musicQueue.addToEnd(tracks: tracks)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                    Text("Queue")
                }
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 130, height: 48)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .addToQueue,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .addToQueue)
            .disabled(tracks.isEmpty)
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
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                            TrackRow(
                                track: track,
                                index: index,
                                isCurrent: isCurrentTrack(track),
                                isPlaying: isCurrentTrack(track) && musicQueue.playbackState == .playing,
                                isFocused: focusedElement == .track(track.ratingKey ?? "")
                            ) {
                                musicQueue.playAlbum(tracks: tracks, startingAt: index)
                            }
                            .focused($focusedElement, equals: .track(track.ratingKey ?? ""))
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
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            isLoading = false
        } catch {
            print("MusicAlbumDetailView: Failed to load tracks: \(error.localizedDescription)")
            isLoading = false
        }
    }
}

// MARK: - Track Row

/// A single track row in the album track list.
private struct TrackRow: View {
    let track: PlexMetadata
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let isFocused: Bool
    let action: () -> Void

    /// Format duration from milliseconds to m:ss
    private var formattedDuration: String {
        guard let durationMs = track.duration else { return "" }
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Track number or playback indicator
                ZStack {
                    if isCurrent {
                        PlaybackIndicator(isPlaying: isPlaying, size: .small)
                    } else {
                        Text("\(track.index ?? (index + 1))")
                            .font(.system(size: 20).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 30, alignment: .center)

                // Track title
                Text(track.title ?? "Track \(index + 1)")
                    .font(.system(size: 22, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.9))
                    .lineLimit(1)

                Spacer()

                // Duration
                Text(formattedDuration)
                    .font(.system(size: 20).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : (isCurrent ? .white.opacity(0.06) : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(GlassRowButtonStyle())
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
