//
//  MusicHomeView.swift
//  Rivulet
//
//  Apple Music tvOS-inspired music library home.
//

import SwiftUI
import UIKit

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

    var showsHeader: Bool {
        self != .recentlyAdded
    }

    var supportsPlaybackActions: Bool {
        self != .playlists
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
    @State private var recentlyAddedTotal: Int?
    @State private var isLoadingMoreRecentlyAdded = false
    @State private var allArtists: [PlexMetadata] = []
    @State private var allAlbums: [PlexMetadata] = []
    @State private var allTracks: [PlexMetadata] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var loadedCategories: Set<MusicLibraryCategory> = []

    private let recentlyAddedPageSize = 60

    @State private var selectedCategory: MusicLibraryCategory = .recentlyAdded
    @State private var selectedGenre: String?
    @State private var selectedItem: PlexMetadata?
    @State private var albumSortAscending = true
    @State private var songSortAscending = true

    private let networkManager = PlexNetworkManager.shared

    // Layout constants — matches the approved wireframe
    private let sidebarWidth: CGFloat = 380
    private let sidebarLeadingPad: CGFloat = 60
    private let sidebarTrailingInset: CGFloat = 36
    private let contentLeadingPad: CGFloat = 24
    private let contentTrailingPad: CGFloat = 80
    private let contentTopPad: CGFloat = 80
    private let gridColumnSpacing: CGFloat = 48
    private let gridRowSpacing: CGFloat = 60

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridColumnSpacing, alignment: .top), count: 4)
    }

    var body: some View {
        MusicFocusContainedView(blockLeftEscape: true, onLeftBlocked: {}) {
            NavigationStack {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        }
        .onChange(of: selectedItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
        .task(id: libraryKey) {
            await loadRecentlyAdded()
            await loadGenres()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MusicLibraryCategory.allCases, id: \.self) { category in
                    sidebarRow(
                        title: category.title,
                        isSelected: selectedCategory == category && selectedGenre == nil
                    ) {
                        selectCategory(category)
                    }
                }

                if !genres.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.leading, 28)
                        .padding(.trailing, 56)
                        .padding(.top, 28)
                        .padding(.bottom, 18)

                    Text("Genres")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)

                    ForEach(genres, id: \.self) { genre in
                        sidebarRow(
                            title: genre,
                            isSelected: selectedGenre == genre
                        ) {
                            selectGenre(genre)
                        }
                    }
                }
            }
            .padding(.top, contentTopPad)
            .padding(.leading, sidebarLeadingPad)
            .padding(.trailing, sidebarTrailingInset)
            .padding(.bottom, 80)
        }
        .frame(width: sidebarWidth)
        .focusSection()
    }

    private func sidebarRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        MusicSidebarRow(title: title, isSelected: isSelected, action: action)
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .top) {
            // Scroll view fills the entire content area edge-to-edge so its
            // clipping bounds (after .scrollClipDisabled) extend to the screen
            // edges, letting focused cards in the leftmost/rightmost columns
            // grow without being clipped. The header floats on top with an
            // opaque background and masks any scroll content that overflows
            // upward into the header band.
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
                }
            }
            // Reserve top space so the first row of grid items isn't under the
            // floating header at rest position.
            .padding(.top, selectedCategory.showsHeader ? (contentTopPad + 88) : contentTopPad)
            .padding(.leading, contentLeadingPad)
            .padding(.trailing, contentTrailingPad)

            if selectedCategory.showsHeader {
                contentHeader
                    .padding(.leading, contentLeadingPad)
                    .padding(.trailing, contentTrailingPad)
                    .padding(.top, contentTopPad)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.92),
                                Color.black.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
    }

    private var contentHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)

                if !contentCountText.isEmpty {
                    Text(contentCountText)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }

            Spacer(minLength: 24)

            HStack(spacing: 14) {
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

    private var headerTitle: String {
        if let selectedGenre {
            return selectedGenre
        }
        return selectedCategory.title
    }

    // MARK: - Grids

    private func albumGrid(items: [PlexMetadata], loading: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if items.isEmpty {
                emptyState(
                    title: "No items",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                        albumCard(item: item)
                            .musicItemContextMenu(item: item, style: item.type == "track" ? .track : .album)
                            .onAppear {
                                // Paginate Recently Added as the user scrolls.
                                guard selectedCategory == .recentlyAdded else { return }
                                if index >= items.count - 12 {
                                    Task { await loadMoreRecentlyAddedIfNeeded() }
                                }
                            }
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .contentMargins(.top, 40, for: .scrollContent)
        .contentMargins(.leading, 32, for: .scrollContent)
        .contentMargins(.trailing, 32, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var artistGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if !loadedCategories.contains(.artists) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if displayedArtists.isEmpty {
                emptyState(
                    title: "No artists",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(displayedArtists, id: \.ratingKey) { artist in
                        artistCard(item: artist)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .contentMargins(.top, 40, for: .scrollContent)
        .contentMargins(.leading, 32, for: .scrollContent)
        .contentMargins(.trailing, 32, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var songsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if !loadedCategories.contains(.songs) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if displayedTracks.isEmpty {
                emptyState(
                    title: "No songs",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.offset) { index, track in
                        songRow(track: track, index: index)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 80)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Cards

    @ViewBuilder
    private func albumCard(item: PlexMetadata) -> some View {
        MusicGridCard(
            item: item,
            shape: .square,
            artworkURL: artworkURL(for: item),
            subtitle: albumSubtitle(for: item)
        ) {
            selectedItem = item
        }
    }

    @ViewBuilder
    private func artistCard(item: PlexMetadata) -> some View {
        MusicGridCard(
            item: item,
            shape: .circle,
            artworkURL: artworkURL(for: item),
            subtitle: nil
        ) {
            selectedItem = item
        }
    }

    private func artworkURL(for item: PlexMetadata) -> URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private func albumSubtitle(for item: PlexMetadata) -> String {
        item.parentTitle ?? item.grandparentTitle ?? ""
    }

    // MARK: - Songs

    private func songRow(track: PlexMetadata, index: Int) -> some View {
        let isCurrent = musicQueue.currentTrack?.ratingKey == track.ratingKey

        return Button {
            musicQueue.playAlbum(tracks: displayedTracks, startingAt: index)
        } label: {
            HStack(spacing: 18) {
                if isCurrent {
                    PlaybackIndicator(isPlaying: musicQueue.playbackState == .playing, size: .small)
                        .frame(width: 28)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title ?? "Unknown")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(track.grandparentTitle ?? track.parentTitle ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if let duration = track.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverEffect(.highlight)
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
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.5))

            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Filtered / sorted data

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
            return albumSortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private var displayedTracks: [PlexMetadata] {
        let items = filtered(items: allTracks)
        return items.sorted { lhs, rhs in
            let left = lhs.title ?? ""
            let right = rhs.title ?? ""
            return songSortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private func filtered(items: [PlexMetadata]) -> [PlexMetadata] {
        guard let selectedGenre else { return items }
        return items.filter { item in
            (item.Genre ?? []).contains(where: { $0.tag == selectedGenre })
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
        }
    }

    private var currentSortIcon: String {
        let ascending = selectedCategory == .albums ? albumSortAscending : songSortAscending
        return ascending ? "arrow.up" : "arrow.down"
    }

    // MARK: - Actions

    private func selectCategory(_ category: MusicLibraryCategory) {
        selectedCategory = category
        selectedGenre = nil
        Task { await loadCategoryData(category) }
    }

    private func selectGenre(_ genre: String) {
        selectedGenre = (selectedGenre == genre) ? nil : genre
        // Make sure the underlying category data is loaded so the filter has something to chew on
        if selectedGenre != nil {
            Task { await loadCategoryData(selectedCategory) }
        }
    }

    private func toggleSortDirection() {
        if selectedCategory == .albums {
            albumSortAscending.toggle()
        } else if selectedCategory == .songs {
            songSortAscending.toggle()
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    // MARK: - Data loading

    private func loadRecentlyAdded() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoading = true
        recentlyAddedItems = []
        recentlyAddedTotal = nil

        do {
            // Sort by addedAt descending on the library/sections/all endpoint —
            // gives us the same data as /recentlyAdded but with full pagination.
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: recentlyAddedPageSize,
                sort: "addedAt:desc",
                type: 9 // 9 = album
            )
            recentlyAddedItems = result.items
            recentlyAddedTotal = result.totalSize
        } catch {
            print("MusicHome: Failed to load recently added: \(error)")
        }

        isLoading = false
    }

    private func loadMoreRecentlyAddedIfNeeded() async {
        guard !isLoadingMoreRecentlyAdded else { return }
        guard let total = recentlyAddedTotal else { return }
        guard recentlyAddedItems.count < total else { return }
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoadingMoreRecentlyAdded = true
        defer { isLoadingMoreRecentlyAdded = false }

        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: recentlyAddedItems.count,
                size: recentlyAddedPageSize,
                sort: "addedAt:desc",
                type: 9
            )
            // De-dupe by ratingKey in case the server returns overlap.
            let existingKeys = Set(recentlyAddedItems.compactMap(\.ratingKey))
            let newItems = result.items.filter { item in
                guard let key = item.ratingKey else { return true }
                return !existingKeys.contains(key)
            }
            recentlyAddedItems.append(contentsOf: newItems)
            if let newTotal = result.totalSize {
                recentlyAddedTotal = newTotal
            }
        } catch {
            print("MusicHome: Failed to load more recently added: \(error)")
        }
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

// MARK: - MusicSidebarRow

/// Apple Music tvOS sidebar row.
/// Uses the system `Button` focus (white glass pill, dark text on focus) for the focus state.
/// "Selected but unfocused" is shown via a small leading accent dot, NOT a background pill —
/// because the system focus highlight already owns the background treatment.
private struct MusicSidebarRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Leading accent dot — only visible when this row represents the selected
                // category but isn't currently focused. When focused, the system pill is
                // the indicator, so we hide the dot to avoid double-marking.
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(isSelected && !isFocused ? 0.95 : 0)

                Text(title)
                    .font(.system(size: 26, weight: (isSelected || isFocused) ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - MusicGridCard

private struct MusicGridCard: View {
    enum Shape {
        case square
        case circle
    }

    let item: PlexMetadata
    let shape: Shape
    let artworkURL: URL?
    let subtitle: String?
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: shape == .circle ? .center : .leading, spacing: 0) {
                artwork
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(isFocused ? 1.08 : 1.0)
                    .shadow(
                        color: .black.opacity(isFocused ? 0.55 : 0.35),
                        radius: isFocused ? 24 : 14,
                        x: 0,
                        y: isFocused ? 18 : 12
                    )

                Text(item.title ?? "Unknown")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(shape == .circle ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
                    .padding(.top, isFocused ? 22 : 16)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
        }
        .buttonStyle(CardButtonStyle())
        .hoverEffectDisabled()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.22), value: isFocused)
    }

    @ViewBuilder
    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                ZStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: item.type == "artist" ? "person.fill" : "music.note")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(.white.opacity(0.28))
                }
            @unknown default:
                Color.white.opacity(0.08)
            }
        }
        .clipShape(artworkClipShape)
    }

    private var artworkClipShape: AnyShape {
        switch shape {
        case .square:
            return AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .circle:
            return AnyShape(Circle())
        }
    }
}

// MARK: - Focus container

/// Wraps the music view in a UIHostingController that overrides `shouldUpdateFocus`
/// to block leftward focus escape — preventing the system tvOS sidebar tab bar from
/// stealing focus when the user navigates left within the music section.
///
/// Mirrors the `FocusContainedView` used in SettingsView.swift.
private struct MusicFocusContainedView<Content: View>: UIViewControllerRepresentable {
    let blockLeftEscape: Bool
    let onLeftBlocked: () -> Void
    let content: Content

    init(blockLeftEscape: Bool, onLeftBlocked: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.blockLeftEscape = blockLeftEscape
        self.onLeftBlocked = onLeftBlocked
        self.content = content()
    }

    func makeUIViewController(context: Context) -> MusicFocusContainedHostingController<Content> {
        let vc = MusicFocusContainedHostingController(rootView: content)
        vc.view.backgroundColor = .clear
        vc.blockLeftEscape = blockLeftEscape
        vc.onLeftBlocked = onLeftBlocked
        return vc
    }

    func updateUIViewController(_ vc: MusicFocusContainedHostingController<Content>, context: Context) {
        vc.blockLeftEscape = blockLeftEscape
        vc.onLeftBlocked = onLeftBlocked
        vc.rootView = content
    }
}

private final class MusicFocusContainedHostingController<Content: View>: UIHostingController<Content> {
    var blockLeftEscape = false
    var onLeftBlocked: (() -> Void)?

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if blockLeftEscape,
           context.focusHeading == .left,
           let nextView = context.nextFocusedView,
           !nextView.isDescendant(of: view) {
            DispatchQueue.main.async { [weak self] in
                self?.onLeftBlocked?()
            }
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }
}
