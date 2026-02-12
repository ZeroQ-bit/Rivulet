//
//  PlexDetailView.swift
//  Rivulet
//
//  Detail view for movies and TV shows with playback options
//

import SwiftUI

struct PlexDetailView: View {
    let item: PlexMetadata

    /// Tracks the currently displayed item - allows swapping content in place
    /// When set, this overrides `item` so collection/recommended navigation
    /// replaces content rather than pushing a new view
    @State private var displayedItem: PlexMetadata?

    /// The item currently being shown - either displayedItem or the original item
    private var currentItem: PlexMetadata {
        displayedItem ?? item
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(\.focusScopeManager) private var focusScopeManager
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var episodes: [PlexMetadata] = []
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var showPlayer = false
    @State private var selectedEpisode: PlexMetadata?
    @State private var lastPlayedMetadata: PlexMetadata?  // Tracks what was playing when player dismissed (for auto-play)
    @State private var fullEpisodeMetadata: [String: PlexMetadata] = [:]  // Prefetched full metadata keyed by ratingKey
    @State private var nextUpEpisode: PlexMetadata?  // The episode that will play when pressing Play on a show

    // Music album state
    @State private var tracks: [PlexMetadata] = []
    @State private var isLoadingTracks = false
    @State private var selectedTrack: PlexMetadata?

    // Music artist state
    @State private var albums: [PlexMetadata] = []
    @State private var isLoadingAlbums = false
    @State private var navigateToAlbum: PlexMetadata?  // For binding-based navigation
    @State private var artistTracks: [PlexMetadata] = []  // All tracks for "Play All"
    @State private var isLoadingArtistTracks = false
    @State private var showBioSheet = false  // Show artist bio

    #if os(tvOS)
    // Focus state for restoring focus when returning from nested navigation
    @FocusState private var focusedAlbumId: String?
    @FocusState private var focusedTrackId: String?
    @FocusState private var focusedSeasonId: String?  // Track focused season
    @FocusState private var focusedEpisodeId: String?  // Track focused episode
    @FocusState private var focusedActionButton: String?  // Track focused action button
    @State private var savedAlbumFocus: String?  // Save focus when navigating to album
    @State private var savedTrackFocus: String?  // Save focus when playing track
    @State private var isSummaryExpanded = false  // Expand summary text on focus/click
    @State private var isEpisodeSectionFocused = false  // Tracks whether episode list has focus (for season overlay)
    #endif

    // New state for cast/crew, collections, and recommendations
    @State private var fullMetadata: PlexMetadata?
    @State private var collectionItems: [PlexMetadata] = []
    @State private var collectionName: String?
    @State private var recommendedItems: [PlexMetadata] = []
    @State private var isWatched = false
    @State private var isStarred = false  // For music: 5-star rating toggle
    @State private var displayedProgress: Double = 0  // For animating progress bar
    @State private var isLoadingExtras = false
    @State private var showTrailerPlayer = false
    @State private var trailerMetadata: PlexMetadata?  // Full metadata for trailer playback
    @State private var playFromBeginning = false  // For "Play from Beginning" button
    @State private var isLoadingShufflePlay = false
    @State private var shuffledEpisodeQueue: [PlexMetadata] = []
    @State private var showLogoURL: URL?  // TMDB stylized logo for shows/movies

    // Navigation state for episode parent navigation
    @State private var navigateToSeason: PlexMetadata?
    @State private var navigateToShow: PlexMetadata?
    @State private var navigateToEpisode: PlexMetadata?
    @State private var isLoadingNavigation = false

    private let networkManager = PlexNetworkManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Effective item data - uses fullMetadata for progress/viewOffset when available
    /// This ensures we have the most up-to-date playback position after returning from the player
    private var effectiveItem: PlexMetadata {
        if let full = fullMetadata {
            // Merge updated viewOffset/viewCount into currentItem
            var merged = currentItem
            merged.viewOffset = full.viewOffset
            merged.viewCount = full.viewCount
            return merged
        }
        return currentItem
    }

    /// Play button label for TV shows and seasons
    /// Shows "Continue S02E05" for in-progress episodes, "Play" otherwise
    private var showPlayButtonLabel: String {
        guard let episode = nextUpEpisode else { return "Play" }

        // Check if the episode is in progress
        if episode.isInProgress, let epString = episode.episodeString {
            return "Continue \(epString)"
        }

        return "Play"
    }

    /// Caption shown below the Play button when there's a next episode to play
    /// Returns nil for in-progress episodes (button already shows episode info)
    private var upNextCaption: String? {
        guard let episode = nextUpEpisode else { return nil }

        // Don't show caption if episode is in progress (button already says "Continue S02E05")
        if episode.isInProgress { return nil }

        // Build "Up Next: S02E05 - Title" caption
        let epString = episode.episodeString ?? ""
        let title = episode.title ?? ""

        if !epString.isEmpty && !title.isEmpty {
            // Truncate long titles
            let maxTitleLength = 25
            let truncatedTitle = title.count <= maxTitleLength
                ? title
                : String(title.prefix(maxTitleLength - 1)) + "…"
            return "Up Next: \(epString) - \(truncatedTitle)"
        } else if !epString.isEmpty {
            return "Up Next: \(epString)"
        } else if !title.isEmpty {
            return "Up Next: \(title)"
        }

        return nil
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Hero Section with backdrop
                heroSection

                // Content Section
                VStack(alignment: .leading, spacing: 32) {
                    // Title and metadata
                    headerSection

                    // Action buttons
                    actionButtons

                    // Up Next caption for shows/seasons (below button row, above description)
                    if let caption = upNextCaption {
                        Text(caption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Progress bar for in-progress content (movies/episodes)
                    // Show if not watched and has progress
                    if !isMusicItem, !isWatched, displayedProgress > 0 {
                        progressSection(progress: displayedProgress)
                            .transition(.opacity.animation(.easeOut(duration: 0.3)))
                    }

                    // Summary (focusable on tvOS so it's a navigation stop between action buttons and rows below)
                    if let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                        #if os(tvOS)
                        summarySection(summary: summary)
                        #else
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        #endif
                    }

                    // TV Show specific: Seasons and Episodes
                    // Also show for episodes so users can browse the parent show inline
                    if currentItem.type == "show" || currentItem.type == "episode" {
                        seasonSection
                    }

                    // Season specific: Episodes list (no season picker needed)
                    if currentItem.type == "season" {
                        episodeSection
                    }

                    // Album specific: Tracks
                    if currentItem.type == "album" {
                        trackSection
                    }

                    // Artist specific: Albums
                    if currentItem.type == "artist" {
                        albumSection
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 8)

                // Collection Section (for movies that are part of a collection)
                if !collectionItems.isEmpty, let name = collectionName {
                    MediaItemRow(
                        title: name,
                        items: collectionItems,
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        onItemSelected: { selectedItem in
                            // Replace current view content with crossfade animation
                            withAnimation(.easeInOut(duration: 0.35)) {
                                displayedItem = selectedItem
                            }
                        }
                    )
                    .padding(.top, 32)
                }

                // Recommended Section (TMDB-powered)
                if !recommendedItems.isEmpty {
                    MediaItemRow(
                        title: "Recommended",
                        items: recommendedItems,
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        onItemSelected: { selectedItem in
                            // Replace current view content with crossfade animation
                            withAnimation(.easeInOut(duration: 0.35)) {
                                displayedItem = selectedItem
                            }
                        }
                    )
                    .padding(.top, 32)
                }

                // Cast & Crew Section
                if let metadata = fullMetadata,
                   (!metadata.cast.isEmpty || !(metadata.Director?.isEmpty ?? true)) {
                    CastCrewRow(
                        cast: metadata.cast,
                        directors: metadata.Director ?? [],
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? ""
                    )
                    .padding(.top, 32)
                }

                Spacer()
                    .frame(height: 60)
            }
        }
        .defaultScrollAnchor(.top)
        .ignoresSafeArea(edges: .top)
        #if os(tvOS)
        .overlay(alignment: .leading) {
            if seasons.count > 1 {
                seasonOverlay
                    .padding(.leading, 48)
            }
        }
        #endif
        .task(id: currentItem.ratingKey) {
            // Debug: log what item we're loading
            print("📋 PlexDetailView loading: \(currentItem.title ?? "?") (type: \(currentItem.type ?? "nil"), ratingKey: \(currentItem.ratingKey ?? "nil"))")

            // Reset state for new item
            seasons = []
            episodes = []
            selectedSeason = nil
            fullMetadata = nil
            collectionItems = []
            collectionName = nil
            recommendedItems = []
            nextUpEpisode = nil
            showLogoURL = nil
            #if os(tvOS)
            isSummaryExpanded = false
            isEpisodeSectionFocused = false
            #endif

            // Initialize watched state
            isWatched = currentItem.isWatched

            // Initialize progress for animation
            displayedProgress = currentItem.watchProgress ?? 0

            // Initialize starred state for music (userRating > 0 means starred)
            isStarred = (currentItem.userRating ?? 0) > 0

            // Load full metadata for cast/crew and trailer
            await loadFullMetadata()

            // Fetch TMDB logo for shows, movies, and episodes
            await loadShowLogo()

            // Load collection and recommendations for movies
            if currentItem.type == "movie" {
                // Load collection items if movie is part of a collection
                if let collection = fullMetadata?.Collection?.first,
                   let collectionId = collection.idString,
                   let sectionId = fullMetadata?.librarySectionID {
                    let name = (collection.tag ?? "Collection") + " Collection"
                    await loadCollectionItems(sectionId: String(sectionId), collectionId: collectionId, name: name)
                }
                // Load TMDB-powered recommendations
                await loadRecommendedItems()
            }

            // Load seasons for TV shows
            if currentItem.type == "show" {
                await loadSeasons()
                // Determine the "next up" episode for the Play button
                await loadNextUpEpisode()
            }

            // Load episodes for seasons
            if currentItem.type == "season" {
                await loadEpisodesForSeason()
                // Determine the "next up" episode for the Play button
                await loadNextUpEpisode()
            }

            // Load seasons for episodes (show parent show's seasons inline)
            if currentItem.type == "episode" {
                await loadSeasonsForEpisode()
            }

            // Load tracks for albums
            if currentItem.type == "album" {
                await loadTracks()
            }

            // Load albums for artists
            if currentItem.type == "artist" {
                await loadAlbums()
            }
        }
        #if os(tvOS)
        .onChange(of: showPlayer) { _, shouldShow in
            if shouldShow {
                presentPlayer()
            }
        }
        #else
        .fullScreenCover(isPresented: $showPlayer) {
            // Play the selected episode/track if available, otherwise play the main item (movie/album)
            // Use prefetched full metadata for episodes (has Stream data for DV detection)
            let playItem: PlexMetadata = if let episode = selectedEpisode {
                // Use prefetched full metadata if available
                if let ratingKey = episode.ratingKey, let fullEpisode = fullEpisodeMetadata[ratingKey] {
                    fullEpisode
                } else {
                    episode
                }
            } else if selectedTrack != nil {
                selectedTrack!
            } else {
                // For main item (movie), prefer fullMetadata as it has Stream data for DV/HDR detection
                fullMetadata ?? item
            }
            // Use fullMetadata for updated viewOffset when playing the main item (not episodes/tracks)
            let viewOffset = (selectedEpisode == nil && selectedTrack == nil)
                ? (fullMetadata?.viewOffset ?? playItem.viewOffset)
                : playItem.viewOffset
            let resumeOffset = playFromBeginning ? nil : (Double(viewOffset ?? 0) / 1000.0)
            // Use wrapper to capture last-played metadata for auto-play detection
            PlayerViewWrapper(
                playItem: playItem,
                startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                lastPlayedMetadata: $lastPlayedMetadata
            )
        }
        #endif
        .fullScreenCover(isPresented: $showTrailerPlayer) {
            // Play trailer using the same player as regular content
            if let metadata = trailerMetadata {
                UniversalPlayerView(metadata: metadata)
            }
        }
        .onChange(of: showTrailerPlayer) { _, isShowing in
            // Clear trailer metadata when player is dismissed
            if !isShowing {
                trailerMetadata = nil
            }
        }
        .sheet(isPresented: $showBioSheet) {
            ArtistBioSheet(
                artistName: fullMetadata?.title ?? currentItem.title ?? "Artist",
                bio: fullMetadata?.summary ?? currentItem.summary ?? "",
                thumbURL: artistThumbURL
            )
        }
        .onChange(of: showPlayer) { _, isShowing in
            // Clear selected episode/track and playFromBeginning when player closes
            if !isShowing {
                // Capture episode ratingKey before clearing for refresh
                let playedEpisodeKey = selectedEpisode?.ratingKey
                let lastPlayed = lastPlayedMetadata

                selectedEpisode = nil
                selectedTrack = nil
                playFromBeginning = false
                lastPlayedMetadata = nil

                // If we're on an episode detail page and auto-play advanced to a different episode,
                // swap the displayed item so the detail page shows the last-played episode
                if currentItem.type == "episode",
                   let lastPlayed,
                   lastPlayed.ratingKey != currentItem.ratingKey {
                    displayedItem = lastPlayed
                    // .task(id: currentItem.ratingKey) will fire and do a full reload
                    return
                }

                // Refresh metadata to get updated viewOffset after playback
                Task {
                    await loadFullMetadata()

                    // Update displayed progress and watched state from refreshed metadata
                    if let full = fullMetadata {
                        withAnimation(.easeOut(duration: 0.3)) {
                            displayedProgress = full.watchProgress ?? 0
                            isWatched = full.isWatched
                        }
                    }

                    // Also refresh the specific episode if one was played
                    if let episodeKey = playedEpisodeKey {
                        await refreshEpisodeWatchStatus(ratingKey: episodeKey)
                    }

                    // For show/season detail pages, also refresh episode list and next-up
                    if currentItem.type == "show" || currentItem.type == "season" {
                        if let season = selectedSeason {
                            await loadEpisodes(for: season)
                        }
                        await loadNextUpEpisode()
                    }
                }
            }
        }
        .navigationDestination(item: $navigateToAlbum) { album in
            PlexDetailView(item: album)
        }
        .navigationDestination(item: $navigateToSeason) { season in
            PlexDetailView(item: season)
        }
        .navigationDestination(item: $navigateToShow) { show in
            PlexDetailView(item: show)
        }
        .navigationDestination(item: $navigateToEpisode) { episode in
            PlexDetailView(item: episode)
        }
        // Update goBackAction when viewing nested album
        .onChange(of: navigateToAlbum) { oldAlbum, newAlbum in
            if newAlbum != nil {
                // Override goBackAction to just dismiss the album, not go all the way back
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    navigateToAlbum = nil
                    // Keep nested state true since we're still in artist view
                    nestedNavState?.isNested = true
                }
            } else if oldAlbum != nil {
                // Returned from album - restore goBackAction to dismiss this view
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    nestedNavState?.isNested = false
                    dismiss()
                }
            }
            #if os(tvOS)
            // Restore focus when returning from album
            if oldAlbum != nil && newAlbum == nil, let savedFocus = savedAlbumFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedAlbumId = savedFocus
                }
            }
            #endif
        }
        #if os(tvOS)
        // Restore track focus when returning from player
        .onChange(of: showPlayer) { wasPlaying, isPlaying in
            if wasPlaying && !isPlaying, let savedFocus = savedTrackFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedTrackId = savedFocus
                }
            }
        }
        #endif
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Background art with squircle corners
            CachedAsyncImage(url: artURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.3), Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .id(artURL)
            .transition(.opacity)
            .frame(height: 600)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay {
                // Gradient overlay for text readability
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .overlay {
                // TMDB logo centered in hero for shows/movies
                if currentItem.type != "episode", let logoURL = showLogoURL {
                    CachedAsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .shadow(color: .black.opacity(0.8), radius: 20, x: 0, y: 4)
                        default:
                            Color.clear
                        }
                    }
                    .frame(maxWidth: 700, maxHeight: 200)
                }
            }
            // GPU-accelerated shadow: blur is hardware-accelerated, unlike .shadow() with large radius
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.black)
                    .blur(radius: 20)
                    .offset(y: 10)
                    .opacity(0.5)
            )
            .padding(.horizontal, 48)

            // Poster overlay - right aligned, larger with squircle corners
            HStack(alignment: .bottom, spacing: 32) {
                Spacer()

                CachedAsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay { ProgressView().tint(.white.opacity(0.3)) }
                    case .failure:
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.18), Color(white: 0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay {
                                Image(systemName: iconForType)
                                    .font(.system(size: 50, weight: .light))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                    }
                }
                .id(posterURL)
                .transition(.opacity)
                .frame(width: 400, height: isMusicItem ? 400 : 600)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                // GPU-accelerated shadow
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.black)
                        .blur(radius: 20)
                        .offset(y: 10)
                        .opacity(0.5)
                )
            }
            .padding(.horizontal, 96) // Inset from hero edges
            .padding(.bottom, isMusicItem ? -40 : -140) // Overlap below hero section
        }
        .animation(.easeInOut(duration: 0.3), value: currentItem.ratingKey)
    }

    /// Check if this is a music item (album, artist, track)
    private var isMusicItem: Bool {
        currentItem.type == "album" || currentItem.type == "artist" || currentItem.type == "track"
    }

    /// Icon for fallback poster based on item type
    private var iconForType: String {
        switch currentItem.type {
        case "movie": return "film"
        case "show": return "tv"
        case "album": return "music.note.list"
        case "artist": return "music.mic"
        case "track": return "music.note"
        default: return "photo"
        }
    }

    /// Artist thumbnail URL for bio sheet
    private var artistThumbURL: URL? {
        guard let thumb = fullMetadata?.thumb ?? currentItem.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Load and play all tracks for an artist
    private func playAllArtistTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingArtistTracks = true
        defer { isLoadingArtistTracks = false }

        do {
            // Use getAllLeaves to get all tracks for this artist
            let allTracks = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            if let firstTrack = allTracks.first {
                artistTracks = allTracks
                selectedTrack = firstTrack
                showPlayer = true
            }
        } catch {
            print("Failed to load artist tracks: \(error)")
        }
    }

    /// Shuffle play all episodes for a show or season
    private func shufflePlay() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingShufflePlay = true
        defer { isLoadingShufflePlay = false }

        do {
            // For seasons, use getChildren (allLeaves returns empty for seasons)
            // For shows, use getAllLeaves to get episodes across all seasons
            let allEpisodes: [PlexMetadata]
            if currentItem.type == "season" {
                allEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            } else {
                allEpisodes = try await networkManager.getAllLeaves(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            }

            guard !allEpisodes.isEmpty else { return }

            var shuffled = allEpisodes
            shuffled.shuffle()

            selectedEpisode = shuffled[0]
            shuffledEpisodeQueue = shuffled
            playFromBeginning = true
            showPlayer = true
        } catch {
            print("Failed to load episodes for shuffle play: \(error)")
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Spacer for poster overlap (minimal - just enough to clear poster bottom)
            Spacer()
                .frame(height: isMusicItem ? 20 : 40)

            Text(fullMetadata?.title ?? currentItem.title ?? "Unknown Title")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                if let year = fullMetadata?.year ?? currentItem.year {
                    Text(String(year))
                }

                if let contentRating = fullMetadata?.contentRating ?? currentItem.contentRating {
                    Text(contentRating)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                        }
                }

                if let duration = fullMetadata?.durationFormatted ?? currentItem.durationFormatted {
                    Text(duration)
                }

                if let rating = fullMetadata?.rating ?? currentItem.rating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                    }
                }

                // Use fullMetadata for media info since hub items don't include Stream data
                if let videoQuality = fullMetadata?.videoQualityDisplay ?? currentItem.videoQualityDisplay {
                    Text(videoQuality)
                }

                if let hdrFormat = fullMetadata?.hdrFormatDisplay ?? currentItem.hdrFormatDisplay {
                    Text(hdrFormat)
                }

                if let audioFormat = fullMetadata?.audioFormatDisplay ?? currentItem.audioFormatDisplay {
                    Text(audioFormat)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let tagline = fullMetadata?.tagline ?? currentItem.tagline {
                Text(tagline)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action Button Constants

    private let actionButtonHeight: CGFloat = 66
    private let actionButtonWidth: CGFloat = 220

    // MARK: - Progress Section

    private func progressSection(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.2))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * progress)
                        .animation(.easeOut(duration: 0.5), value: progress)
                }
            }
            .frame(height: 6)

            // Time remaining text (hide when animating to 100%)
            if progress < 1, let remaining = effectiveItem.remainingTimeFormatted {
                Text("\(remaining) remaining")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 500)
    }

    // MARK: - Summary Section (tvOS)

    #if os(tvOS)
    @ViewBuilder
    private func summarySection(summary: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSummaryExpanded.toggle()
            }
        } label: {
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(isSummaryExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Play button for movies, shows, albums
            // Play All button for artists
            if currentItem.type == "artist" {
                Button {
                    Task {
                        await playAllArtistTracks()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingArtistTracks {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Play All")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play"))
                .focused($focusedActionButton, equals: "play")
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .disabled(isLoadingArtistTracks)
            } else if currentItem.type == "album" {
                Button {
                    if let firstTrack = tracks.first {
                        selectedTrack = firstTrack
                    }
                    showPlayer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play Album")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play"))
                .focused($focusedActionButton, equals: "play")
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .disabled(tracks.isEmpty)
            } else if currentItem.type == "show" || currentItem.type == "season" {
                // TV Show/Season: Play button uses nextUpEpisode
                Button {
                    if let episode = nextUpEpisode {
                        selectedEpisode = episode
                    }
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(showPlayButtonLabel)
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play"))
                .focused($focusedActionButton, equals: "play")
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .disabled(nextUpEpisode == nil)

                // Shuffle Play button
                Button {
                    Task { await shufflePlay() }
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingShufflePlay {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Shuffle")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "shuffle", isPrimary: false))
                .focused($focusedActionButton, equals: "shuffle")
                #else
                .buttonStyle(.bordered)
                #endif
                .disabled(isLoadingShufflePlay)
            } else if currentItem.type != "track" {
                // Movies/Episodes: Standard Play/Resume button
                Button {
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(effectiveItem.isInProgress ? "Resume" : "Play")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play"))
                .focused($focusedActionButton, equals: "play")
                #else
                .buttonStyle(.borderedProminent)
                #endif

                // Restart button (only for in-progress content)
                if effectiveItem.isInProgress {
                    Button {
                        playFromBeginning = true
                        showPlayer = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restart")
                        }
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: actionButtonWidth, height: actionButtonHeight)
                    }
                    #if os(tvOS)
                    .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "restart", isPrimary: false))
                    .focused($focusedActionButton, equals: "restart")
                    #else
                    .buttonStyle(.bordered)
                    #endif
                }
            }

            // For music: Star rating toggle (5 stars or no rating)
            // For other content: Watched toggle button
            if isMusicItem {
                Button {
                    Task {
                        await toggleStarRating()
                    }
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 30, weight: .medium))
                        #if os(tvOS)
                        // Black when focused, yellow when starred, gray when not starred
                        .foregroundStyle(focusedActionButton == "star" ? .black : (isStarred ? .yellow : .secondary))
                        #else
                        .foregroundStyle(isStarred ? .yellow : .secondary)
                        #endif
                        .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "star", isPrimary: false))
                .focused($focusedActionButton, equals: "star")
                #else
                .buttonStyle(.bordered)
                #endif
            } else {
                #if os(tvOS)
                Button {
                    Task {
                        await toggleWatched()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                        Text(isWatched ? "Watched" : "Unwatched")
                    }
                    // Black when focused (for visibility on white bg), green when watched + unfocused, white when unwatched + unfocused
                    .foregroundStyle(focusedActionButton == "watched" ? .black : (isWatched ? .green : .white))
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watched", isPrimary: false))
                .focused($focusedActionButton, equals: "watched")
                #else
                Button {
                    Task {
                        await toggleWatched()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isWatched ? "checkmark.circle.fill" : "circle")
                        Text(isWatched ? "Watched" : "Unwatched")
                    }
                    .foregroundStyle(isWatched ? .green : .primary)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                .buttonStyle(.bordered)
                #endif
            }

            // Show button (for seasons)
            if currentItem.type == "season", currentItem.parentRatingKey != nil {
                Button {
                    Task { await navigateToParentShowFromSeason() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tv")
                        Text("Show")
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "showFromSeason", isPrimary: false))
                .focused($focusedActionButton, equals: "showFromSeason")
                #else
                .buttonStyle(.bordered)
                #endif
                .disabled(isLoadingNavigation)
            }

            // Info button for artists with bio
            if currentItem.type == "artist", let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                Button {
                    showBioSheet = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                        .font(.system(size: 24, weight: .medium))
                        .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "info", isPrimary: false))
                .focused($focusedActionButton, equals: "info")
                #else
                .buttonStyle(.bordered)
                #endif
            }

            // Trailer button (only show if available, not for music)
            if !isMusicItem, fullMetadata?.trailer != nil {
                Button {
                    Task {
                        await loadAndPlayTrailer()
                    }
                } label: {
                    Label("Watch Trailer", systemImage: "film")
                        .font(.system(size: 24, weight: .medium))
                        .frame(width: actionButtonWidth, height: actionButtonHeight)
                }
                #if os(tvOS)
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "trailer", isPrimary: false))
                .focused($focusedActionButton, equals: "trailer")
                #else
                .buttonStyle(.bordered)
                #endif
            }

            Spacer()

            // Progress info on the right (not for music)
            if !isMusicItem, let progress = effectiveItem.viewOffsetFormatted, effectiveItem.isInProgress {
                Text("\(progress) watched")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: - Season Overlay (tvOS, pinned outside ScrollView)

    #if os(tvOS)
    private var seasonOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seasons")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.leading, 18)
                .padding(.bottom, 4)

            ForEach(seasons, id: \.ratingKey) { season in
                SeasonListRow(
                    season: season,
                    isSelected: selectedSeason?.ratingKey == season.ratingKey,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    onRefreshNeeded: { await refreshEpisodeWatchStatus(ratingKey: nil) },
                    onSelect: {
                        guard season.ratingKey != selectedSeason?.ratingKey else { return }
                        selectedSeason = season
                        Task { await loadEpisodes(for: season) }
                    },
                    focusedSeasonId: $focusedSeasonId
                )
                .focusable(isEpisodeSectionFocused || focusedSeasonId != nil)
            }
        }
        .frame(width: 300)
        .focusSection()
        .opacity(isEpisodeSectionFocused || focusedSeasonId != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isEpisodeSectionFocused)
    }
    #endif

    // MARK: - Season Section (TV Shows)

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Show the parent show title (or logo) when viewing an episode
            if currentItem.type == "episode", let showTitle = currentItem.grandparentTitle {
                if let logoURL = showLogoURL {
                    CachedAsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        default:
                            Text(showTitle)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 600, maxHeight: 180)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 32)
                } else {
                    Text(showTitle)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.top, 32)
                }
            }

            if isLoadingSeasons {
                ProgressView("Loading seasons...")
            } else if !seasons.isEmpty {
                #if os(tvOS)
                // tvOS: Split pane for multi-season, flat episode list for single season
                if seasons.count > 1 {
                    SeasonEpisodeSplitPane(
                        selectedSeason: $selectedSeason,
                        episodes: episodes,
                        isLoadingEpisodes: isLoadingEpisodes,
                        currentItemRatingKey: currentItem.ratingKey,
                        currentItemType: currentItem.type,
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        onEpisodePlay: { episode in
                            selectedEpisode = episode
                            playFromBeginning = false
                            showPlayer = true
                        },
                        onEpisodeRefresh: { ratingKey in
                            await refreshEpisodeWatchStatus(ratingKey: ratingKey)
                        },
                        onEpisodeShowInfo: { episode in
                            navigateToEpisode = episode
                        },
                        isEpisodeFocused: $isEpisodeSectionFocused
                    )
                } else {
                    // Single season: episode list only
                    seasonSectionEpisodeList
                }
                #else
                // Non-tvOS: horizontal poster carousel + vertical episode list
                if seasons.count > 1 {
                    Text("Seasons")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top, 16)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 24) {
                                ForEach(seasons, id: \.ratingKey) { season in
                                    SeasonPosterCard(
                                        season: season,
                                        isSelected: selectedSeason?.ratingKey == season.ratingKey,
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? ""
                                    ) {
                                        selectedSeason = season
                                        Task {
                                            await loadEpisodes(for: season)
                                        }
                                    }
                                    .id(season.ratingKey)
                                }
                            }
                            .padding(.horizontal, 48)
                            .padding(.vertical, 32)
                        }
                        .onChange(of: selectedSeason?.ratingKey) { oldKey, newKey in
                            guard let key = newKey else { return }
                            if oldKey == nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    proxy.scrollTo(key, anchor: .center)
                                }
                            } else {
                                withAnimation {
                                    proxy.scrollTo(key, anchor: .center)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, -48)
                    .scrollClipDisabled()
                    .focusSection()
                }

                // Non-tvOS episode list
                seasonSectionEpisodeList
                #endif
            }
        }
    }

    /// Shared episode list used by single-season tvOS path and all non-tvOS paths
    private var seasonSectionEpisodeList: some View {
        Group {
            let episodeCount = selectedSeason?.leafCount ?? 0
            if isLoadingEpisodes && episodeCount > 0 {
                Text("Episodes")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.top, seasons.count > 1 ? 16 : 0)

                LazyVStack(spacing: 16) {
                    ForEach(1...episodeCount, id: \.self) { index in
                        SkeletonEpisodeRow(episodeNumber: index)
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 8)
                #endif
            } else if isLoadingEpisodes {
                ProgressView("Loading episodes...")
                    .padding(.top, 20)
            } else if !episodes.isEmpty {
                Text("Episodes")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.top, seasons.count > 1 ? 16 : 0)

                LazyVStack(spacing: 16) {
                    ForEach(episodes, id: \.ratingKey) { episode in
                        let isCurrentEpisode = currentItem.type == "episode" && episode.ratingKey == currentItem.ratingKey
                        #if os(tvOS)
                        EpisodeRow(
                            episode: episode,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            isCurrent: isCurrentEpisode,
                            focusedEpisodeId: $focusedEpisodeId,
                            onPlay: {
                                selectedEpisode = episode
                                playFromBeginning = false
                                showPlayer = true
                            },
                            onRefreshNeeded: {
                                await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                            },
                            onShowInfo: {
                                navigateToEpisode = episode
                            }
                        )
                        #else
                        EpisodeRow(
                            episode: episode,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            isCurrent: isCurrentEpisode,
                            onPlay: {
                                selectedEpisode = episode
                                playFromBeginning = false
                                showPlayer = true
                            },
                            onRefreshNeeded: {
                                await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                            },
                            onShowInfo: {
                                navigateToEpisode = episode
                            }
                        )
                        #endif
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 8)
                .focusSection()
                .remembersFocus(key: "detailEpisodes", focusedId: $focusedEpisodeId)
                #endif
            }
        }
    }

    // MARK: - Episode Section (Seasons)

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingEpisodes {
                ProgressView("Loading episodes...")
            } else if !episodes.isEmpty {
                Text("Episodes")
                    .font(.title2)
                    .fontWeight(.bold)

                LazyVStack(spacing: 16) {
                    ForEach(episodes, id: \.ratingKey) { episode in
                        #if os(tvOS)
                        EpisodeRow(
                            episode: episode,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            focusedEpisodeId: $focusedEpisodeId,
                            onPlay: {
                                selectedEpisode = episode
                                playFromBeginning = false
                                showPlayer = true
                            },
                            onRefreshNeeded: {
                                await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                            },
                            onShowInfo: {
                                navigateToEpisode = episode
                            }
                        )
                        #else
                        EpisodeRow(
                            episode: episode,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            onPlay: {
                                selectedEpisode = episode
                                playFromBeginning = false
                                showPlayer = true
                            },
                            onRefreshNeeded: {
                                await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                            },
                            onShowInfo: {
                                navigateToEpisode = episode
                            }
                        )
                        #endif
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 8)  // Room for focus scale effect
                .focusSection()
                .remembersFocus(key: "detailEpisodes", focusedId: $focusedEpisodeId)
                #endif
            }
        }
    }

    // MARK: - Track Section (Albums)

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingTracks {
                ProgressView("Loading tracks...")
            } else if !tracks.isEmpty {
                Text("Tracks")
                    .font(.title2)
                    .fontWeight(.bold)

                LazyVStack(spacing: 12) {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                        #if os(tvOS)
                        AlbumTrackRow(
                            track: track,
                            trackNumber: track.index ?? (index + 1),
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            focusedId: $focusedTrackId,
                            onPlay: {
                                savedTrackFocus = track.ratingKey
                                selectedTrack = track
                                showPlayer = true
                            }
                        )
                        #else
                        AlbumTrackRow(
                            track: track,
                            trackNumber: track.index ?? (index + 1),
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? ""
                        ) {
                            selectedTrack = track
                            showPlayer = true
                        }
                        #endif
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 8)  // Room for focus scale effect
                #endif
            }
        }
    }

    // MARK: - Album Section (Artists)

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingAlbums {
                ProgressView("Loading albums...")
            } else if !albums.isEmpty {
                Text("Albums")
                    .font(.title2)
                    .fontWeight(.bold)

                LazyVStack(spacing: 16) {
                    ForEach(albums, id: \.ratingKey) { album in
                        #if os(tvOS)
                        AlbumRowButton(
                            album: album,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            focusedAlbumId: $focusedAlbumId,
                            onSelect: {
                                savedAlbumFocus = album.ratingKey
                                navigateToAlbum = album
                            }
                        )
                        #else
                        Button {
                            navigateToAlbum = album
                        } label: {
                            ArtistAlbumRow(
                                album: album,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? ""
                            )
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                #if os(tvOS)
                .padding(.horizontal, 8)  // Room for focus scale effect
                .focusSection()
                #endif
            }
        }
    }

    // MARK: - Player Presentation (tvOS)

    #if os(tvOS)
    /// Present player using UIViewController to intercept Menu button
    private func presentPlayer() {
        // Get images and metadata, then present player
        Task {
            // Determine which item to play and fetch full metadata if needed (for DV/HDR detection)
            let playItem: PlexMetadata
            if let episode = selectedEpisode {
                // Fetch full metadata on-demand for episodes (avoids N+1 prefetch - Fixes RIVULET-V)
                if let ratingKey = episode.ratingKey, let fullEpisode = fullEpisodeMetadata[ratingKey] {
                    playItem = fullEpisode
                } else if let ratingKey = episode.ratingKey,
                          let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    // Fetch full metadata now (single request vs N+1 prefetch)
                    do {
                        let metadata = try await networkManager.getFullMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        )
                        fullEpisodeMetadata[ratingKey] = metadata
                        playItem = metadata
                    } catch {
                        // Fall back to basic metadata if fetch fails
                        playItem = episode
                    }
                } else {
                    playItem = episode
                }
            } else if selectedTrack != nil {
                playItem = selectedTrack!
            } else {
                // For main item (movie), prefer fullMetadata as it has Stream data for DV/HDR detection
                playItem = fullMetadata ?? item
            }

            // Use fullMetadata for updated viewOffset when playing the main item (not episodes/tracks)
            let viewOffset = (selectedEpisode == nil && selectedTrack == nil)
                ? (fullMetadata?.viewOffset ?? playItem.viewOffset)
                : playItem.viewOffset
            let resumeOffset = playFromBeginning ? nil : (Double(viewOffset ?? 0) / 1000.0)

            // Get images for loading screen (from cache or fetch if needed)
            let (artImage, thumbImage) = await getPlayerImages(for: playItem)

            await MainActor.run {
                // Create viewModel with cached images for instant loading screen display
                let queue = shuffledEpisodeQueue
                shuffledEpisodeQueue = []

                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                    shuffledQueue: queue,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let inputCoordinator = PlaybackInputCoordinator()

                // Create view with the external viewModel
                let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)

                // Create container that intercepts Menu button, passing the same viewModel
                let container = PlayerContainerViewController(
                    rootView: playerView,
                    viewModel: viewModel,
                    inputCoordinator: inputCoordinator
                )

                // Update SwiftUI state when player is dismissed
                container.onDismiss = { [weak viewModel] in
                    lastPlayedMetadata = viewModel?.metadata
                    showPlayer = false
                }

                // Present from top-most view controller
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(container, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen (from cache or fetch)
    private func getPlayerImages(for metadata: PlexMetadata) async -> (UIImage?, UIImage?) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return (nil, nil) }

        // For episodes, use the show's art (displayed on detail page)
        let art = (metadata.type == "episode" && selectedEpisode != nil) ? currentItem.bestArt : metadata.bestArt
        let thumb = metadata.thumb ?? metadata.bestThumb

        // Build URLs
        let artURL = art.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        let thumbURL = thumb.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }

        // Fetch both images concurrently (from cache or network)
        async let artTask: UIImage? = artURL != nil ? ImageCacheManager.shared.image(for: artURL!) : nil
        async let thumbTask: UIImage? = thumbURL != nil ? ImageCacheManager.shared.image(for: thumbURL!) : nil

        return await (artTask, thumbTask)
    }
    #endif

    // MARK: - Data Loading

    private func loadFullMetadata() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingExtras = true

        // Check in-memory cache first for instant display
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) {
            fullMetadata = cached

            // Pre-warm from cached data immediately
            if cached.type == "movie" || cached.type == "episode" {
                preWarmStreamURL(for: cached, serverURL: serverURL, authToken: token)
                MPVPrewarmService.shared.prewarmIfNeeded(forLiveStream: false)
            }

            // If cache is fresh enough, skip the network request entirely
            if PlexDataStore.shared.isFullMetadataFresh(for: ratingKey) {
                isLoadingExtras = false
                return
            }
        }

        // Fetch from network (either no cache or stale cache)
        do {
            let metadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            fullMetadata = metadata
            PlexDataStore.shared.cacheFullMetadata(metadata, for: ratingKey)

            // Pre-warm stream URL for playable content (movies, episodes)
            // This reduces startup latency when user presses Play
            if metadata.type == "movie" || metadata.type == "episode" {
                preWarmStreamURL(for: metadata, serverURL: serverURL, authToken: token)

                // Pre-warm MPV context (mirrors stream URL pattern)
                // This initializes Vulkan/MoltenVK while user is still on detail view
                MPVPrewarmService.shared.prewarmIfNeeded(forLiveStream: false)
            }
        } catch {
            print("Failed to load full metadata: \(error)")
        }

        isLoadingExtras = false
    }

    /// Fetch the stylized logo image URL from TMDB for the title display
    private func loadShowLogo() async {
        // For shows: use the show's TMDB ID directly
        // For episodes: fetch the parent show's metadata to get its guid/TMDB ID
        // For movies: use the movie's TMDB ID
        let tmdbId: Int?
        let mediaType: TMDBMediaType

        switch currentItem.type {
        case "show":
            mediaType = .tv
            if let id = fullMetadata?.tmdbId ?? currentItem.tmdbId {
                tmdbId = id
            } else {
                tmdbId = await resolveTmdbIdViaTvdb(metadata: fullMetadata ?? currentItem, type: .tv)
            }
        case "episode":
            // Episode metadata doesn't include grandparentGuid, so fetch the show's metadata
            mediaType = .tv
            tmdbId = await resolveShowTmdbId()
        case "movie":
            mediaType = .movie
            if let id = fullMetadata?.tmdbId ?? currentItem.tmdbId {
                tmdbId = id
            } else {
                tmdbId = await resolveTmdbIdViaTvdb(metadata: fullMetadata ?? currentItem, type: .movie)
            }
        default:
            return
        }

        guard let tmdbId else {
            print("🎨 [Logo] No TMDB ID found for \(currentItem.title ?? "?") (type: \(currentItem.type ?? "nil"))")
            return
        }

        print("🎨 [Logo] Fetching logo for TMDB \(mediaType.rawValue)/\(tmdbId) (\(currentItem.title ?? "?"))")
        let url = await TMDBClient.shared.fetchLogoURL(tmdbId: tmdbId, type: mediaType)
        showLogoURL = url
        if let url {
            print("🎨 [Logo] Found: \(url.lastPathComponent)")
        } else {
            print("🎨 [Logo] No logo available")
        }
    }

    /// Resolve the TMDB ID for the parent show of an episode.
    /// Tries grandparentGuid first, then fetches the show's metadata,
    /// and falls back to TVDB→TMDB conversion for legacy Plex agents.
    private func resolveShowTmdbId() async -> Int? {
        // Try extracting from grandparentGuid if available
        if let id = fullMetadata?.showTmdbId ?? currentItem.showTmdbId {
            return id
        }

        // Fetch the show's metadata using grandparentRatingKey
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = fullMetadata?.grandparentRatingKey ?? currentItem.grandparentRatingKey else {
            return nil
        }

        do {
            let showMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            print("🎨 [Logo] Fetched show metadata for \(showMetadata.title ?? "?"), guid: \(showMetadata.guid ?? "nil")")

            // Direct TMDB ID from guid or Guid array
            if let tmdbId = showMetadata.tmdbId {
                return tmdbId
            }

            // Legacy agent: convert TVDB ID → TMDB ID
            if let tvdbId = showMetadata.tvdbId {
                print("🎨 [Logo] Converting TVDB \(tvdbId) → TMDB")
                return await TMDBClient.shared.findTmdbId(tvdbId: tvdbId, type: .tv)
            }

            return nil
        } catch {
            print("🎨 [Logo] Failed to fetch show metadata: \(error)")
            return nil
        }
    }

    /// Convert a TVDB ID to TMDB ID for items using legacy Plex agents
    private func resolveTmdbIdViaTvdb(metadata: PlexMetadata, type: TMDBMediaType) async -> Int? {
        guard let tvdbId = metadata.tvdbId else { return nil }
        print("🎨 [Logo] Converting TVDB \(tvdbId) → TMDB for \(metadata.title ?? "?")")
        return await TMDBClient.shared.findTmdbId(tvdbId: tvdbId, type: type)
    }

    /// Pre-compute and cache stream URL to reduce player startup latency
    private func preWarmStreamURL(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        guard let ratingKey = metadata.ratingKey,
              let partKey = metadata.Media?.first?.Part?.first?.key else { return }

        // Build direct play URL (most common case for MPV)
        if let url = networkManager.buildVLCDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            partKey: partKey
        ) {
            let headers = [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                "X-Plex-Platform": PlexAPI.platform,
                "X-Plex-Device": PlexAPI.deviceName,
                "X-Plex-Product": PlexAPI.productName
            ]
            StreamURLCache.shared.set(ratingKey: ratingKey, url: url, headers: headers)
            Task(priority: .utility) {
                await networkManager.warmDirectPlayStream(url: url, headers: headers)
            }
            print("🎬 [PreWarm] Cached stream URL for \(metadata.title ?? ratingKey)")
        }
    }

    private func loadCollectionItems(sectionId: String, collectionId: String, name: String) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            let items = try await networkManager.getCollectionItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: sectionId,
                collectionId: collectionId,
                excludeRatingKey: currentItem.ratingKey
            )
            collectionItems = items
            collectionName = name
        } catch {
            print("Failed to load collection items: \(error)")
        }
    }

    private func loadRecommendedItems() async {
        do {
            let items = try await recommendationService.recommendationsForItem(item, blendWithHistory: true, limit: 12)
            recommendedItems = items
        } catch {
            print("Failed to load recommended items: \(error)")
        }
    }

    /// Determine the "next up" episode for the Play button on TV shows and seasons
    /// Uses Plex's OnDeck data if available, otherwise falls back to first unwatched episode
    private func loadNextUpEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // For seasons, find the next up episode from the loaded episodes
        if currentItem.type == "season" {
            await loadNextUpEpisodeForSeason()
            return
        }

        guard currentItem.type == "show" else { return }

        // Try to get OnDeck episode from full metadata
        if let onDeckEpisode = fullMetadata?.OnDeck?.Metadata?.first,
           let ratingKey = onDeckEpisode.ratingKey {
            // Fetch full metadata for the episode (includes Stream data for DV detection)
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                // Fall back to the basic OnDeck episode data
                nextUpEpisode = onDeckEpisode
                return
            }
        }

        // No OnDeck episode - search for first in-progress or unwatched episode across all seasons
        for season in seasons {
            guard let seasonRatingKey = season.ratingKey else { continue }

            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )

                // First, look for an in-progress episode in this season
                if let inProgressEpisode = seasonEpisodes.first(where: { $0.isInProgress }),
                   let ratingKey = inProgressEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }

                // Next, look for first unwatched episode in this season
                if let unwatchedEpisode = seasonEpisodes.first(where: { !$0.isWatched }),
                   let ratingKey = unwatchedEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }
            } catch {
                print("Failed to load episodes for season: \(error)")
            }
        }

        // All episodes watched - fall back to first episode of first season
        if let firstSeason = seasons.first,
           let seasonRatingKey = firstSeason.ratingKey {
            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )
                if let firstEpisode = seasonEpisodes.first,
                   let ratingKey = firstEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                }
            } catch {
                print("Failed to load first episode: \(error)")
            }
        }
    }

    /// Determine the "next up" episode for seasons
    /// Finds the first in-progress or unwatched episode, falls back to first episode
    private func loadNextUpEpisodeForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // First, look for an in-progress episode
        if let inProgressEpisode = episodes.first(where: { $0.isInProgress }),
           let ratingKey = inProgressEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = inProgressEpisode
                return
            }
        }

        // Next, look for the first unwatched episode
        if let unwatchedEpisode = episodes.first(where: { !$0.isWatched }),
           let ratingKey = unwatchedEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = unwatchedEpisode
                return
            }
        }

        // All episodes watched - fall back to first episode
        if let firstEpisode = episodes.first,
           let ratingKey = firstEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
            } catch {
                nextUpEpisode = firstEpisode
            }
        }
    }

    private func loadAndPlayTrailer() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let trailer = fullMetadata?.trailer,
              let ratingKey = trailer.ratingKey else { return }

        do {
            // Fetch full metadata for the trailer (includes Media/Part info for playback)
            let metadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            trailerMetadata = metadata
            showTrailerPlayer = true
        } catch {
            print("Failed to load trailer metadata: \(error)")
        }
    }

    private func toggleWatched() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        do {
            if isWatched {
                try await networkManager.markUnwatched(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                isWatched = false
            } else {
                try await networkManager.markWatched(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                // Animate progress bar to 100% before marking as watched
                withAnimation(.easeOut(duration: 0.5)) {
                    displayedProgress = 1.0
                }
                // After animation, mark as watched and hide progress
                try? await Task.sleep(nanoseconds: 500_000_000)
                isWatched = true
            }
            // Notify home screen to refresh Continue Watching
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        } catch {
            print("Failed to toggle watched status: \(error)")
        }
    }

    private func toggleStarRating() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        do {
            // Toggle between 5 stars (rating=10) and no rating (rating=nil)
            let newRating: Int? = isStarred ? nil : 10
            try await networkManager.setRating(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey,
                rating: newRating
            )
            isStarred.toggle()
        } catch {
            print("Failed to toggle star rating: \(error)")
        }
    }

    // MARK: - Episode Navigation

    /// Navigate to the parent season of the current episode
    private func navigateToParentSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let seasonKey = currentItem.parentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let seasonMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: seasonKey
            )
            navigateToSeason = seasonMetadata
        } catch {
            print("Failed to load season metadata: \(error)")
        }
    }

    /// Navigate to the parent show of the current episode
    private func navigateToParentShow() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showKey = currentItem.grandparentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let showMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showKey
            )
            navigateToShow = showMetadata
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    /// Navigate to the parent show from a season (season's parent is the show)
    private func navigateToParentShowFromSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showKey = currentItem.parentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let showMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showKey
            )
            navigateToShow = showMetadata
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    private func loadSeasons() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            seasons = fetchedSeasons

            // Auto-select first season
            if let first = fetchedSeasons.first {
                selectedSeason = first
                await loadEpisodes(for: first)
            }
        } catch {
            print("Failed to load seasons: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load seasons when viewing an episode - displays the parent show's seasons inline
    private func loadSeasonsForEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.grandparentRatingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            // Select the season this episode belongs to
            // Note: We don't set focusedSeasonId here - focus should stay on action buttons
            // The ScrollViewReader will scroll the season into view when user navigates down
            if let currentSeasonKey = currentItem.parentRatingKey,
               let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
                await loadEpisodes(for: currentSeason)
            } else if let first = fetchedSeasons.first {
                // Fallback to first season
                selectedSeason = first
                await loadEpisodes(for: first)
            }
        } catch {
            print("Failed to load seasons for episode: \(error)")
        }

        isLoadingSeasons = false
    }

    private func loadEpisodes(for season: PlexMetadata) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = season.ratingKey else { return }

        isLoadingEpisodes = true

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            episodes = fetchedEpisodes
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes when viewing a season directly
    private func loadEpisodesForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingEpisodes = true

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            episodes = fetchedEpisodes
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes for season: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Refresh a single episode's watch status without reloading the entire list
    /// This preserves focus position in the episode list
    private func refreshEpisodeWatchStatus(ratingKey: String?) async {
        guard let ratingKey = ratingKey,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            // Fetch fresh metadata for just this episode
            let updatedMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            // Update the episode in place
            if let index = episodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                episodes[index].viewCount = updatedMetadata.viewCount
                episodes[index].viewOffset = updatedMetadata.viewOffset
            }

            // Also update prefetched metadata
            fullEpisodeMetadata[ratingKey] = updatedMetadata
        } catch {
            print("Failed to refresh episode watch status: \(error)")
        }
    }


    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingTracks = true

        do {
            let fetchedTracks = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            tracks = fetchedTracks
        } catch {
            print("Failed to load tracks: \(error)")
        }

        isLoadingTracks = false
    }

    private func loadAlbums() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else {
            print("🎵 Missing required data for loading albums")
            return
        }

        // Get librarySectionID from fullMetadata (fetched first) or item
        guard let librarySectionId = fullMetadata?.librarySectionID ?? currentItem.librarySectionID else {
            print("🎵 Missing librarySectionID for artist - item: \(currentItem.librarySectionID ?? -1), fullMetadata: \(fullMetadata?.librarySectionID ?? -1)")
            return
        }

        isLoadingAlbums = true

        do {
            // Use the library section endpoint with artist.id filter
            // This is more reliable than /children endpoint
            let fetchedAlbums = try await networkManager.getAlbumsForArtist(
                serverURL: serverURL,
                authToken: token,
                librarySectionId: librarySectionId,
                artistId: ratingKey
            )

            // Sort by year (newest first)
            albums = fetchedAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }

            print("🎵 Found \(albums.count) albums for \(currentItem.title ?? "?")")
            for album in albums.prefix(5) {
                print("  - \(album.title ?? "?") (type: \(album.type ?? "nil"), ratingKey: \(album.ratingKey ?? "nil"), parentKey: \(album.parentRatingKey ?? "nil"))")
            }
            if albums.count > 5 {
                print("  ... and \(albums.count - 5) more")
            }
        } catch {
            print("🎵 Failed to load albums: \(error)")
        }

        isLoadingAlbums = false
    }


    // MARK: - URL Helpers

    private var artURL: URL? {
        guard let art = currentItem.bestArt,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(art)?X-Plex-Token=\(token)")
    }

    /// Poster URL - uses grandparent poster for episodes (series poster)
    private var posterURL: URL? {
        let thumb: String?

        // For TV show episodes, prefer the series poster (grandparentThumb)
        if currentItem.type == "episode" || currentItem.type == "season" {
            thumb = currentItem.grandparentThumb ?? currentItem.parentThumb ?? currentItem.thumb
        } else {
            thumb = currentItem.thumb
        }

        guard let thumbPath = thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(token)")
    }

    private var thumbURL: URL? {
        guard let thumb = currentItem.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }
}

