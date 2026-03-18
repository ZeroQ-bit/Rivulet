//
//  PlexDetailView.swift
//  Rivulet
//
//  Detail view for movies and TV shows with playback options
//

import SwiftUI

enum PlexDetailPresentationMode: Equatable {
    case previewCarousel
    case expandedDetail
}

struct PlexDetailView: View {
    let item: PlexMetadata
    var presentationMode: PlexDetailPresentationMode = .expandedDetail
    var backgroundParallaxOffset: CGFloat = 0
    var showMetadata: Bool = true
    var showExpandedChrome: Bool = true
    var allowVerticalScroll: Bool = true
    var allowActionRowInteraction: Bool = true
    var heroBackdropMotionLocked: Bool = false
    var onPreviewExitRequested: (() -> Void)? = nil
    var onDetailsBecameVisible: (() -> Void)? = nil

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
    @Environment(\.previewMenuBridge) private var menuBridge
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

    // Focus state for restoring focus when returning from nested navigation
    @FocusState private var focusedAlbumId: String?
    @FocusState private var focusedTrackId: String?
    @FocusState private var focusedEpisodeId: String?  // Track focused episode
    @FocusState private var focusedActionButton: String?  // Track focused action button
    @State private var savedAlbumFocus: String?  // Save focus when navigating to album
    @State private var savedTrackFocus: String?  // Save focus when playing track
    @State private var isSummaryExpanded = false  // Expand summary text on focus/click

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
    @StateObject private var heroBackdrop = HeroBackdropCoordinator()
    @State private var scrollProgress: CGFloat = 0  // 0 = at rest (peek), 1 = fully scrolled
    @State private var scrollResetID = UUID()

    // Navigation state for episode parent navigation
    @State private var navigateToSeason: PlexMetadata?
    @State private var navigateToShow: PlexMetadata?
    @State private var navigateToEpisode: PlexMetadata?
    @State private var isLoadingNavigation = false

    // Unified episode list state (all seasons in one scroll)
    @State private var unifiedEpisodes: [PlexMetadata] = []
    @State private var episodeScrollTarget: String? = nil
    @State private var scrollToTopTrigger = false

