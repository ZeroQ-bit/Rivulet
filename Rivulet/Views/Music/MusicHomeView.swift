//
//  MusicHomeView.swift
//  Rivulet
//
//  Split-view music library matching Apple Music tvOS Library tab.
//  Left sidebar for categories, right content area with grids/lists.
//

import SwiftUI

/// Category shown in the left sidebar of the music library
enum MusicLibraryCategory: Hashable, CaseIterable {
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

/// Music library home with Apple Music-style split layout.
/// Left sidebar for category selection, right side shows content grid.
struct MusicHomeView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var dataStore = PlexDataStore.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    // Data
    @State private var hubs: [PlexHub] = []
    @State private var allArtists: [PlexMetadata] = []
    @State private var allAlbums: [PlexMetadata] = []
    @State private var allTracks: [PlexMetadata] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedCategories: Set<MusicLibraryCategory> = []

    // Navigation
    @State private var selectedCategory: MusicLibraryCategory = .recentlyAdded
    @State private var selectedAlbum: PlexMetadata?
    @State private var selectedArtist: PlexMetadata?
    @State private var selectedPlaylist: PlexMetadata?

    // Focus
    @FocusState private var focusedCategory: MusicLibraryCategory?
    @FocusState private var focusedGenre: String?
    @FocusState private var focusedContentId: String?

    private let networkManager = PlexNetworkManager.shared

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Left sidebar
                sidebar
                    .frame(width: 340)