// MARK: - Season/Episode Split Pane (tvOS)

#if os(tvOS)

/// Text-based season row for the left pane of the split layout
struct SeasonListRow: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onSelect: (() -> Void)?
    @FocusState.Binding var focusedSeasonId: String?

    @FocusState private var isFocused: Bool

    /// Season is fully watched when all episodes have been viewed
    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    private var seasonLabel: String {
        if let index = season.index {
            return String(format: "Season %02d", index)
        }
        return season.title ?? "Season"
    }

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(seasonLabel)
                        .font(.system(size: 30, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if let leafCount = season.leafCount {
                        Text("\(leafCount) episodes")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer(minLength: 4)

                // Fully-watched checkmark
                if isFullyWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 22))
                }

                // Selected indicator dot
                if isSelected {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
            }
            .foregroundStyle(.white.opacity(isFocused || isSelected ? 1.0 : 0.6))
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : isSelected ? .white.opacity(0.10) : .white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .focused($focusedSeasonId, equals: season.ratingKey)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .mediaItemContextMenu(
            item: season,
            serverURL: serverURL,
            authToken: authToken,
            onRefreshNeeded: onRefreshNeeded
        )
    }
}

/// Episode list pane for multi-season shows.
/// Seasons are rendered as a pinned overlay at the PlexDetailView level.
struct SeasonEpisodeSplitPane: View {
    @Binding var selectedSeason: PlexMetadata?
    let episodes: [PlexMetadata]
    let isLoadingEpisodes: Bool
    var currentItemRatingKey: String?
    var currentItemType: String?
    let serverURL: String
    let authToken: String
    let onEpisodePlay: (PlexMetadata) -> Void
    let onEpisodeRefresh: (String?) async -> Void
    let onEpisodeShowInfo: (PlexMetadata) -> Void
    @Binding var isEpisodeFocused: Bool