    private let networkManager = PlexNetworkManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared
    private var isPreviewCarousel: Bool { presentationMode == .previewCarousel }
    private var isExpandedPreviewFlow: Bool { onPreviewExitRequested != nil && presentationMode == .expandedDetail }
    private let heroOverlayHorizontalInset: CGFloat = 60

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
        GeometryReader { geo in
            let heroHeight = heroContentHeight(for: geo.size.height)
            ZStack {
                // Layer 1: Fixed backdrop (doesn't scroll, fills screen)
                heroBackdropImage
                    .offset(x: backgroundParallaxOffset)
                    .scaleEffect(1.04)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay {
                        Rectangle()
                            .fill(.regularMaterial)
                            .opacity(scrollProgress)
                    }

                // Fixed vignette for text readability (doesn't scroll)
                RadialGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.3),
                        .black.opacity(0.7),
                    ],
                    center: .center,
                    startRadius: geo.size.width * 0.25,
                    endRadius: geo.size.width * 0.75
                )
                .opacity(showMetadata ? 1 : 0)
                .animation(.easeInOut(duration: 0.7), value: showMetadata)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Bottom gradient for metadata text readability
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.4), location: 0.25),
                        .init(color: .black.opacity(0.75), location: 0.55),
                        .init(color: .black.opacity(0.9), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(showMetadata ? 1 : 0)
                .animation(.easeInOut(duration: 0.7), value: showMetadata)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Layer 2: All scrollable content in one continuous flow
                ScrollViewReader { verticalProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Metadata pinned near bottom of visible area
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            heroMetadataOverlay
                                .padding(.horizontal, heroOverlayHorizontalInset)
                                .opacity(showMetadata ? (1 - scrollProgress) : 0)
                        }
                        .frame(height: heroHeight)
                        .id("scrollTop")

                        // Below-fold page: ZStack decouples min height from content layout.
                        // Color.clear sets the height floor; the VStack sits on top
                        // at its natural size so no extra space leaks into children.
                        ZStack(alignment: .topLeading) {
                            // Invisible rect guarantees at least one screen of scroll room
                            Color.clear.frame(height: geo.size.height)

                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 32) {
                                    // TV Show specific: Seasons and Episodes
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
                                .padding(.top, belowFoldHeaderReserveHeight)
                                .padding(.horizontal, 48)
                                .allowsHitTesting(!isPreviewCarousel)

                                // Recommended / Related Section
                                if !recommendedItems.isEmpty {
                                    MediaItemRow(
                                        title: "Related",
                                        items: recommendedItems,
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? "",
                                        onItemSelected: { selectedItem in
                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                displayedItem = selectedItem
                                            }
                                        }
                                    )
                                    .padding(.top, 32)
                                }

                                // Collection Section (for movies that are part of a collection)
                                if !collectionItems.isEmpty, let name = collectionName {
                                    MediaItemRow(
                                        title: name,
                                        items: collectionItems,
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? "",
                                        onItemSelected: { selectedItem in
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
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            belowFoldTitleLogo
                                .frame(height: 110)
                                .padding(.top, 40)
                                .padding(.bottom, 8)
                                .opacity(scrollProgress)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > 10
                } action: { _, isScrolled in
                    withAnimation(.easeInOut(duration: 0.7)) {
                        scrollProgress = isScrolled ? 1 : 0
                    }
                    if isScrolled {
                        onDetailsBecameVisible?()
                    }
                }
                .id(scrollResetID)
                .scrollDisabled(isPreviewCarousel || !allowVerticalScroll)
                .defaultScrollAnchor(.top)
                .onChange(of: scrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        verticalProxy.scrollTo("scrollTop", anchor: .top)
                    }
                }
                } // ScrollViewReader
            }
        }
        .ignoresSafeArea()
        .task(id: currentItem.ratingKey) {
            // Reset state for new item
            seasons = []
            episodes = []
            selectedSeason = nil
            unifiedEpisodes = []
            episodeScrollTarget = nil
            fullMetadata = nil
            collectionItems = []
            collectionName = nil
            recommendedItems = []
            nextUpEpisode = nil
            isSummaryExpanded = false
            scrollProgress = 0
            syncHeroBackdrop()

            // Initialize watched state
            isWatched = currentItem.isWatched

            // Initialize progress for animation
            displayedProgress = currentItem.watchProgress ?? 0

            // Initialize starred state for music (userRating > 0 means starred)
            isStarred = (currentItem.userRating ?? 0) > 0

            // Load full metadata for cast/crew and trailer
            await loadFullMetadata()

            // Refresh hero art/logo with the best TMDB/TVDB data now that metadata is loaded.
            await refreshHeroBackdropAssets()

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
                await loadAllEpisodes()
                await loadNextUpEpisode()
            }

            // Load episodes for seasons
            if currentItem.type == "season" {
                await loadSeasonsForCurrentSeason()
                await loadEpisodesForSeason()
                // Determine the "next up" episode for the Play button
                await loadNextUpEpisode()
            }

            // Load seasons for episodes (show parent show's seasons inline)
            if currentItem.type == "episode" {
                await loadSeasonsForEpisode()
                await loadAllEpisodes()
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
        .onChange(of: presentationMode) { _, newMode in
            if newMode == .previewCarousel {
                displayedItem = nil
                focusedActionButton = nil
                scrollProgress = 0
                scrollResetID = UUID()
            }
        }
        .onChange(of: heroBackdropMotionLocked) { _, locked in
            heroBackdrop.setMotionLocked(locked)
        }
        .onChange(of: showExpandedChrome) { _, isVisible in
            guard isVisible, isExpandedPreviewFlow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                focusedActionButton = "play"
            }
        }
        .onChange(of: focusedEpisodeId) { _, newId in
            // Sync season pill when user navigates across season boundary
            guard let newId,
                  let episode = unifiedEpisodes.first(where: { $0.ratingKey == newId }),
                  episode.parentRatingKey != selectedSeason?.ratingKey,
                  let newSeason = seasons.first(where: { $0.ratingKey == episode.parentRatingKey }) else { return }
            selectedSeason = newSeason
        }
        .onAppear {
            guard isExpandedPreviewFlow, let bridge = menuBridge else { return }
            bridge.interceptHandler = { [self] in
                if navigateToAlbum != nil {
                    navigateToAlbum = nil
                    return true
                } else if navigateToSeason != nil {
                    navigateToSeason = nil
                    return true
                } else if navigateToShow != nil {
                    navigateToShow = nil
                    return true
                } else if navigateToEpisode != nil {
                    navigateToEpisode = nil
                    return true
                } else if scrollProgress > 0 || focusedEpisodeId != nil {
                    scrollToTopTrigger.toggle()
                    focusedEpisodeId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedActionButton = "play"
                    }
                    return true
                }
                return false
            }
        }
        .onDisappear {
            guard isExpandedPreviewFlow else { return }
            menuBridge?.interceptHandler = nil
        }
        .onChange(of: showPlayer) { _, shouldShow in
            if shouldShow {
                presentPlayer()
            }
        }
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
                    if currentItem.type == "show" {
                        await loadAllEpisodes()
                        await loadNextUpEpisode()
                    } else if currentItem.type == "season" {
                        await loadEpisodesForSeason()
                        await loadNextUpEpisode()
                    }
                }
            }
        }
        // Navigation destinations only in standard flow (not preview overlay — no NavigationStack there)
        .modifier(NavigationDestinationsModifier(
            navigateToAlbum: $navigateToAlbum,
            navigateToSeason: $navigateToSeason,
            navigateToShow: $navigateToShow,
            navigateToEpisode: $navigateToEpisode,
            isEnabled: onPreviewExitRequested == nil
        ))
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
            // Restore focus when returning from album
            if oldAlbum != nil && newAlbum == nil, let savedFocus = savedAlbumFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedAlbumId = savedFocus
                }
            }
        }
        // Restore track focus when returning from player
        .onChange(of: showPlayer) { wasPlaying, isPlaying in
            if wasPlaying && !isPlaying, let savedFocus = savedTrackFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedTrackId = savedFocus
                }
            }
        }
    }

    private func heroContentHeight(for fullHeight: CGFloat) -> CGFloat {
        let shelfPeek: CGFloat
        switch currentItem.type {
        case "show", "episode":
            // Keep the real shelf visible, but only as a shallow tease.
            shelfPeek = 136
        default:
            shelfPeek = 220
        }

        return max(0, fullHeight - shelfPeek)
    }

    private var belowFoldHeaderReserveHeight: CGFloat {
        158 * scrollProgress
    }

    // MARK: - Hero Components (Apple TV+ style — backdrop fixed, content scrolls over)

    /// Fixed backdrop image (behind everything, doesn't scroll)
    private var heroBackdropImage: some View {
        HeroBackdropImage(
            url: heroBackdrop.session.displayedBackdropURL,
            animationDuration: isPreviewCarousel ? 0.3 : 0.26
        ) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .animation(.easeOut(duration: isPreviewCarousel ? 0.42 : 0.48), value: backgroundParallaxOffset)
    }

    /// Gradient overlay for hero text readability (scrolls with content)
    private var heroGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.5), location: 0.55),
                .init(color: .black.opacity(0.85), location: 0.75),
                .init(color: .black, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Metadata overlay (title, genres, quality, buttons, cast) positioned at bottom of hero
    private var heroMetadataOverlay: some View {
        GeometryReader { metaGeo in
            VStack(alignment: .leading, spacing: 10) {
                Spacer()

                // Text content — fixed height so buttons/peek distance
                // stays constant regardless of description length, logo vs title, etc.
                VStack(alignment: .leading, spacing: 10) {
                    // TMDB logo or title — fixed height so content below is always
                    // at the same position regardless of logo aspect ratio
                    Group {
                        if let logoURL = heroBackdrop.session.logoURL {
                            CachedAsyncImage(url: logoURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .shadow(color: .black.opacity(0.8), radius: 20, x: 0, y: 4)
                                default:
                                    heroTitleText
                                }
                            }
                        } else {
                            heroTitleText
                        }
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(height: 112, alignment: .bottomLeading)

                    // Genre + content rating row
                    heroMetadataRow

                    // Description area
                    VStack(alignment: .leading, spacing: 4) {
                        if currentItem.type == "episode" {
                            if let epString = currentItem.episodeString {
                                let title = currentItem.title ?? ""
                                let header = epString + (title.isEmpty ? "" : " · \(title)")
                                let desc = fullMetadata?.summary ?? currentItem.summary ?? ""
                                (Text(header).bold() + Text(desc.isEmpty ? "" : ":  \(desc)"))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .lineLimit(4)
                            }
                        } else if currentItem.type == "show" || currentItem.type == "season" {
                            if let tagline = fullMetadata?.tagline ?? currentItem.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(4)
                            }
                        } else {
                            if let tagline = fullMetadata?.tagline ?? currentItem.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            } else if let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(4)
                            }
                        }
                    }

                    // Year · Duration · Quality badges
                    heroQualityRow

                    // Up Next caption
                    if let caption = upNextCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 392, alignment: .bottomLeading)
                .frame(maxWidth: 760, alignment: .leading)

                // Bottom row: buttons (left) + starring (right) — full width
                // Always in tree to avoid layout shift; opacity-controlled
                HStack(alignment: .bottom, spacing: 0) {
                    actionButtons
                        .onMoveCommand { direction in
                            if direction == .up,
                               isExpandedPreviewFlow,
                               scrollProgress == 0 {
                                onPreviewExitRequested?()
                            }
                        }

                    Spacer(minLength: 40)

                    // Starring (comma-separated, right-aligned)
                    if let roles = (fullMetadata ?? currentItem).Role, !roles.isEmpty {
                        let topCast = roles.prefix(5).compactMap { $0.tag }
                        if !topCast.isEmpty {
                            Text("Starring \(topCast.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 700, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 24)
                .opacity(showMetadata ? 1 : 0)
                .allowsHitTesting(allowActionRowInteraction)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentItem.ratingKey)
        .animation(.easeInOut(duration: 0.22), value: showMetadata)
    }

    // MARK: - Below-fold Title Logo (centered, Apple TV+ style)

    private var belowFoldTitleLogo: some View {
        Group {
            if let logoURL = heroBackdrop.session.logoURL {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        Text(fullMetadata?.title ?? currentItem.title ?? "")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: 680, maxHeight: 126)
            } else {
                Text(fullMetadata?.title ?? currentItem.title ?? "")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Hero Sub-components

    private var heroTitleText: some View {
        Text(fullMetadata?.title ?? currentItem.title ?? "Unknown Title")
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    /// Genre tags + content rating badge
    private var heroMetadataRow: some View {
        HStack(spacing: 10) {
            // Type label for non-obvious types
            if currentItem.type == "show" {
                Text("Series")
            }

            // Genres (up to 3)
            if let genres = (fullMetadata ?? currentItem).Genre?.prefix(3) {
                ForEach(Array(genres), id: \.id) { genre in
                    if let tag = genre.tag {
                        Text(tag)
                    }
                }
            }

            // Content rating badge
            if let contentRating = fullMetadata?.contentRating ?? currentItem.contentRating {
                Text(contentRating)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    /// Year, duration, quality badges row
    private var heroQualityRow: some View {
        HStack(spacing: 10) {
            if let year = fullMetadata?.year ?? currentItem.year {
                Text(String(year))
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

            // Quality badges
            if let videoQuality = fullMetadata?.videoQualityDisplay ?? currentItem.videoQualityDisplay {
                QualityBadge(text: videoQuality)
            }
            if let hdrFormat = fullMetadata?.hdrFormatDisplay ?? currentItem.hdrFormatDisplay {
                QualityBadge(text: hdrFormat)
            }
            if let audioFormat = fullMetadata?.audioFormatDisplay ?? currentItem.audioFormatDisplay {
                QualityBadge(text: audioFormat)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
    }

    /// Small badge for quality indicators (4K, DV, Atmos, etc.)
    private struct QualityBadge: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.15))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 0.5)
                }
        }
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

    // MARK: - Summary Section (Full, below fold)

    @ViewBuilder
    private func fullSummarySection(summary: String) -> some View {
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

    // MARK: - Action Buttons (Apple TV+ style)

    private let pillButtonHeight: CGFloat = 58
    private let circleButtonSize: CGFloat = 58

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Primary play button with inline progress + time remaining
            if currentItem.type == "artist" {
                Button {
                    Task { await playAllArtistTracks() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingArtistTracks {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Play All")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 28)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(isLoadingArtistTracks)
            } else if currentItem.type == "album" {
                Button {
                    if let firstTrack = tracks.first { selectedTrack = firstTrack }
                    showPlayer = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Play Album")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 28)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(tracks.isEmpty)
            } else if currentItem.type == "show" || currentItem.type == "season" {
                Button {
                    if let episode = nextUpEpisode { selectedEpisode = episode }
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: showPlayButtonLabel, isFocused: focusedActionButton == "play")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 28)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(nextUpEpisode == nil)

                // Shuffle
                Button {
                    Task { await shufflePlay() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingShufflePlay {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Shuffle")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 28)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "shuffle", cornerRadius: pillButtonHeight / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "shuffle")
                .disabled(isLoadingShufflePlay)
            } else if currentItem.type != "track" {
                // Movies/Episodes: Play button with progress bar + time remaining
                Button {
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: effectiveItem.isInProgress ? "Resume" : "Play", isFocused: focusedActionButton == "play")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.horizontal, 28)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
            }

            // Watched toggle — perfect circle checkmark button
            if !isMusicItem {
                Button {
                    Task { await toggleWatched() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watched", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "watched")
            }

            // Music: Star rating — perfect circle
            if isMusicItem {
                Button {
                    Task { await toggleStarRating() }
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "star", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "star")
            }

            // Show button (for seasons)
            if currentItem.type == "season", currentItem.parentRatingKey != nil {
                Button {
                    Task { await navigateToParentShowFromSeason() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tv")
                        Text("Show")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 28)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "showFromSeason", cornerRadius: pillButtonHeight / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "showFromSeason")
                .disabled(isLoadingNavigation)
            }

            // Info button for artists — perfect circle
            if currentItem.type == "artist", let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                Button {
                    showBioSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "info", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "info")
            }

            // Trailer button — perfect circle
            if !isMusicItem, fullMetadata?.trailer != nil {
                Button {
                    Task { await loadAndPlayTrailer() }
                } label: {
                    Image(systemName: "film")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "trailer", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "trailer")
            }
        }
        .disabled(!allowActionRowInteraction)
        .focusSection()
    }

    /// Play button label with inline progress bar + time remaining (Apple TV+ style)
    private func playButtonLabel(text: String, isFocused: Bool = false) -> some View {
        let trackColor = isFocused ? Color.black.opacity(0.2) : Color.white.opacity(0.3)
        let fillColor = isFocused ? Color.black : Color.white

        return HStack(spacing: 10) {
            Image(systemName: "play.fill")

            // Progress bar (always shown — full track for unwatched, partial for in-progress)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(trackColor)
                    .frame(width: 80, height: 5)
                if displayedProgress > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor)
                        .frame(width: 80 * displayedProgress, height: 5)
                }
            }

            // Time: remaining if in progress, total duration otherwise
            if effectiveItem.isInProgress, let remaining = effectiveItem.remainingTimeFormatted {
                Text(remaining)
            } else if let duration = effectiveItem.durationFormatted {
                Text(duration)
            } else {
                Text(text)
            }
        }
    }

    // MARK: - Season Section (TV Shows)

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingSeasons {
                ProgressView("Loading seasons...")
            } else if !seasons.isEmpty {
                SeasonPillBar(
                    seasons: seasons,
                    selectedSeason: $selectedSeason,
                    onSeasonSelected: { season in
                        // Scroll episode list to this season's first episode
                        if let firstEp = unifiedEpisodes.first(where: { $0.parentRatingKey == season.ratingKey }),
                           let epKey = firstEp.ratingKey {
                            episodeScrollTarget = epKey
                        }
                    }
                )
                .opacity(scrollProgress)
                .onMoveCommand { direction in
                    if direction == .up {
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                }

                // Unified horizontal episode cards across all seasons
                unifiedEpisodeList
            }
        }
    }

    private var shouldUseSingleSeasonPillHeaderInSeasonDetail: Bool {
        currentItem.type == "season" && seasons.count == 1
    }

    private var seasonDetailHeaderPills: [PlexMetadata] {
        let matchingSeason = seasons.filter { $0.ratingKey == currentItem.ratingKey }
        if !matchingSeason.isEmpty {
            return matchingSeason
        }
        return [selectedSeason ?? currentItem]
    }

    /// Unified horizontal episode card row across all seasons
    private var unifiedEpisodeList: some View {
        Group {
            if unifiedEpisodes.isEmpty && isLoadingEpisodes {
                ProgressView("Loading episodes...")
                    .padding(.top, 20)
            } else if !unifiedEpisodes.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(unifiedEpisodes.enumerated()), id: \.element.ratingKey) { index, episode in
                                let isSeasonBoundary = index > 0 && episode.parentRatingKey != unifiedEpisodes[index - 1].parentRatingKey
                                let leadingPad: CGFloat = index == 0 ? 48 : (isSeasonBoundary ? 56 : 24)

                                EpisodeCard(
                                    episode: episode,
                                    serverURL: authManager.selectedServerURL ?? "",
                                    authToken: authManager.selectedServerToken ?? "",
                                    focusedEpisodeId: $focusedEpisodeId,
                                    showSeasonPrefix: seasons.count > 1,
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
                                .padding(.leading, leadingPad)
                                .padding(.trailing, index == unifiedEpisodes.count - 1 ? 48 : 0)
                                .id(episode.ratingKey)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    .onMoveCommand { direction in
                        guard direction == .up, seasons.count <= 1 else { return }
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                    .onChange(of: episodeScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .leading)
                        }
                        episodeScrollTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - Episode Section (Seasons)

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingEpisodes || isLoadingSeasons {
                ProgressView("Loading episodes...")
            } else if !episodes.isEmpty {
                if shouldUseSingleSeasonPillHeaderInSeasonDetail {
                    SeasonPillBar(
                        seasons: seasonDetailHeaderPills,
                        selectedSeason: $selectedSeason,
                        onSeasonSelected: { _ in }
                    )
                } else {
                    Text("Episodes")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.leading, 48)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(episodes, id: \.ratingKey) { episode in
                            EpisodeCard(
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
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()
                .remembersFocus(key: "detailEpisodes", focusedId: $focusedEpisodeId)
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
                    }
                }
                .padding(.horizontal, 8)  // Room for focus scale effect
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
                    }
                }
                .padding(.horizontal, 8)  // Room for focus scale effect
                .focusSection()
            }
        }
    }

    // MARK: - Player Presentation (tvOS)

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
        guard let request = playerHeroBackdropRequest(for: metadata) else {
            return (nil, nil)
        }

        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

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
            }
        } catch {
            print("Failed to load full metadata: \(error)")
        }

        isLoadingExtras = false
    }

    private func syncHeroBackdrop(tmdbIdOverride: Int? = nil, tvdbIdOverride: Int? = nil) {
        let request = currentHeroBackdropRequest(
            tmdbIdOverride: tmdbIdOverride,
            tvdbIdOverride: tvdbIdOverride
        )
        heroBackdrop.load(request: request, motionLocked: heroBackdropMotionLocked)
    }

    private func refreshHeroBackdropAssets() async {
        switch currentItem.type {
        case "show":
            if let tmdbId = fullMetadata?.tmdbId ?? currentItem.tmdbId {
                syncHeroBackdrop(tmdbIdOverride: tmdbId)
            } else if let tvdbId = fullMetadata?.tvdbId ?? currentItem.tvdbId {
                syncHeroBackdrop(tvdbIdOverride: tvdbId)
            } else {
                syncHeroBackdrop()
            }
        case "movie":
            if let tmdbId = fullMetadata?.tmdbId ?? currentItem.tmdbId {
                syncHeroBackdrop(tmdbIdOverride: tmdbId)
            } else if let tvdbId = fullMetadata?.tvdbId ?? currentItem.tvdbId {
                syncHeroBackdrop(tvdbIdOverride: tvdbId)
            } else {
                syncHeroBackdrop()
            }
        case "episode":
            if let tmdbId = await resolveShowTmdbId() {
                syncHeroBackdrop(tmdbIdOverride: tmdbId)
            } else {
                syncHeroBackdrop()
            }
        default:
            syncHeroBackdrop()
        }
    }

    private func currentHeroBackdropRequest(
        tmdbIdOverride: Int? = nil,
        tvdbIdOverride: Int? = nil
    ) -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        let mediaTypeOverride: TMDBMediaType?
        switch currentItem.type {
        case "movie":
            mediaTypeOverride = .movie
        case "show", "episode":
            mediaTypeOverride = .tv
        default:
            mediaTypeOverride = nil
        }

        return currentItem.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token,
            tmdbIdOverride: tmdbIdOverride,
            tvdbIdOverride: tvdbIdOverride,
            mediaTypeOverride: mediaTypeOverride
        )
    }

    private func playerHeroBackdropRequest(for metadata: PlexMetadata) -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        let backdropSource = (metadata.type == "episode" && selectedEpisode != nil) ? currentItem : metadata
        let baseRequest = backdropSource.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token
        )

        let thumbPath = metadata.thumb ?? metadata.bestThumb
        let thumbURL = thumbPath.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }

        return HeroBackdropRequest(
            cacheKey: metadata.ratingKey ?? baseRequest.cacheKey,
            plexBackdropURL: baseRequest.plexBackdropURL,
            plexThumbnailURL: thumbURL,
            tmdbId: baseRequest.tmdbId,
            tvdbId: baseRequest.tvdbId,
            mediaType: baseRequest.mediaType,
            preferredBackdropSize: baseRequest.preferredBackdropSize
        )
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
            // Direct TMDB ID from guid or Guid array
            if let tmdbId = showMetadata.tmdbId {
                return tmdbId
            }

            // Legacy agent: convert TVDB ID → TMDB ID
            if let tvdbId = showMetadata.tvdbId {
                return await TMDBClient.shared.findTmdbId(tvdbId: tvdbId, type: .tv)
            }

            return nil
        } catch {
            print("🎨 [Logo] Failed to fetch show metadata: \(error)")
            return nil
        }
    }

    /// Pre-compute and cache stream URL to reduce player startup latency
    private func preWarmStreamURL(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        guard let ratingKey = metadata.ratingKey,
              let partKey = metadata.Media?.first?.Part?.first?.key else { return }

        // Build direct play URL for playback prewarming
        if let url = networkManager.buildPlaybackDirectPlayURL(
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

        // No OnDeck episode - search unifiedEpisodes if available
        if !unifiedEpisodes.isEmpty {
            let candidate = unifiedEpisodes.first(where: { $0.isInProgress })
                ?? unifiedEpisodes.first(where: { !$0.isWatched })
                ?? unifiedEpisodes.first

            if let candidate, let ratingKey = candidate.ratingKey {
                do {
                    nextUpEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey
                    )
                } catch {
                    nextUpEpisode = candidate
                }
            }
            return
        }

        // Fallback: per-season API calls (unifiedEpisodes not yet loaded)
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
            } else if let first = fetchedSeasons.first {
                // Fallback to first season
                selectedSeason = first
            }
        } catch {
            print("Failed to load seasons for episode: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load sibling seasons when viewing a season so single-season shows can
    /// keep the season-pill header pattern instead of falling back to `Episodes`.
    private func loadSeasonsForCurrentSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.parentRatingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            if let currentSeasonKey = currentItem.ratingKey,
               let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
            } else if let first = fetchedSeasons.first {
                selectedSeason = first
            }
        } catch {
            print("Failed to load sibling seasons for season detail: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load all episodes across all seasons using getAllLeaves (single API call)
    private func loadAllEpisodes() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey: String?
        if currentItem.type == "show" {
            ratingKey = currentItem.ratingKey
        } else if currentItem.type == "episode" {
            ratingKey = currentItem.grandparentRatingKey
        } else {
            return
        }

        guard let ratingKey else { return }

        isLoadingEpisodes = true

        do {
            let allEps = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            unifiedEpisodes = allEps
        } catch {
            print("Failed to load all episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes for a season.
    /// - Parameter crossfade: When true, keeps old episodes visible and crossfades to new ones
    ///   instead of showing a loading indicator. Used for season switching.
    private func loadEpisodes(for season: PlexMetadata, crossfade: Bool = false) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = season.ratingKey else { return }

        if !crossfade {
            isLoadingEpisodes = true
        }

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            if crossfade {
                withAnimation(.easeInOut(duration: 0.35)) {
                    episodes = fetchedEpisodes
                }
            } else {
                episodes = fetchedEpisodes
            }
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

            // Also update in unified episodes
            if let index = unifiedEpisodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                unifiedEpisodes[index].viewCount = updatedMetadata.viewCount
                unifiedEpisodes[index].viewOffset = updatedMetadata.viewOffset
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
            return
        }

        // Get librarySectionID from fullMetadata (fetched first) or item
        guard let librarySectionId = fullMetadata?.librarySectionID ?? currentItem.librarySectionID else {
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
        } catch {
            print("Failed to load albums: \(error)")
        }

        isLoadingAlbums = false
    }


    // MARK: - URL Helpers

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

// MARK: - Season Poster Bar (tvOS)


/// Season poster card for the horizontal bar. Click selects, focus only highlights.
struct SeasonBarCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    @FocusState private var isFocused: Bool

    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    private var seasonLabel: String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                // Season poster
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? .white : .clear, lineWidth: 3)
                    )

                // Season label
                Text(seasonLabel)
                    .font(.system(size: titleSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected || isFocused ? 1.0 : 0.6))
                    .lineLimit(1)
            }
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
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
                            .font(.system(size: 28, weight: .light))
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

