//
//  MusicHomeView.swift
//  Rivulet
//
//  Music library home matching Apple Music tvOS Library tab.
//  Left sidebar for categories, right content area with album/artist grids.
//  Uses the same MediaPosterCard and grid patterns as PlexLibraryView.
//

import SwiftUI

/// Category shown in the left sidebar of the music library
enum MusicLibraryCategory: String, Hashable, CaseIterable {
    case recentlyAdded
    case playlists
    case artists
    case albums
    case songs

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        }
    }
}

struct MusicHomeView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(\.uiScale) private var scale

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var dataStore = PlexDataStore.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    // Data
    @State private var recentlyAddedItems: [PlexMetadata] = []
    @State private var allArtists: [PlexMetadata] = []
    @State private var allAlbums: [PlexMetadata] = []
    @State private var allTracks: [PlexMetadata] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var loadedCategories: Set<MusicLibraryCategory> = []

    // Navigation
    @State private var selectedCategory: MusicLibraryCategory = .recentlyAdded
    @State private var selectedItem: PlexMetadata?

    private let networkManager = PlexNetworkManager.shared

    // Grid columns — same as PlexLibraryView
    private var columns: [GridItem] {
        let minWidth = ScaledDimensions.gridMinWidth * scale
        let maxWidth = ScaledDimensions.gridMaxWidth * scale
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: ScaledDimensions.gridSpacing)]
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                sidebar
                contentArea
            }
            .navigationDestination(item: $selectedItem) { item in
                if item.type == "artist" {
                    MusicArtistDetailView(artist: item, libraryKey: libraryKey)
                } else if item.type == "playlist" {
                    MusicPlaylistView(playlist: item)
                } else {
                    MusicAlbumDetailView(album: item)
                }
            }
        }
        .onChange(of: selectedItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
        .task {
            await loadRecentlyAdded()
            await loadGenres()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                // Categories
                ForEach(MusicLibraryCategory.allCases, id: \.self) { category in
                    Button {
                        selectedCategory = category
                        Task { await loadCategoryData(category) }
                    } label: {
                        Label(category.title, systemImage: category.icon)
                            .font(.system(size: 29))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Genres section
                if !genres.isEmpty {
                    Text("Genres")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 28)
                        .padding(.bottom, 4)

                    ForEach(genres, id: \.self) { genre in
                        Button {
                            // Genre filtering — future feature
                        } label: {
                            Text(genre)
                                .font(.system(size: 29))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(40)
        }
        .frame(width: 340)
        .focusSection()
    }

    // MARK: - Content Area

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — only for categories with counts
            if selectedCategory != .recentlyAdded {
                contentHeader
                    .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                    .padding(.top, 40)
                    .padding(.bottom, 20)
            }

            // Grid content
            switch selectedCategory {
            case .recentlyAdded: albumGrid(items: recentlyAddedItems)
            case .playlists:     albumGrid(items: playlists)
            case .artists:       artistGrid
            case .albums:        albumGrid(items: allAlbums)
            case .songs:         songsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCategory.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text(contentCountText)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            if selectedCategory == .albums || selectedCategory == .artists || selectedCategory == .songs {
                HStack(spacing: 12) {
                    Button {
                        Task { await playAll(shuffled: false) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.15))

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.15))
                }
            }
        }
    }

    // MARK: - Album / Recently Added Grid

    private func albumGrid(items: [PlexMetadata]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if items.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if items.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { _, item in
                        Button {
                            selectedItem = item
                        } label: {
                            EquatableView(content: MediaPosterCard(
                                item: item,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? ""
                            ))
                        }
                        .buttonStyle(CardButtonStyle())
                        .contextMenu {
                            Button { musicQueue.playNow(track: item) } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            Button {
                                Task {
                                    guard let serverURL = authManager.selectedServerURL,
                                          let token = authManager.selectedServerToken,
                                          let ratingKey = item.ratingKey else { return }
                                    let tracks = try? await networkManager.getChildren(
                                        serverURL: serverURL, authToken: token, ratingKey: ratingKey
                                    )
                                    if let tracks, !tracks.isEmpty {
                                        var shuffled = tracks; shuffled.shuffle()
                                        musicQueue.playAlbum(tracks: shuffled)
                                    }
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            Button {
                                Task {
                                    guard let serverURL = authManager.selectedServerURL,
                                          let token = authManager.selectedServerToken,
                                          let ratingKey = item.ratingKey else { return }
                                    let tracks = try? await networkManager.getChildren(
                                        serverURL: serverURL, authToken: token, ratingKey: ratingKey
                                    )
                                    if let tracks { musicQueue.addToEnd(tracks: tracks) }
                                }
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                        }
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
        }
    }

    // MARK: - Artist Grid

    private var artistGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if allArtists.isEmpty && !loadedCategories.contains(.artists) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if allArtists.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(Array(allArtists.enumerated()), id: \.element.ratingKey) { _, artist in
                        Button {
                            selectedItem = artist
                        } label: {
                            VStack(spacing: 10) {
                                // Circular artist photo
                                artistPhoto(for: artist)
                                    .frame(width: ScaledDimensions.squarePosterSize * scale,
                                           height: ScaledDimensions.squarePosterSize * scale)
                                    .clipShape(Circle())
                                    .hoverEffect(.highlight)
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 6)

                                Text(artist.title ?? "Unknown")
                                    .font(.system(size: ScaledDimensions.posterTitleSize))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
        }
    }

    private func artistPhoto(for artist: PlexMetadata) -> some View {
        let url = artworkURL(for: artist)
        return CachedAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Circle()
                    .fill(.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            }
        }
    }

    // MARK: - Songs List

    private var songsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if allTracks.isEmpty && !loadedCategories.contains(.songs) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if allTracks.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(allTracks.enumerated()), id: \.element.ratingKey) { index, track in
                        let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey
                        Button {
                            musicQueue.playAlbum(tracks: allTracks, startingAt: index)
                        } label: {
                            HStack(spacing: 14) {
                                if isCurrent {
                                    PlaybackIndicator(isPlaying: musicQueue.playbackState == .playing, size: .small)
                                        .frame(width: 28)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.system(size: 17).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                }

                                Text(track.title ?? "Unknown")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isCurrent ? .white : .primary)
                                    .lineLimit(1)

                                Spacer()

                                Text(track.grandparentTitle ?? "")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                if let duration = track.duration {
                                    Text(formatDuration(duration))
                                        .font(.system(size: 17).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 55, alignment: .trailing)
                                }
                            }
                            .padding(.vertical, 12)
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

                        if index < allTracks.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
        }
    }

    // MARK: - Shared

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text("No items")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var contentCountText: String {
        switch selectedCategory {
        case .recentlyAdded: return ""
        case .playlists: return playlists.isEmpty ? "" : "\(playlists.count) playlists"
        case .artists: return allArtists.isEmpty ? "" : "\(allArtists.count) artists"
        case .albums: return allAlbums.isEmpty ? "" : "\(allAlbums.count) albums"
        case .songs: return allTracks.isEmpty ? "" : "\(allTracks.count) songs"
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private func formatDuration(_ ms: Int) -> String {
        let s = ms / 1000
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    // MARK: - Data Loading

    private func loadRecentlyAdded() async {
        if let cached = dataStore.libraryHubs[libraryKey], !cached.isEmpty {
            recentlyAddedItems = cached.flatMap { $0.Metadata ?? [] }
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoading = true
        do {
            let hubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: libraryKey
            )
            recentlyAddedItems = hubs.flatMap { $0.Metadata ?? [] }
        } catch {
            print("MusicHome: Failed to load hubs: \(error)")
        }
        isLoading = false
    }

    private func loadGenres() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        guard let url = URL(string: "\(serverURL)/library/sections/\(libraryKey)/genre?X-Plex-Token=\(token)") else { return }

        do {
            struct GenreResponse: Codable {
                struct Container: Codable { var Directory: [Entry]? }
                struct Entry: Codable { var title: String? }
                var MediaContainer: Container
            }
            let data = try await networkManager.requestData(url, method: "GET", headers: ["X-Plex-Token": token])
            let response = try JSONDecoder().decode(GenreResponse.self, from: data)
            genres = (response.MediaContainer.Directory ?? []).compactMap(\.title).sorted()
        } catch {
            print("MusicHome: Failed to load genres: \(error)")
        }
    }

    private func loadCategoryData(_ category: MusicLibraryCategory) async {
        guard !loadedCategories.contains(category) else { return }
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        switch category {
        case .recentlyAdded:
            break // Already loaded
        case .playlists:
            playlists = (try? await networkManager.getPlaylists(serverURL: serverURL, authToken: token)) ?? []
        case .artists:
            let items = (try? await networkManager.getLibraryItems(
                serverURL: serverURL, authToken: token, sectionId: libraryKey, start: 0, size: 500
            )) ?? []
            allArtists = items.filter { $0.type == "artist" }
        case .albums:
            let result = (try? await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: token, sectionId: libraryKey, start: 0, size: 500, sort: "-addedAt"
            ))
            let items = result?.items ?? []
            allAlbums = items.filter { $0.type == "album" }
            if allAlbums.isEmpty { allAlbums = items }
        case .songs:
            let items = (try? await networkManager.getLibraryItems(
                serverURL: serverURL, authToken: token, sectionId: libraryKey, start: 0, size: 500
            )) ?? []
            allTracks = items.filter { $0.type == "track" }
        }
        loadedCategories.insert(category)
    }

    private func playAll(shuffled: Bool) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        var tracks: [PlexMetadata]
        if selectedCategory == .songs, !allTracks.isEmpty {
            tracks = allTracks
        } else {
            tracks = (try? await networkManager.getLibraryItems(
                serverURL: serverURL, authToken: token, sectionId: libraryKey, start: 0, size: 1000
            ).filter { $0.type == "track" }) ?? []
        }

        if shuffled { tracks.shuffle() }
        if !tracks.isEmpty { musicQueue.playAlbum(tracks: tracks) }
    }
}