    @FocusState private var focusedEpisodeId: String?
    @Namespace private var episodePaneNamespace

    @State private var episodeListOpacity: Double = 1

    /// Entry focus target: first episode is guaranteed to be materialized in LazyVStack.
    private var entryEpisodeRatingKey: String? {
        if currentItemType == "episode",
           let currentItemRatingKey,
           episodes.contains(where: { $0.ratingKey == currentItemRatingKey }) {
            return currentItemRatingKey
        }
        return episodes.first?.ratingKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            episodeListContent
                .opacity(episodeListOpacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusScope(episodePaneNamespace)
        .onAppear {
            isEpisodeFocused = false
        }
        .onChange(of: focusedEpisodeId) { _, newId in
            isEpisodeFocused = newId != nil
        }
        .onChange(of: episodes) { _, _ in
            // New episodes loaded — crossfade in
            withAnimation(.easeIn(duration: 0.3)) {
                episodeListOpacity = 1
            }
        }
        .onChange(of: selectedSeason) { _, _ in
            // Season changed — fade out episode list for crossfade
            FocusMemory.shared.forget(key: "splitEpisodes")
            withAnimation(.easeOut(duration: 0.2)) {
                episodeListOpacity = 0
            }
        }
    }

    @ViewBuilder
    private var episodeListContent: some View {
        let episodeCount = selectedSeason?.leafCount ?? 0
        if isLoadingEpisodes && episodeCount > 0 {
            LazyVStack(spacing: 16) {
                ForEach(0..<episodeCount, id: \.self) { index in
                    SkeletonEpisodeRow(episodeNumber: index + 1)
                }
            }
            .padding(.horizontal, 8)
        } else if isLoadingEpisodes {
            ProgressView("Loading episodes...")
                .padding(.top, 20)
        } else if !episodes.isEmpty {
            LazyVStack(spacing: 16) {
                let defaultEpisodeRatingKey = entryEpisodeRatingKey
                ForEach(episodes, id: \.ratingKey) { episode in
                    let isCurrentEpisode = currentItemType == "episode" && episode.ratingKey == currentItemRatingKey
                    EpisodeRow(
                        episode: episode,
                        serverURL: serverURL,
                        authToken: authToken,
                        isCurrent: isCurrentEpisode,
                        focusedEpisodeId: $focusedEpisodeId,
                        onPlay: { onEpisodePlay(episode) },
                        onRefreshNeeded: { await onEpisodeRefresh(episode.ratingKey) },
                        onShowInfo: { onEpisodeShowInfo(episode) }
                    )
                    .prefersDefaultFocus(defaultEpisodeRatingKey == episode.ratingKey, in: episodePaneNamespace)
                }
            }
            .padding(.horizontal, 8)
            .focusSection()
            .remembersFocus(key: "splitEpisodes", focusedId: $focusedEpisodeId)
        }
    }

}

#endif

// MARK: - Season Poster Card

struct SeasonPosterCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    #if os(tvOS)
    var focusedSeasonId: FocusState<String?>.Binding?
    #endif
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    #if os(tvOS)
    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }
    #else
    private let posterWidth: CGFloat = 140
    private let posterHeight: CGFloat = 210
    private let cornerRadius: CGFloat = 12
    private let titleSize: CGFloat = 15
    private let subtitleSize: CGFloat = 13
    #endif

    /// Season is fully watched when all episodes have been viewed
    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 12) {
                // Season poster - structure matches MediaPosterCard
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        // Watched indicator (corner triangle tag) - inside clipShape so it curves
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    #if os(tvOS)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .hoverEffect(.highlight)  // Native tvOS focus effect - scales poster AND badge
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .padding(.bottom, 10)  // Space for hover scale effect
                    #else
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                    )
                    #endif

                // Season label
                VStack(spacing: 4) {
                    Text(seasonLabel)
                        .font(.system(size: titleSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    if let leafCount = season.leafCount {
                        Text("\(leafCount) episodes")
                            .font(.system(size: subtitleSize))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        #if os(tvOS)
        .buttonStyle(CardButtonStyle())
        .modifier(SeasonFocusModifier(focusedSeasonId: focusedSeasonId, seasonRatingKey: season.ratingKey))
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var seasonLabel: String {
        // Format as "Season 01", "Season 02", etc.
        if let index = season.index {
            return String(format: "Season %02d", index)
        }
        return season.title ?? "Season"
    }

    private var posterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var posterURL: URL? {
        guard let thumb = season.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var isCurrent: Bool = false  // Indicates this is the episode currently being viewed
    #if os(tvOS)
    var focusedEpisodeId: FocusState<String?>.Binding?
    #endif
    let onPlay: () -> Void
    var onPlayFromBeginning: (() -> Void)? = nil
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Thumbnail
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                #if os(tvOS)
                .frame(width: 240, height: 135)
                #else
                .frame(width: 200, height: 112)
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.5))
                                        .frame(height: 3)
                                    Rectangle()
                                        .fill(Color.blue)
                                        .frame(width: geo.size.width * progress, height: 3)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    if let epString = episode.episodeString {
                        Text(epString)
                            #if os(tvOS)
                            .font(.system(size: 26))
                            #else
                            .font(.caption)
                            #endif
                            .foregroundStyle(.secondary)
                    }

                    Text(episode.title ?? "Episode")
                        #if os(tvOS)
                        .font(.system(size: 30, weight: .medium))
                        #else
                        .font(.headline)
                        #endif
                        .lineLimit(1)

                    if let duration = episode.durationFormatted {
                        Text(duration)
                            #if os(tvOS)
                            .font(.system(size: 26))
                            #else
                            .font(.caption)
                            #endif
                            .foregroundStyle(.secondary)
                    }

                    if let summary = episode.summary {
                        Text(summary)
                            #if os(tvOS)
                            .font(.system(size: 26))
                            #else
                            .font(.caption)
                            #endif
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Current episode indicator (when viewing episode detail)
                if isCurrent {
                    Text("VIEWING")
                        #if os(tvOS)
                        .font(.system(size: 16, weight: .semibold))
                        #else
                        .font(.caption2)
                        .fontWeight(.semibold)
                        #endif
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.blue)
                        )
                }

                // Watched indicator
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        #if os(tvOS)
                        .font(.system(size: 24))
                        #endif
                }
            }
            #if os(tvOS)
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            #else
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
            )
            #endif
        }
        #if os(tvOS)
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        #else
        .buttonStyle(.plain)
        #endif
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