/// Horizontal scrollable row of season poster cards. Click-to-select only.
struct SeasonPosterBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let serverURL: String
    let authToken: String
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(seasons, id: \.ratingKey) { season in
                        SeasonBarCard(
                            season: season,
                            isSelected: selectedSeason?.ratingKey == season.ratingKey,
                            serverURL: serverURL,
                            authToken: authToken,
                            onSelect: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ratingKey)
                        .id(season.ratingKey)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
            .focusSection()
            .remembersFocus(key: "seasonPosters", focusedId: $focusedSeasonId)
            .onChange(of: selectedSeason?.ratingKey) { _, newKey in
                guard let key = newKey else { return }
                withAnimation {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }
}


// MARK: - Season Poster Card

struct SeasonPosterCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    var focusedSeasonId: FocusState<String?>.Binding?
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

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
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .hoverEffect(.highlight)  // Native tvOS focus effect - scales poster AND badge
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .padding(.bottom, 10)  // Space for hover scale effect

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
        .buttonStyle(CardButtonStyle())
        .modifier(SeasonFocusModifier(focusedSeasonId: focusedSeasonId, seasonRatingKey: season.ratingKey))
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

// MARK: - Scroll Offset Tracking

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Season Pill Bar

/// Horizontal row of capsule/pill buttons for season selection (Apple TV+ style)
struct SeasonPillBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(seasons, id: \.ratingKey) { season in
                    let isSelected = selectedSeason?.ratingKey == season.ratingKey
                    SeasonPillButton(
                        label: seasonLabel(for: season),
                        isSelected: isSelected,
                        action: {
                            selectedSeason = season
                            onSeasonSelected(season)
                        }
                    )
                    .focused($focusedSeasonId, equals: season.ratingKey)
                    .id(season.ratingKey)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func seasonLabel(for season: PlexMetadata) -> String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }
}

