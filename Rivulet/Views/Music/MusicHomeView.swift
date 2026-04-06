//
//  MusicHomeView.swift
//  Rivulet
//
//  Apple Music tvOS-inspired music library built from native tvOS controls.
//

import SwiftUI

private enum MusicSidebarFocusTarget: Hashable {
    case category(MusicLibraryCategory)
    case genre(String)
}

enum MusicLibraryCategory: String, Hashable, CaseIterable {
    case recentlyAdded
    case playlists
    case artists
    case albums
    case songs
    case composers

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .composers: return "Composers"
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .composers: return "music.quarternote.3"
        }
    }

    var showsHeader: Bool {
        self != .recentlyAdded
    }

    var supportsPlaybackActions: Bool {
        self != .playlists && self != .composers
    }
}

struct MusicHomeView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var dataStore = PlexDataStore.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var recentlyAddedItems: [PlexMetadata] = []
    @State private var allArtists: [PlexMetadata] = []
    @State private var allAlbums: [PlexMetadata] = []
    @State private var allTracks: [PlexMetadata] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var loadedCategories: Set<MusicLibraryCategory> = []

    @State private var selectedCategory: MusicLibraryCategory = .recentlyAdded
    @State private var selectedGenre: String?
    @State private var selectedItem: PlexMetadata?
    @State private var focusedArtworkItem: PlexMetadata?
    @State private var albumSortAscending = true
    @State private var songSortAscending = true
    @State private var contentResetID = UUID()

    @FocusState private var focusedSidebarTarget: MusicSidebarFocusTarget?

    private let networkManager = PlexNetworkManager.shared
    private let gridColumns = Array(repeating: GridItem(.fixed(200), spacing: 30, alignment: .top), count: 4)

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundView

                HStack(spacing: 0) {
                    sidebar
                    contentArea
                }
                .frame(maxWidth: 1140, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 54)
                .padding(.trailing, 72)
                .padding(.top, 72)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            applyLandingState()
        }
        .onAppear {
            applyLandingState()
        }
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.33, blue: 0.39),
                    Color(red: 0.18, green: 0.21, blue: 0.26),
                    Color(red: 0.09, green: 0.10, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let backgroundArtworkURL {
                CachedAsyncImage(url: backgroundArtworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Color.clear
                    }
                }
                .saturation(1.15)
                .scaleEffect(1.45)
                .blur(radius: 72)
                .opacity(0.3)
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.12), Color.black.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .mask {
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.32),
                            Color.white
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.clear,
                    Color.black.opacity(0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.26), Color.black.opacity(0.06), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 250)

                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MusicLibraryCategory.allCases, id: \.self) { category in
                    MusicSidebarRow(
                        title: category.title,
                        isSelected: selectedCategory == category
                        ,
                        target: .category(category),
                        focus: $focusedSidebarTarget
                    ) {
                        selectCategory(category)
                    }
                }
            }
            .padding(.top, 4)

            if !genres.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.12))
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Genres")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.bottom, 2)

                    ForEach(genres, id: \.self) { genre in
                        MusicSidebarRow(
                            title: genre,
                            isSelected: selectedGenre == genre
                            ,
                            target: .genre(genre),
                            focus: $focusedSidebarTarget
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedGenre = selectedGenre == genre ? nil : genre
                                contentResetID = UUID()
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: 212)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focusedSidebarTarget, .category(.recentlyAdded))
    }

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedCategory.showsHeader {
                contentHeader
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    .padding(.bottom, 26)
            } else {
                Spacer()
                    .frame(height: 8)
            }

            Group {
                switch selectedCategory {
                case .recentlyAdded:
                    albumGrid(items: displayedRecentlyAdded, loading: isLoading)
                case .playlists:
                    albumGrid(items: displayedPlaylists, loading: !loadedCategories.contains(.playlists))
                case .artists:
                    artistGrid
                case .albums:
                    albumGrid(items: displayedAlbums, loading: !loadedCategories.contains(.albums))
                case .songs:
                    songsList
                case .composers:
                    emptyState(
                        title: "No composers",
                        subtitle: "Composer browsing is not available for this library yet."
                    )
                }
            }
        }
        .frame(width: 894)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedCategory.title)
                    .font(.system(size: 29, weight: .bold))
                    .lineLimit(1)

                if !contentCountText.isEmpty {
                    Text(contentCountText)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer()

            HStack(spacing: 12) {
                if selectedCategory.supportsPlaybackActions {
                    Button {
                        Task { await playAll(shuffled: false) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.white.opacity(0.16))

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.white.opacity(0.13))
                }

                if selectedCategory == .albums || selectedCategory == .songs {
                    Button {
                        toggleSortDirection()
                    } label: {
                        Image(systemName: currentSortIcon)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(Color.white.opacity(0.14))
                }
            }
        }
    }

    private func albumGrid(items: [PlexMetadata], loading: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if items.isEmpty {
                emptyState(title: "No items", subtitle: selectedGenre == nil ? "" : "Try another genre.")
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 30) {
                    ForEach(items, id: \.ratingKey) { item in
                        MusicPosterCard(item: item, style: .square, onFocusChanged: { isFocused in
                            if isFocused {
                                focusedArtworkItem = item
                            } else if focusedArtworkItem?.ratingKey == item.ratingKey {
                                focusedArtworkItem = nil
                            }
                        }) {
                            selectedItem = item
                        }
                        .musicItemContextMenu(item: item, style: item.type == "track" ? .track : .album)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 54)
                .padding(.top, 4)
            }
        }
        .id(contentResetID)
        .scrollClipDisabled()
    }

    private var artistGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if !loadedCategories.contains(.artists) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if displayedArtists.isEmpty {
                emptyState(title: "No artists", subtitle: selectedGenre == nil ? "" : "Try another genre.")
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 30) {
                    ForEach(displayedArtists, id: \.ratingKey) { artist in
                        MusicPosterCard(item: artist, style: .circular, onFocusChanged: { isFocused in
                            if isFocused {
                                focusedArtworkItem = artist
                            } else if focusedArtworkItem?.ratingKey == artist.ratingKey {
                                focusedArtworkItem = nil
                            }
                        }) {
                            selectedItem = artist
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 54)
                .padding(.top, 4)
            }
        }
        .id(contentResetID)
        .scrollClipDisabled()
    }

    private var songsList: some View {
        List {
            if !loadedCategories.contains(.songs) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowBackground(Color.clear)
            } else if displayedTracks.isEmpty {
                emptyState(title: "No songs", subtitle: selectedGenre == nil ? "" : "Try another genre.")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(Array(displayedTracks.enumerated()), id: \.offset) { index, track in
                    songRow(track: track, index: index)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30))
                }
            }
        }
        .listStyle(.plain)
        .id(contentResetID)
    }

    private func songRow(track: PlexMetadata, index: Int) -> some View {
        let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey

        return Button {
            musicQueue.playAlbum(tracks: displayedTracks, startingAt: index)
        } label: {
            HStack(spacing: 16) {
                if isCurrent {
                    PlaybackIndicator(isPlaying: musicQueue.playbackState == .playing, size: .small)
                        .frame(width: 24)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title ?? "Unknown")
                        .font(.system(size: 18, weight: .regular))
                        .lineLimit(1)

                    Text(track.grandparentTitle ?? track.parentTitle ?? "")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if let duration = track.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 15, design: .monospaced))
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

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 20, weight: .medium))

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var displayedRecentlyAdded: [PlexMetadata] {
        filtered(items: recentlyAddedItems)
    }

    private var displayedPlaylists: [PlexMetadata] {
        playlists.sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var displayedArtists: [PlexMetadata] {
        filtered(items: allArtists)
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var displayedAlbums: [PlexMetadata] {
        let items = filtered(items: allAlbums)
        return items.sorted { lhs, rhs in
            let left = lhs.title ?? ""
            let right = rhs.title ?? ""
            return albumSortAscending ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private var displayedTracks: [PlexMetadata] {
        let items = filtered(items: allTracks)
        return items.sorted { lhs, rhs in
            let left = lhs.title ?? ""
            let right = rhs.title ?? ""
            return songSortAscending ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private func filtered(items: [PlexMetadata]) -> [PlexMetadata] {
        guard let selectedGenre else { return items }
        return items.filter { item in
            (item.Genre ?? []).contains(where: { $0.tag == selectedGenre })
        }
    }

    private var backgroundArtworkURL: URL? {
        guard let item = focusedArtworkItem ?? currentArtworkItems.first,
              let thumb = item.thumb ?? item.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var currentArtworkItems: [PlexMetadata] {
        switch selectedCategory {
        case .recentlyAdded:
            return displayedRecentlyAdded
        case .playlists:
            return displayedPlaylists
        case .artists:
            return displayedArtists
        case .albums:
            return displayedAlbums
        case .songs, .composers:
            return []
        }
    }

    private var contentCountText: String {
        switch selectedCategory {
        case .recentlyAdded:
            return ""
        case .playlists:
            return displayedPlaylists.isEmpty ? "" : "\(displayedPlaylists.count) playlists"
        case .artists:
            return displayedArtists.isEmpty ? "" : "\(displayedArtists.count) artists"
        case .albums:
            return displayedAlbums.isEmpty ? "" : "\(displayedAlbums.count) albums"
        case .songs:
            return displayedTracks.isEmpty ? "" : "\(displayedTracks.count) songs"
        case .composers:
            return ""
        }
    }

    private var currentSortIcon: String {
        let ascending = selectedCategory == .albums ? albumSortAscending : songSortAscending
        return ascending ? "arrow.up" : "arrow.down"
    }

    private func toggleSortDirection() {
        if selectedCategory == .albums {
            albumSortAscending.toggle()
        } else if selectedCategory == .songs {
            songSortAscending.toggle()
        }
    }

    private func selectCategory(_ category: MusicLibraryCategory) {
        selectedCategory = category
        selectedGenre = nil
        focusedArtworkItem = nil
        contentResetID = UUID()
        focusedSidebarTarget = .category(category)
        Task { await loadCategoryData(category) }
    }

    private func applyLandingState() {
        selectedCategory = .recentlyAdded
        selectedGenre = nil
        selectedItem = nil
        focusedArtworkItem = nil
        contentResetID = UUID()
        focusedSidebarTarget = .category(.recentlyAdded)
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func loadRecentlyAdded() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoading = true

        if let cached = dataStore.libraryHubs[libraryKey], !cached.isEmpty {
            let hubItems = cached.flatMap { $0.Metadata ?? [] }
            let albums = hubItems.filter { $0.type == "album" }
            recentlyAddedItems = albums.isEmpty ? hubItems : albums
            isLoading = false
            return
        }

        do {
            let hubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey
            )
            let hubItems = hubs.flatMap { $0.Metadata ?? [] }
            let albums = hubItems.filter { $0.type == "album" }
            recentlyAddedItems = albums.isEmpty ? hubItems : albums

            if recentlyAddedItems.isEmpty {
                recentlyAddedItems = try await networkManager.getLibraryItems(
                    serverURL: serverURL,
                    authToken: token,
                    sectionId: libraryKey,
                    start: 0,
                    size: 50,
                    type: 9
                )
            }
        } catch {
            print("MusicHome: Failed to load recently added: \(error)")
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
            break
        case .playlists:
            playlists = (try? await networkManager.getPlaylists(serverURL: serverURL, authToken: token)) ?? []
        case .artists:
            allArtists = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 500,
                type: 8
            )) ?? []
        case .albums:
            allAlbums = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 500,
                type: 9
            )) ?? []
        case .songs:
            allTracks = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 500,
                type: 10
            )) ?? []
        case .composers:
            break
        }

        loadedCategories.insert(category)
    }

    private func playAll(shuffled: Bool) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        var tracks: [PlexMetadata]
        if selectedCategory == .songs, !displayedTracks.isEmpty {
            tracks = displayedTracks
        } else {
            tracks = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 1000,
                type: 10
            )) ?? []
        }

        if shuffled { tracks.shuffle() }
        if !tracks.isEmpty {
            musicQueue.playAlbum(tracks: tracks)
        }
    }
}

private struct MusicSidebarRow: View {
    let title: String
    let isSelected: Bool
    let target: MusicSidebarFocusTarget
    let focus: FocusState<MusicSidebarFocusTarget?>.Binding
    let action: () -> Void

    private var isFocused: Bool {
        focus.wrappedValue == target
    }

    private var highlightOpacity: Double {
        if isFocused {
            return 0.34
        }
        if isSelected {
            return 0.18
        }
        return 0
    }

    private var foregroundOpacity: Double {
        isFocused || isSelected ? 0.98 : 0.8
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Circle()
                    .fill(.white.opacity(isFocused || isSelected ? 0.95 : 0.42))
                    .frame(width: isFocused || isSelected ? 7 : 5, height: isFocused || isSelected ? 7 : 5)
                    .frame(width: 9, alignment: .center)

                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(highlightOpacity))
            )
        }
        .buttonStyle(.plain)
        .focused(focus, equals: target)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }
}