#if os(tvOS)
/// Helper modifier to apply focus binding to episode rows
struct EpisodeFocusModifier: ViewModifier {
    var focusedEpisodeId: FocusState<String?>.Binding?
    let episodeRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedEpisodeId, let key = episodeRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}
#endif

// MARK: - Skeleton Episode Row

/// Loading placeholder for episode rows - shows while fetching episode data
struct SkeletonEpisodeRow: View {
    let episodeNumber: Int

    var body: some View {
        HStack(spacing: 16) {
            // Placeholder thumbnail
            Rectangle()
                .fill(Color(white: 0.15))
                #if os(tvOS)
                .frame(width: 240, height: 135)
                #else
                .frame(width: 200, height: 112)
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.3))
                }

            VStack(alignment: .leading, spacing: 5) {
                // Episode number placeholder
                Text("Episode \(episodeNumber)")
                    #if os(tvOS)
                    .font(.system(size: 22))
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.white.opacity(0.3))

                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    #if os(tvOS)
                    .frame(width: 220, height: 26)
                    #else
                    .frame(width: 150, height: 18)
                    #endif

                // Duration placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    #if os(tvOS)
                    .frame(width: 90, height: 22)
                    #else
                    .frame(width: 60, height: 14)
                    #endif
            }

            Spacer()
        }
        #if os(tvOS)
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
        )
        #else
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.05))
        )
        #endif
    }
}