/// Individual season pill button
struct SeasonPillButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isFocused ? .white : (isSelected ? .white.opacity(0.2) : .clear))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected && !isFocused ? .white.opacity(0.4) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }
}

// MARK: - Episode Card (Horizontal)

/// Apple TV+ style episode card for horizontal scrolling rows
struct EpisodeCard: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var focusedEpisodeId: FocusState<String?>.Binding?
    var showSeasonPrefix: Bool = false
    let onPlay: () -> Void
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

    private let cardWidth: CGFloat = 340
    private let thumbHeight: CGFloat = 192

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
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
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: cardWidth, height: thumbHeight)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    // Duration pill
                    if let duration = episode.durationFormatted {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text(duration)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5)).frame(height: 3)
                                    Rectangle().fill(.blue).frame(width: geo.size.width * progress, height: 3)
                                }
                            }
                        }
                    }
                }

                // Metadata below thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    // Episode label
                    Text(episodeLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, 10)

                    // Title
                    Text(episode.title ?? "Episode")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)

                    // Summary
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.top, 1)
                    }

                    // Date + Content Rating
                    HStack(spacing: 6) {
                        if let date = episode.originallyAvailableAt {
                            Text(formattedDate(date))
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        if let rating = episode.contentRating {
                            Text(rating)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var episodeLabel: String {
        if showSeasonPrefix, let epString = episode.episodeString {
            return epString
        }
        if let index = episode.index {
            return "Episode \(index)"
        }
        return episode.episodeString ?? "Episode"
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }

    private func formattedDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var isCurrent: Bool = false  // Indicates this is the episode currently being viewed
    var focusedEpisodeId: FocusState<String?>.Binding?
    let onPlay: () -> Void
    var onPlayFromBeginning: (() -> Void)? = nil
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

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
                .frame(width: 240, height: 135)
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
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    Text(episode.title ?? "Episode")
                        .font(.system(size: 30, weight: .medium))
                        .lineLimit(1)

                    if let duration = episode.durationFormatted {
                        Text(duration)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Current episode indicator (when viewing episode detail)
                if isCurrent {
                    Text("VIEWING")
                        .font(.system(size: 16, weight: .semibold))
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
                        .font(.system(size: 24))
                }
            }
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
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
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

// MARK: - Skeleton Episode Row

/// Loading placeholder for episode rows - shows while fetching episode data
struct SkeletonEpisodeRow: View {
    let episodeNumber: Int

    var body: some View {
        HStack(spacing: 16) {
            // Placeholder thumbnail
            Rectangle()
                .fill(Color(white: 0.15))
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.3))
                }

            VStack(alignment: .leading, spacing: 5) {
                // Episode number placeholder
                Text("Episode \(episodeNumber)")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))

                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 220, height: 26)

                // Duration placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 22)
            }

            Spacer()
        }
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
    }
}

