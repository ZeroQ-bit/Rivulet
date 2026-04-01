//
//  MusicHomeView.swift
//  Rivulet
//
//  Shelf-based home view for a Plex music library
//

import SwiftUI

/// Music library home with horizontal shelves for recently added, recently played, etc.
/// Replaces PlexLibraryView for music-type libraries.
struct MusicHomeView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var dataStore = PlexDataStore.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var hubs: [PlexHub] = []
    @State private var isLoading = false
    @State private var error: String?

    // Navigation
    @State private var selectedArtist: PlexMetadata?
    @State private var selectedAlbum: PlexMetadata?
    @State private var showArtistDetail = false
    @State private var showAlbumDetail = false

    private let networkManager = PlexNetworkManager.shared

    var body: some View {
        ZStack {
            if isLoading && hubs.isEmpty {
                loadingView
            } else if let error, hubs.isEmpty {
                errorView(error)
            } else {
                shelvesView
            }
        }
        .task {
            await loadHubs()
        }
        .fullScreenCover(isPresented: $showArtistDetail) {
            if let artist = selectedArtist {
                MusicArtistDetailView(artist: artist, isPresented: $showArtistDetail)
                    .presentationBackground(.clear)
            }
        }
        .fullScreenCover(isPresented: $showAlbumDetail) {
            if let album = selectedAlbum {
                MusicAlbumDetailView(album: album, isPresented: $showAlbumDetail)
                    .presentationBackground(.clear)
            }
        }
    }

    // MARK: - Shelves

    private var shelvesView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                // Library title
                Text(libraryTitle)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 50)
                    .padding(.top, 20)

                // Render each hub as a shelf
                ForEach(hubs) { hub in
                    if let items = hub.Metadata, !items.isEmpty {
                        MusicShelfRow(
                            title: hub.title ?? "Music",
                            items: items,
                            onSelect: { item in
                                handleItemSelected(item)
                            }
                        )
                    }
                }
            }
            .padding(.bottom, musicQueue.isActive ? 120 : 40)
        }
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading \(libraryTitle)...")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.4))
            Text(message)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadHubs() }
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .padding(40)
    }

    // MARK: - Navigation

    private func handleItemSelected(_ item: PlexMetadata) {
        switch item.type {
        case "artist":
            selectedArtist = item
            showArtistDetail = true
        case "album":
            selectedAlbum = item
            showAlbumDetail = true
        case "track":
            // Play track immediately
            musicQueue.playNow(track: item)
        default:
            // Treat unknown types as albums if they have children
            selectedAlbum = item
            showAlbumDetail = true
        }
    }

    // MARK: - Data Loading

    private func loadHubs() async {
        // Try cached hubs first
        if let cached = dataStore.libraryHubs[libraryKey], !cached.isEmpty {
            hubs = cached
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            error = "Not connected to a server"
            return
        }

        isLoading = true
        error = nil

        do {
            let loadedHubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey
            )
            hubs = loadedHubs
            isLoading = false
        } catch {
            self.error = "Failed to load library: \(error.localizedDescription)"
            isLoading = false
        }
    }
}