// MARK: - Album Track Row

struct AlbumTrackRow: View {
    let track: PlexMetadata
    let trackNumber: Int
    let serverURL: String
    let authToken: String
    #if os(tvOS)
    var focusedId: FocusState<String?>.Binding?
    @FocusState private var isFocused: Bool
    #endif
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Track number
                Text("\(trackNumber)")
                    #if os(tvOS)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    #else
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    #endif
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title ?? "Track \(trackNumber)")
                        #if os(tvOS)
                        .font(.system(size: 22, weight: .medium))
                        #else
                        .font(.headline)
                        #endif
                        .lineLimit(1)

                    if let duration = track.durationFormatted {
                        Text(duration)
                            #if os(tvOS)
                            .font(.system(size: 18))
                            #else
                            .font(.caption)
                            #endif
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            #if os(tvOS)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            #else
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
            )
            #endif
        }
        #if os(tvOS)
        .buttonStyle(CardButtonStyle())
        .modifier(TrackFocusModifier(focusedId: focusedId, trackRatingKey: track.ratingKey))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
/// Helper view for album rows with proper focus tracking
struct AlbumRowButton: View {
    let album: PlexMetadata
    let serverURL: String
    let authToken: String
    var focusedAlbumId: FocusState<String?>.Binding
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            ArtistAlbumRow(
                album: album,
                serverURL: serverURL,
                authToken: authToken,
                isFocused: isFocused
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .focused(focusedAlbumId, equals: album.ratingKey)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Helper modifier to apply focus binding to track rows
struct TrackFocusModifier: ViewModifier {
    var focusedId: FocusState<String?>.Binding?
    let trackRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedId, let key = trackRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

/// Helper modifier to apply focus binding to season cards
struct SeasonFocusModifier: ViewModifier {
    var focusedSeasonId: FocusState<String?>.Binding?
    let seasonRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedSeasonId, let key = seasonRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}
#endif

// MARK: - Artist Album Row

struct ArtistAlbumRow: View {
    let album: PlexMetadata
    let serverURL: String
    let authToken: String
    #if os(tvOS)
    var isFocused: Bool = false
    #endif

    var body: some View {
        HStack(spacing: 16) {
            // Album artwork (square)
            CachedAsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay { ProgressView().tint(.white.opacity(0.3)) }
                case .failure:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                }
            }
            #if os(tvOS)
            .frame(width: 80, height: 80)
            #else
            .frame(width: 60, height: 60)
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title ?? "Unknown Album")
                    #if os(tvOS)
                    .font(.system(size: 22, weight: .medium))
                    #else
                    .font(.headline)
                    #endif
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let year = album.year {
                        Text(String(year))
                    }
                    if let trackCount = album.leafCount {
                        Text("\(trackCount) tracks")
                    }
                }
                #if os(tvOS)
                .font(.system(size: 18))
                #else
                .font(.caption)
                #endif
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        #if os(tvOS)
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
        #else
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
        )
        #endif
    }

    private var thumbURL: URL? {
        guard let thumb = album.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Artist Bio Sheet

struct ArtistBioSheet: View {
    let artistName: String
    let bio: String
    let thumbURL: URL?

    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    @FocusState private var focusedParagraph: Int?

    /// Split bio into small chunks for smooth scrolling
    /// Each chunk is ~2-3 sentences or ~300 chars max for comfortable reading
    private var bioChunks: [String] {
        let sentences = bio.components(separatedBy: ". ")
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let sentenceWithPeriod = trimmed.hasSuffix(".") ? trimmed : trimmed + "."

            if currentChunk.isEmpty {
                currentChunk = sentenceWithPeriod
            } else if currentChunk.count + sentenceWithPeriod.count < 300 {
                // Add to current chunk if under limit
                currentChunk += " " + sentenceWithPeriod
            } else {
                // Start new chunk
                chunks.append(currentChunk)
                currentChunk = sentenceWithPeriod
            }
        }

        // Add remaining chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks.isEmpty ? [bio] : chunks
    }
    #endif

    var body: some View {
        #if os(tvOS)
        // tvOS: Scrollable view with focusable paragraphs
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 40) {
                // Header with artist name
                Text(artistName)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 60)

                // Artist image
                if let url = thumbURL {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .empty:
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .overlay { ProgressView().tint(.white.opacity(0.3)) }
                        case .failure:
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .overlay {
                                    Image(systemName: "music.mic")
                                        .font(.system(size: 40, weight: .light))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                        }
                    }
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                }

                // Bio text - split into small focusable chunks for smooth scrolling
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(bioChunks.enumerated()), id: \.offset) { index, chunk in
                        BioParagraphRow(
                            text: chunk,
                            isFocused: focusedParagraph == index
                        )
                        .focusable()
                        .focused($focusedParagraph, equals: index)
                    }
                }
                .frame(maxWidth: 1200)
                .padding(.horizontal, 80)

                // Done button at bottom (index = -1)
                BioDoneButton(isFocused: focusedParagraph == -1) {
                    dismiss()
                }
                .focused($focusedParagraph, equals: -1)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
            .padding(8) // Room for scale effect
        }
        .background(Color(white: 0.12))
        .onExitCommand {
            dismiss()
        }
        #else
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 32) {
                    // Artist image
                    if let url = thumbURL {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .empty:
                                Rectangle()
                                    .fill(Color(white: 0.15))
                                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
                            case .failure:
                                Rectangle()
                                    .fill(Color(white: 0.15))
                                    .overlay {
                                        Image(systemName: "music.mic")
                                            .font(.system(size: 40, weight: .light))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                            }
                        }
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                    }

                    // Bio text
                    Text(bio)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(6)
                }
                .padding()
            }
            .background(Color(white: 0.12))
            .navigationTitle(artistName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #endif
    }
}

