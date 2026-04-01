//
//  MusicArtistDetailView.swift
//  Rivulet
//
//  Dedicated artist detail page with discography and bio
//

import SwiftUI

/// Full-screen artist detail with blurred backdrop, action buttons, and discography.
struct MusicArtistDetailView: View {
    let artist: PlexMetadata
    @Binding var isPresented: Bool

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var albums: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var isPlayingAll = false
    @State private var isShuffling = false
    @State private var showExpandedBio = false

    @FocusState private var focusedElement: ArtistFocusElement?

    private enum ArtistFocusElement: Hashable {
        case playAll
        case shuffle
        case album(String) // ratingKey
    }

    private let networkManager = PlexNetworkManager.shared

    /// Artist photo URL
    private var artistPhotoURL: URL? {
        guard let thumb = artist.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Albums sorted by year (newest first)
    private var sortedAlbums: [PlexMetadata] {
        albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var body: some View {
        ZStack {
            // Blurred backdrop
            backdrop

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    // Spacer for backdrop area
                    Spacer()
                        .frame(height: 300)

                    // Artist name
                    Text(artist.title ?? "Unknown Artist")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 80)

                    // Action row
                    actionRow
                        .padding(.horizontal, 80)

                    // Discography
                    if !albums.isEmpty {
                        discographySection
                    } else if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(1.2)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    }

                    // About section
                    if let summary = artist.summary, !summary.isEmpty {
                        aboutSection(summary)
                            .padding(.horizontal, 80)
                    }

                    Spacer()
                        .frame(height: musicQueue.isActive ? 120 : 60)
                }
            }
        }
        .background(Color.black)
        .onAppear {
            focusedElement = .playAll
        }
        .onExitCommand {
            isPresented = false
        }
        .task {
            await loadAlbums()
        }
        .fullScreenCover(isPresented: $showAlbumDetail) {
            if let album = selectedAlbum {
                MusicAlbumDetailView(album: album, isPresented: $showAlbumDetail)
                    .presentationBackground(.clear)
            }
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        GeometryReader { geo in
            CachedAsyncImage(url: artistPhotoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 30)
                        .overlay(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.7), .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(0.6)
                default:
                    Color.black
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 20) {
            // Play All
            Button {
                Task { await playAll(shuffled: false) }
            } label: {
                HStack(spacing: 10) {
                    if isPlayingAll {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text("Play All")
                }
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 180, height: 56)
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
                HStack(spacing: 10) {
                    if isShuffling {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "shuffle")
                    }
                    Text("Shuffle")
                }
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 180, height: 56)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedElement == .shuffle,
                isPrimary: false
            ))
            .focused($focusedElement, equals: .shuffle)
            .disabled(isPlayingAll || isShuffling)
        }
    }

    // MARK: - Discography

    private var discographySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discography")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(sortedAlbums, id: \.ratingKey) { album in
                        MusicPosterCard(item: album) {
                            navigateToAlbum(album)
                        }
                        .focused($focusedElement, equals: .album(album.ratingKey ?? ""))
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 8)
            }
            .focusSection()
        }
    }

    // MARK: - About

    private func aboutSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Text(summary)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(showExpandedBio ? nil : 4)
                .animation(.easeInOut(duration: 0.3), value: showExpandedBio)

            if summary.count > 200 {
                Button(showExpandedBio ? "Show Less" : "Read More") {
                    showExpandedBio.toggle()
                }
                .buttonStyle(AppStoreButtonStyle())
            }
        }
    }

    // MARK: - Navigation

    @State private var selectedAlbum: PlexMetadata?
    @State private var showAlbumDetail = false

    private func navigateToAlbum(_ album: PlexMetadata) {
        selectedAlbum = album
        showAlbumDetail = true
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
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
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

        if shuffled {
            isShuffling = true
        } else {
            isPlayingAll = true
        }

        do {
            var allTracks = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            if shuffled {
                allTracks.shuffle()
            }

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
