//
//  MusicArtistDetailView.swift
//  Rivulet
//
//  Artist detail page tuned to the Apple Music tvOS hierarchy.
//

import SwiftUI

struct MusicArtistDetailView: View {
    let artist: PlexMetadata
    let libraryKey: String

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var albums: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var isPlayingAll = false
    @State private var isShuffling = false
    @State private var selectedAlbum: PlexMetadata?

    private let networkManager = PlexNetworkManager.shared
    private let gridColumns = Array(repeating: GridItem(.fixed(188), spacing: 28, alignment: .top), count: 4)

    private var artistPhotoURL: URL? {
        guard let thumb = artist.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var sortedAlbums: [PlexMetadata] {
        albums.sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    var body: some View {
        ZStack {
            backgroundView

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    headerSection
                    actionRow

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if sortedAlbums.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 34) {
                            ForEach(sortedAlbums, id: \.ratingKey) { album in
                                MusicPosterCard(item: album, style: .square) {
                                    selectedAlbum = album
                                }
                                .musicItemContextMenu(item: album, style: .album)
                            }
                        }
                    }

                    if let summary = artist.summary, !summary.isEmpty {
                        aboutSection(summary)
                    }
                }
                .padding(.horizontal, 72)
                .padding(.top, 56)
                .padding(.bottom, 64)
            }
        }
        .navigationDestination(item: $selectedAlbum) { album in
            MusicAlbumDetailView(album: album)
        }
        .task {
            await loadAlbums()
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.2, blue: 0.24),
                Color(red: 0.1, green: 0.11, blue: 0.14),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.14)
        }
        .ignoresSafeArea()
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 24) {
            artistPortrait

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.title ?? "Unknown Artist")
                    .font(.system(size: 31, weight: .bold))
                    .lineLimit(2)

                if !albums.isEmpty {
                    Text("\(albums.count) albums")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 32)
        }
    }

    private var artistPortrait: some View {
        CachedAsyncImage(url: artistPhotoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                Circle()
                    .fill(.regularMaterial)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(Circle())
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await playAll(shuffled: false) }
            } label: {
                Label(isPlayingAll ? "Loading" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.18))
            .disabled(isPlayingAll || isShuffling)

            Button {
                Task { await playAll(shuffled: true) }
            } label: {
                Label(isShuffling ? "Loading" : "Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.white.opacity(0.14))
            .disabled(isPlayingAll || isShuffling)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("No albums found")
                .font(.system(size: 20, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func aboutSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.system(size: 21, weight: .semibold))

            Text(summary)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
        .padding(.top, 6)
    }

    private func loadAlbums() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = artist.ratingKey else {
            isLoading = false
            return
        }

        do {
            albums = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
        } catch {
            print("MusicArtistDetailView: Failed to load albums: \(error.localizedDescription)")
        }

        isLoading = false
    }

    private func playAll(shuffled: Bool) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = artist.ratingKey else { return }

        if shuffled {
            isShuffling = true
        } else {
            isPlayingAll = true
        }

        defer {
            isPlayingAll = false
            isShuffling = false
        }

        do {
            var allTracks = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            if shuffled { allTracks.shuffle() }
            if !allTracks.isEmpty {
                musicQueue.playAlbum(tracks: allTracks, startingAt: 0)
            }
        } catch {
            print("MusicArtistDetailView: Failed to load tracks: \(error.localizedDescription)")
        }
    }
}