                // Right content
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationDestination(item: $selectedAlbum) { album in
                MusicAlbumDetailView(album: album)
            }
            .navigationDestination(item: $selectedArtist) { artist in
                MusicArtistDetailView(artist: artist, libraryKey: libraryKey)
            }
            .navigationDestination(item: $selectedPlaylist) { playlist in
                MusicPlaylistView(playlist: playlist)
            }
        }
        .task {
            await loadInitialData()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                // Library title
                Text(libraryTitle)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)

                // Category list
                ForEach(MusicLibraryCategory.allCases, id: \.self) { category in
                    sidebarButton(category: category)
                }

                // Genres section
                if !genres.isEmpty {
                    Divider()
                        .background(.white.opacity(0.1))
                        .padding(.vertical, 16)

                    Text("Genres")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 8)

                    ForEach(genres, id: \.self) { genre in
                        Button {
                            // Genre filtering could be added as a future feature
                        } label: {
                            Text(genre)
                                .font(.system(size: 22))
                                .foregroundStyle(focusedGenre == genre ? .black : .white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(focusedGenre == genre ? .white : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedGenre, equals: genre)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
        .focusSection()
    }

    private func sidebarButton(category: MusicLibraryCategory) -> some View {
        Button {
            selectedCategory = category
            Task { await loadCategoryData(category) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: category.icon)
                    .font(.system(size: 20))
                    .frame(width: 24)

                Text(category.title)
                    .font(.system(size: 24, weight: selectedCategory == category ? .semibold : .regular))

                Spacer()
            }
            .foregroundStyle(
                focusedCategory == category
                    ? .black
                    : (selectedCategory == category ? .white : .white.opacity(0.7))
            )
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        focusedCategory == category
                            ? .white
                            : (selectedCategory == category ? .white.opacity(0.12) : .clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($focusedCategory, equals: category)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content header
            contentHeader
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 20)

            // Content body
            switch selectedCategory {
            case .recentlyAdded:
                recentlyAddedGrid
            case .playlists:
                playlistsGrid
            case .artists:
                artistsGrid
            case .albums:
                albumsGrid
            case .songs:
                songsList
            }
        }
        .focusSection()
    }

    private var contentHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedCategory.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                Text(contentCountText)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Play All / Shuffle for applicable categories
            if selectedCategory == .albums || selectedCategory == .songs {
                HStack(spacing: 12) {
                    Button {
                        Task { await playAllContent(shuffled: false) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 110, height: 44)
                    }
                    .buttonStyle(AppStoreActionButtonStyle(
                        isFocused: focusedContentId == "_play",
                        isPrimary: true
                    ))
                    .focused($focusedContentId, equals: "_play")

                    Button {
                        Task { await playAllContent(shuffled: true) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                            Text("Shuffle")
                        }
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 120, height: 44)
                    }
                    .buttonStyle(AppStoreActionButtonStyle(
                        isFocused: focusedContentId == "_shuffle",
                        isPrimary: false
                    ))
                    .focused($focusedContentId, equals: "_shuffle")
                }
            }
        }
    }

    private var contentCountText: String {
        switch selectedCategory {
        case .recentlyAdded:
            let count = recentlyAddedItems.count
            return count > 0 ? "\(count) albums" : ""
        case .playlists:
            return playlists.isEmpty ? "" : "\(playlists.count) playlists"
        case .artists:
            return allArtists.isEmpty ? "" : "\(allArtists.count) artists"
        case .albums:
            return allAlbums.isEmpty ? "" : "\(allAlbums.count) albums"
        case .songs:
            return allTracks.isEmpty ? "" : "\(allTracks.count) songs"
        }
    }

    // MARK: - Recently Added

    private var recentlyAddedItems: [PlexMetadata] {
        let hubItems = hubs.flatMap { $0.Metadata ?? [] }
        // Filter to albums only for recently added
        let albums = hubItems.filter { $0.type == "album" }
        return albums.isEmpty ? hubItems : albums
    }

    private var recentlyAddedGrid: some View {
        contentGrid(items: recentlyAddedItems, isLoading: isLoading && hubs.isEmpty)
    }

    // MARK: - Playlists

    private var playlistsGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if playlists.isEmpty && loadedCategories.contains(.playlists) {
                emptyStateView("No playlists found")
            } else if playlists.isEmpty {
                loadingIndicator
            } else {
                LazyVGrid(columns: gridColumns, spacing: 30) {
                    ForEach(playlists, id: \.ratingKey) { playlist in
                        MusicPosterCard(item: playlist, style: .square) {
                            selectedPlaylist = playlist
                        }
                        .focused($focusedContentId, equals: playlist.ratingKey)
                        .musicItemContextMenu(item: playlist, style: .album)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, musicQueue.isActive ? 120 : 40)
            }
        }
    }

    // MARK: - Artists

    private var artistsGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if allArtists.isEmpty && loadedCategories.contains(.artists) {
                emptyStateView("No artists found")
            } else if allArtists.isEmpty {
                loadingIndicator
            } else {
                LazyVGrid(columns: gridColumns, spacing: 30) {
                    ForEach(allArtists, id: \.ratingKey) { artist in
                        MusicPosterCard(item: artist, style: .circular) {
                            selectedArtist = artist
                        }
                        .focused($focusedContentId, equals: artist.ratingKey)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, musicQueue.isActive ? 120 : 40)
            }
        }
    }

    // MARK: - Albums

    private var albumsGrid: some View {
        contentGrid(items: allAlbums, isLoading: allAlbums.isEmpty && !loadedCategories.contains(.albums))
    }

    // MARK: - Songs

    private var songsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if allTracks.isEmpty && loadedCategories.contains(.songs) {
                emptyStateView("No songs found")
            } else if allTracks.isEmpty {
                loadingIndicator
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(allTracks.enumerated()), id: \.element.ratingKey) { index, track in
                        let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey
                        Button {
                            musicQueue.playAlbum(tracks: allTracks, startingAt: index)
                        } label: {
                            HStack(spacing: 16) {
                                // Track number or playback indicator
                                if isCurrent {
                                    PlaybackIndicator(
                                        isPlaying: musicQueue.playbackState == .playing,
                                        size: .small
                                    )
                                    .frame(width: 30)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.system(size: 18).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 30)
                                }

                                // Title
                                Text(track.title ?? "Unknown")
                                    .font(.system(size: 22, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.9))
                                    .lineLimit(1)

                                Spacer()

                                // Artist
                                Text(track.grandparentTitle ?? "")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .lineLimit(1)

                                // Duration
                                if let duration = track.duration {
                                    Text(formatDuration(duration))
                                        .font(.system(size: 18).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 60, alignment: .trailing)
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                        .focused($focusedContentId, equals: track.ratingKey)
                        .musicItemContextMenu(item: track, style: .track)

                        if index < allTracks.count - 1 {
                            Divider()
                                .background(.white.opacity(0.06))
                                .padding(.leading, 66)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, musicQueue.isActive ? 120 : 40)
            }
        }
    }

    // MARK: - Shared Components

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)]
    }

    private func contentGrid(items: [PlexMetadata], isLoading: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if items.isEmpty && isLoading {
                loadingIndicator
            } else if items.isEmpty {
                emptyStateView("No items found")
            } else {
                LazyVGrid(columns: gridColumns, spacing: 30) {
                    ForEach(items, id: \.ratingKey) { item in
                        MusicPosterCard(item: item, style: item.type == "artist" ? .circular : .square) {
                            handleItemSelected(item)
                        }
                        .focused($focusedContentId, equals: item.ratingKey)
                        .musicItemContextMenu(item: item, style: item.type == "track" ? .track : .album)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, musicQueue.isActive ? 120 : 40)
            }
        }
    }

    private var loadingIndicator: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func emptyStateView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))
            Text(message)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Navigation

    private func handleItemSelected(_ item: PlexMetadata) {
        switch item.type {
        case "artist":
            selectedArtist = item
        case "album":
            selectedAlbum = item
        case "track":
            musicQueue.playNow(track: item)
        default:
            selectedAlbum = item
        }
    }

    // MARK: - Data Loading

    private func loadInitialData() async {
        await loadHubs()
        await loadGenres()
    }

    private func loadCategoryData(_ category: MusicLibraryCategory) async {
        guard !loadedCategories.contains(category) else { return }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        switch category {
        case .recentlyAdded:
            // Already loaded via hubs
            break
        case .playlists:
            do {
                playlists = try await networkManager.getPlaylists(
                    serverURL: serverURL, authToken: token
                )
            } catch {
                print("MusicHomeView: Failed to load playlists: \(error)")
            }
        case .artists:
            do {
                allArtists = try await networkManager.getLibraryItems(
                    serverURL: serverURL, authToken: token,
                    sectionId: libraryKey, start: 0, size: 500
                )
                // Filter to artists only (type 8 in Plex)
                allArtists = allArtists.filter { $0.type == "artist" }
            } catch {
                print("MusicHomeView: Failed to load artists: \(error)")
            }
        case .albums:
            do {
                let result = try await networkManager.getLibraryItemsWithTotal(
                    serverURL: serverURL, authToken: token,
                    sectionId: libraryKey, start: 0, size: 500,
                    sort: "-addedAt"
                )
                allAlbums = result.items.filter { $0.type == "album" }
                // If we got artist-level items, load albums separately
                if allAlbums.isEmpty {
                    allAlbums = result.items
                }
            } catch {
                print("MusicHomeView: Failed to load albums: \(error)")
            }
        case .songs:
            do {
                allTracks = try await networkManager.getLibraryItems(
                    serverURL: serverURL, authToken: token,
                    sectionId: libraryKey, start: 0, size: 500
                )
                allTracks = allTracks.filter { $0.type == "track" }
            } catch {
                print("MusicHomeView: Failed to load tracks: \(error)")
            }
        }

        loadedCategories.insert(category)
    }

    private func loadHubs() async {
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
            hubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: libraryKey
            )
            isLoading = false
        } catch {
            self.error = "Failed to load library: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadGenres() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Extract genres from hubs data
        var genreSet = Set<String>()
        for hub in hubs {
            for item in hub.Metadata ?? [] {
                for genre in item.Genre ?? [] {
                    if let tag = genre.tag {
                        genreSet.insert(tag)
                    }
                }
            }
        }
        genres = genreSet.sorted()
    }

    private func playAllContent(shuffled: Bool) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        var tracks: [PlexMetadata] = []

        if selectedCategory == .songs {
            tracks = allTracks
        } else {
            // Load all tracks from library
            do {
                tracks = try await networkManager.getLibraryItems(
                    serverURL: serverURL, authToken: token,
                    sectionId: libraryKey, start: 0, size: 1000
                ).filter { $0.type == "track" }
            } catch {
                print("MusicHomeView: Failed to load tracks for playback: \(error)")
                return
            }
        }

        if shuffled { tracks.shuffle() }
        if !tracks.isEmpty {
            musicQueue.playAlbum(tracks: tracks, startingAt: 0)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
