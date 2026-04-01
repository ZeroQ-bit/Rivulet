//
//  MusicArtistDetailView.swift
//  Rivulet
//
//  Artist detail page showing discography as a grid.
//  Pushed via NavigationStack from the Artists grid.
//

import SwiftUI

/// Artist detail with header, Play All/Shuffle, and album grid.
/// Pushed via NavigationStack — no fullScreenCover.
struct MusicArtistDetailView: View {
    let artist: PlexMetadata
    let libraryKey: String

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var albums: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var isPlayingAll = false
    @State private var isShuffling = false

    // Navigation
    @State private var selectedAlbum: PlexMetadata?

    @FocusState private var focusedElement: ArtistFocusElement?

    private enum ArtistFocusElement: Hashable {
        case playAll
        case shuffle
        case album(String)
    }

    private let networkManager = PlexNetworkManager.shared

    // MARK: - Computed Properties

    private var artistPhotoURL: URL? {
        guard let thumb = artist.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var sortedAlbums: [PlexMetadata] {
        albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)
    ]

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection
                    .padding(.horizontal, 80)

                // Action buttons
                actionRow
                    .padding(.horizontal, 80)

                // Discography grid
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .padding(.vertical, 60)
                } else if albums.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No albums found")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    albumGrid
                }

                // About section
                if let summary = artist.summary, !summary.isEmpty {
                    aboutSection(summary)
                        .padding(.horizontal, 80)
                }

                Spacer()
                    .frame(height: musicQueue.isActive ? 120 : 60)
            }
            .padding(.top, 40)
        }
        .navigationDestination(item: $selectedAlbum) { album in
            MusicAlbumDetailView(album: album)
        }
        .task {
            await loadAlbums()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 24) {
            // Artist photo (circular)
            CachedAsyncImage(url: artistPhotoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    Circle()
                        .fill(.white.opacity(0.06))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(artist.title ?? "Unknown Artist")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if !albums.isEmpty {
                    Text("\(albums.count) albums")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 14) {
            // Play All
            Button {
                Task { await playAll(shuffled: false) }
            } label: {
                HStack(spacing: 8) {
                    if isPlayingAll {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play All")
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 130, height: 44)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .playAll,
                isPrimary: true
            ))
            .focused($focusedElement, equals: .playAll)
            .disabled(isPlayingAll || isShuffling)

            // Shuffle
            Button {
                Task { await playAll(shuffled: true) }
            } label: {
                HStack(spacing: 8) {
                    if isShuffling {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "shuffle")
                    }
                    Text("Shuffle")
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 120, height: 44)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .shuffle,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .shuffle)
            .disabled(isPlayingAll || isShuffling)
        }
    }

    // MARK: - Album Grid

    private var albumGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 30) {
            ForEach(sortedAlbums, id: \.ratingKey) { album in
                MusicPosterCard(item: album, style: .square) {
                    selectedAlbum = album
                }
                .focused($focusedElement, equals: .album(album.ratingKey ?? ""))
                .musicItemContextMenu(item: album, style: .album)
            }
        }
        .padding(.horizontal, 80)
        .focusSection()
    }

    // MARK: - About

    private func aboutSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Text(summary)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(6)
        }
    }

    // MARK: - Data Loading

    private func loadAlbums() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = artist.ratingKey else {
            isLoading = false
            return
        }

        do {
            albums = try await networkManager.getChildren(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
            isLoading = false
        } catch {
            print("MusicArtistDetailView: Failed to load albums: \(error.localizedDescription)")
            isLoading = false
        }
    }

    private func playAll(shuffled: Bool) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = artist.ratingKey else { return }

        if shuffled { isShuffling = true } else { isPlayingAll = true }

        do {
            var allTracks = try await networkManager.getAllLeaves(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
            if shuffled { allTracks.shuffle() }
            if !allTracks.isEmpty {
                musicQueue.playAlbum(tracks: allTracks, startingAt: 0)
            }
        } catch {
            print("MusicArtistDetailView: Failed to load tracks: \(error.localizedDescription)")
        }

        isPlayingAll = false
        isShuffling = false
    }
}