// MARK: - Album Track Row

struct AlbumTrackRow: View {
    let track: PlexMetadata
    let trackNumber: Int
    let serverURL: String
    let authToken: String
    var focusedId: FocusState<String?>.Binding?
    @FocusState private var isFocused: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Track number
                Text("\(trackNumber)")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title ?? "Track \(trackNumber)")
                        .font(.system(size: 22, weight: .medium))
                        .lineLimit(1)

                    if let duration = track.durationFormatted {
                        Text(duration)
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
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
        }
        .buttonStyle(CardButtonStyle())
        .modifier(TrackFocusModifier(focusedId: focusedId, trackRatingKey: track.ratingKey))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

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

// MARK: - Artist Album Row

struct ArtistAlbumRow: View {
    let album: PlexMetadata
    let serverURL: String
    let authToken: String
    var isFocused: Bool = false

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
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title ?? "Unknown Album")
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let year = album.year {
                        Text(String(year))
                    }
                    if let trackCount = album.leafCount {
                        Text("\(trackCount) tracks")
                    }
                }
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
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

    var body: some View {
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
        .onExitCommand {
            dismiss()
        }
    }
}

// MARK: - Bio Sheet Helper Views (tvOS)

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

// MARK: - Player View Wrapper (non-tvOS)


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

// MARK: - Navigation Destinations Modifier

/// Conditionally applies .navigationDestination modifiers.
/// Disabled in preview overlay flow (no NavigationStack ancestor).
private struct NavigationDestinationsModifier: ViewModifier {
    @Binding var navigateToAlbum: PlexMetadata?
    @Binding var navigateToSeason: PlexMetadata?
    @Binding var navigateToShow: PlexMetadata?
    @Binding var navigateToEpisode: PlexMetadata?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
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
        } else {
            content
        }
    }
}