// MARK: - Bio Sheet Helper Views (tvOS)

#if os(tvOS)
/// Focusable text chunk - minimal styling for continuous reading
private struct BioParagraphRow: View {
    let text: String
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Subtle focus indicator on the left edge
            RoundedRectangle(cornerRadius: 2)
                .fill(isFocused ? .white.opacity(0.6) : .clear)
                .frame(width: 3)

            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.8))
                .multilineTextAlignment(.leading)
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Done button for bio sheet - follows design guide glass styling
private struct BioDoneButton: View {
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 60)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
#endif

// MARK: - Player View Wrapper (non-tvOS)

#if !os(tvOS)
/// Wraps UniversalPlayerView to capture the viewModel's final metadata on dismiss,
/// enabling auto-play episode tracking back to the detail view.
private struct PlayerViewWrapper: View {
    @StateObject private var viewModel: UniversalPlayerViewModel
    @Binding var lastPlayedMetadata: PlexMetadata?

    init(playItem: PlexMetadata, startOffset: TimeInterval?, lastPlayedMetadata: Binding<PlexMetadata?>) {
        let authManager = PlexAuthManager.shared
        _viewModel = StateObject(wrappedValue: UniversalPlayerViewModel(
            metadata: playItem,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            startOffset: startOffset
        ))
        _lastPlayedMetadata = lastPlayedMetadata
    }

    var body: some View {
        UniversalPlayerView(viewModel: viewModel)
            .onDisappear {
                lastPlayedMetadata = viewModel.metadata
            }
    }
}
#endif

#Preview {
    let sampleMovie = PlexMetadata(
        ratingKey: "123",
        key: "/library/metadata/123",
        type: "movie",
        title: "Sample Movie",
        contentRating: "PG-13",
        summary: "This is a sample movie summary that describes the plot and gives viewers an idea of what to expect.",
        tagline: "An epic adventure awaits",
        year: 2024,
        duration: 7200000 // 2 hours
    )

    PlexDetailView(item: sampleMovie)
}
