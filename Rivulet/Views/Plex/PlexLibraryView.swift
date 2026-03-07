//
//  PlexLibraryView.swift
//  Rivulet
//
//  Grid view for browsing a Plex library section
//

import SwiftUI


struct PlexLibraryView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(\.uiScale) private var scale

    @StateObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var librarySettings = LibrarySettingsManager.shared
    private let dataStore = PlexDataStore.shared
    @AppStorage("showLibraryHero") private var showLibraryHero = false
    @AppStorage("showLibraryRecommendations") private var showLibraryRecommendations = true
    @AppStorage("showLibraryRecentRows") private var showLibraryRecentRows = true
    @State private var currentSortOption: LibrarySortOption = .addedAtDesc
    @State private var items: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []  // Library-specific hubs from Plex API
    @State private var isLoading = false
    @State private var isLoadingMore = false  // Loading additional pages
    @State private var error: String?
    @State private var selectedItem: PlexMetadata?
    @State private var heroItem: PlexMetadata?
    @State private var lastLoadedLibraryKey: String?  // Track which library is currently loaded
    @State private var hasPrefetched = false  // Track if we've already prefetched for this library
    @State private var hasMoreItems = true  // Whether there are more items to load
    @State private var totalItemCount: Int = 0  // Total items in this library
    @State private var cachedProcessedHubs: [PlexHub] = []  // Memoized hubs to avoid recalculation
    @State private var loadingTask: Task<Void, Never>?  // Track current loading task for cancellation
    // Batching disabled — LazyVGrid handles lazy rendering natively.
    // Uncomment if first-load performance regresses.
    // @State private var visibleItemCount: Int = 0
    // @State private var visibleItemExpandTask: Task<Void, Never>?
    @State private var recommendations: [PlexMetadata] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationsError: String?
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false

    @FocusState private var focusedItemId: String?  // Track focused item by "context:itemId" format
    @State private var lastFocusedItemId: String?  // Remembers focus for back-from-detail restore
    @State private var rowPreviewRequest: PreviewRequest?
    @State private var previewRestoreTarget: PreviewSourceTarget?
    @State private var lastPrefetchIndex: Int = -18  // Track last prefetch position for throttling
    private var firstDisplayedItem: PlexMetadata? {
        items.first
    }

    /// Create a unique focus ID for a grid item
    private func gridFocusId(for item: PlexMetadata) -> String {
        "libraryGrid:\(item.ratingKey ?? "")"
    }

    private let networkManager = PlexNetworkManager.shared
    private let cacheManager = CacheManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Check if this is a music library (uses square posters)
    private var isMusicLibrary: Bool {
        dataStore.libraries.first(where: { $0.key == libraryKey })?.isMusicLibrary ?? false
    }

    private var columns: [GridItem] {
        let minWidth = ScaledDimensions.gridMinWidth * scale
        let maxWidth = ScaledDimensions.gridMaxWidth * scale
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: ScaledDimensions.gridSpacing)]
    }

    // private let initialVisibleBatch = 36  // Limit first-frame layout work

    private var recommendationsContentType: RecommendationContentType {
        let libraryType = dataStore.libraries.first(where: { $0.key == libraryKey })?.type
        switch libraryType {
        case "movie":
            return .movies
        case "show":
            return .shows
        default:
            return .moviesAndShows
        }
    }

    private var shouldShowRecommendationsRow: Bool {
        let libraryType = dataStore.libraries.first(where: { $0.key == libraryKey })?.type
        return libraryType == "movie" || libraryType == "show"
    }

    // MARK: - Processed Hubs (merged Continue Watching + On Deck)

    /// Essential hub types that are always shown (Continue Watching, Recently Added, Recently Released, Recently Played)
    private func isEssentialHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""

        // Continue Watching / On Deck
        if identifier.contains("continuewatching") || title.contains("continue watching") ||
           identifier.contains("ondeck") || title.contains("on deck") {
            return true
        }

        // Recently Added (video and music)
        if identifier.contains("recentlyadded") || title.contains("recently added") {
            return true
        }

        // Recently Released (by year)
        if identifier.contains("recentlyreleased") || title.contains("recently released") ||
           identifier.contains("newestreleases") || title.contains("newest releases") {
            return true
        }

        // Recently Played (music)
        if identifier.contains("recentlyplayed") || title.contains("recently played") {
            return true
        }

        return false
    }

    /// Check if a hub is a "recent" type (Recently Added, Recently Released, Newest Releases)
    private func isRecentHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("recentlyadded") || title.contains("recently added") ||
               identifier.contains("recentlyreleased") || title.contains("recently released") ||
               identifier.contains("newestreleases") || title.contains("newest releases")
    }

    /// Essential hubs only (Continue Watching, Recently Added, Recently Released)
    private var essentialHubs: [PlexHub] {
        cachedProcessedHubs.filter { isEssentialHub($0) && (showLibraryRecentRows || !isRecentHub($0)) }
    }

    /// Discovery/recommendation hubs (Rediscover, Because you watched, etc.)
    private var discoveryHubs: [PlexHub] {
        cachedProcessedHubs.filter { !isEssentialHub($0) }
    }

    /// Processes hubs to combine Continue Watching and On Deck, similar to PlexHomeView
    /// Called once when hubs change, result is cached in cachedProcessedHubs
    private func computeProcessedHubs(from hubsToProcess: [PlexHub]) -> [PlexHub] {
        var result: [PlexHub] = []
        var continueWatchingItems: [PlexMetadata] = []
        var seenRatingKeys: Set<String> = []

        for hub in hubsToProcess {
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let title = hub.title?.lowercased() ?? ""

            // Check if this is a Continue Watching or On Deck hub
            let isContinueWatching = identifier.contains("continuewatching") ||
                                     title.contains("continue watching")
            let isOnDeck = identifier.contains("ondeck") ||
                          title.contains("on deck")

            if isContinueWatching || isOnDeck {
                // Merge items, deduplicating by ratingKey
                if let items = hub.Metadata {
                    for item in items {
                        if let key = item.ratingKey, !seenRatingKeys.contains(key) {
                            seenRatingKeys.insert(key)
                            continueWatchingItems.append(item)
                        }
                    }
                }
            } else {
                // Include all non-continue-watching hubs
                result.append(hub)
            }
        }

        // Sort merged items by lastViewedAt (most recent first)
        continueWatchingItems.sort { item1, item2 in
            let time1 = item1.lastViewedAt ?? 0
            let time2 = item2.lastViewedAt ?? 0
            return time1 > time2
        }

        // Create merged Continue Watching hub if we have items
        if !continueWatchingItems.isEmpty {
            let mergedHub = PlexHub(
                hubIdentifier: "continueWatching",
                title: "Continue Watching",
                Metadata: continueWatchingItems
            )
            // Insert at beginning
            result.insert(mergedHub, at: 0)
        }

        return result
    }

    var body: some View {
        NavigationStack {
            navigationContent
        }
        // Tell parent we're in nested navigation when viewing detail
        .onChange(of: selectedItem) { _, newValue in
            let _ = newValue
            updateNestedNavigationState()
        }
        .onChange(of: rowPreviewRequest?.id) { _, _ in
            updateNestedNavigationState()
        }
        .onChange(of: enablePersonalizedRecommendations) { _, _ in
            handleRecommendationsToggle()
        }
        // Track last focused item for back-from-detail restore
        .onChange(of: focusedItemId) { _, newValue in
            if let newValue {
                lastFocusedItemId = newValue
            }
        }
    }

    @ViewBuilder
    private var libraryStateContent: some View {
        ZStack {
            if !authManager.isAuthenticated {
                notConnectedView
            } else if isLoading && items.isEmpty {
                loadingView
            } else if let error = error, items.isEmpty {
                errorView(error)
            } else if items.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
    }

    private var navigationContent: some View {
        libraryStateContent
            .task(id: libraryKey) {
                await handleLibraryTask()
            }
            .refreshable {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)) { _ in
                Task {
                    guard let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken else { return }
                    await fetchLibraryHubs(serverURL: serverURL, token: token)
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                PlexDetailView(item: item)
            }
            .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
                previewOverlay(for: anchors)
            }
    }

    @ViewBuilder
    private func previewOverlay(for anchors: [PreviewSourceTarget: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let activeRequest = rowPreviewRequest {
                let resolvedFrames = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key, proxy[$0.value]) })
                PreviewOverlayHost(
                    request: activeRequest,
                    sourceFrames: resolvedFrames,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    onDismiss: { sourceTarget in
                        previewRestoreTarget = sourceTarget
                        self.rowPreviewRequest = nil
                    }
                )
            }
        }
    }

    private func handleLibraryTask() async {
        loadingTask?.cancel()

        error = nil

        let isNewLibrary = lastLoadedLibraryKey != libraryKey

        if authManager.isAuthenticated {
            if isNewLibrary {
                items = []
                hubs = []
                cachedProcessedHubs = []
                isLoading = true
                lastLoadedLibraryKey = libraryKey

                currentSortOption = librarySettings.getSortOption(for: libraryKey)

                focusedItemId = nil
                lastFocusedItemId = nil

                heroItem = dataStore.getCachedHero(forLibrary: libraryKey)

                hasPrefetched = false
                hasMoreItems = true
                totalItemCount = 0

                let inMemoryHubs = dataStore.libraryHubs[libraryKey]

                let libKey = libraryKey
                let (cachedItems, cachedHubs): ([PlexMetadata], [PlexHub]?) = await Task.detached(priority: .userInitiated) {
                    async let itemsTask = self.getCachedItems()
                    let hubsResult: [PlexHub]?
                    if inMemoryHubs != nil {
                        hubsResult = nil
                    } else {
                        hubsResult = await self.cacheManager.getCachedLibraryHubs(forLibrary: libKey)
                    }
                    return await (itemsTask, hubsResult)
                }.value

                let hubsToUse = inMemoryHubs ?? cachedHubs
                if let hubsToUse, !hubsToUse.isEmpty {
                    hubs = hubsToUse
                    cachedProcessedHubs = computeProcessedHubs(from: hubsToUse)
                }

                if !cachedItems.isEmpty {
                    items = cachedItems
                    isLoading = false

                    if heroItem == nil {
                        selectHeroItemFromCurrentData()
                    }

                    if !dataStore.isFresh("libraryItems:\(libraryKey)", within: 60) {
                        await loadItemsInBackground()
                    }
                } else {
                    await loadItems()
                }

                if enablePersonalizedRecommendations {
                    Task { await refreshRecommendations(force: false) }
                }
            } else {
                await loadItemsInBackground()
                if enablePersonalizedRecommendations, recommendations.isEmpty {
                    Task { await refreshRecommendations(force: false) }
                }
            }
        } else {
            items = []
            hubs = []
            cachedProcessedHubs = []
            heroItem = nil
            lastLoadedLibraryKey = nil
            isLoading = false
        }
    }

    private func libraryRowID(for hub: PlexHub, section: String, index: Int) -> String {
        let identifier = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
        return "library:\(libraryKey):\(section):\(index):\(identifier)"
    }

    private func updateNestedNavigationState() {
        if rowPreviewRequest != nil {
            nestedNavState.isNested = true
            nestedNavState.goBackAction = nil
            return
        }

        let isNested = selectedItem != nil
        nestedNavState.isNested = isNested
        if isNested {
            nestedNavState.goBackAction = { [weak nestedNavState] in
                selectedItem = nil
                nestedNavState?.isNested = false
            }
        } else {
            nestedNavState.goBackAction = nil
            if let targetId = lastFocusedItemId {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    focusedItemId = targetId
                }
            }
        }
    }

    // MARK: - Content View

    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                essentialRowsView
                heroSectionView
                discoveryRowsView
                librarySectionHeader
                libraryGridView

                // Loading more indicator
                if isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .id(libraryKey)  // Force fresh ScrollView when library changes - starts at top
        .opacity(rowPreviewRequest != nil ? 0.12 : 1)
        .offset(y: rowPreviewRequest != nil ? 20 : 0)
        .allowsHitTesting(rowPreviewRequest == nil)
        .animation(previewEntryAnimation, value: rowPreviewRequest?.id)
        .onAppear {
            // Hero will be selected when items load via task handler
            if heroItem == nil && !items.isEmpty {
                selectHeroItem()
            }
        }
        .onChange(of: items.count) { oldCount, newCount in
            // Consolidated handler: hero selection + prefetch
            if heroItem == nil {
                selectHeroItem()
            }
            handleItemsCountChange(oldCount: oldCount, newCount: newCount)
        }
        .onChange(of: hubs.count) { _, _ in
            // Recompute cached hubs (memoization)
            cachedProcessedHubs = computeProcessedHubs(from: hubs)
            // Only reselect hero if we don't have one yet (avoid redundant selection)
            if heroItem == nil {
                selectHeroItem()
            }
        }
    }

    // MARK: - Hero Selection

    private func selectHeroItem() {
        // Check cache first - heroes persist across navigation
        if let cachedHero = dataStore.getCachedHero(forLibrary: libraryKey) {
            heroItem = cachedHero
            return
        }

        // Try to get hero from recently added hub first
        let recentlyAddedHub = hubs.first { hub in
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let title = hub.title?.lowercased() ?? ""
            return identifier.contains("recentlyadded") || title.contains("recently added")
        }

        if let hubItems = recentlyAddedHub?.Metadata, !hubItems.isEmpty {
            if let newHero = hubItems.randomElement() {
                heroItem = newHero
                dataStore.cacheHero(newHero, forLibrary: libraryKey)
            }
            return
        }

        // Fallback to items sorted by addedAt
        if !items.isEmpty {
            if let newHero = mostRecentItem(from: items) {
                heroItem = newHero
                dataStore.cacheHero(newHero, forLibrary: libraryKey)
            }
        }
    }

    // MARK: - Hero Section View

    @ViewBuilder
    private var heroSectionView: some View {
        // Only show hero when there are essential rows above it (prevents flash at top during library switch)
        if showLibraryHero, let hero = heroItem, !essentialHubs.isEmpty {
            HeroView(
                item: hero,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                focusTarget: $focusedItemId,
                targetValue: "hero"
            ) {
                selectedItem = hero
            }
            .id("hero-\(libraryKey)-\(hero.ratingKey ?? "")")
            .padding(.top, 48)
        }
    }

    // MARK: - Essential Rows View (Continue Watching, Recently Added, Recently Released)

    @ViewBuilder
    private var essentialRowsView: some View {
        if !essentialHubs.isEmpty {
            VStack(alignment: .leading, spacing: 40) {
                let continueWatchingIndex = essentialHubs.firstIndex(where: isContinueWatchingHub)
                ForEach(Array(essentialHubs.enumerated()), id: \.element.hubIdentifier) { index, hub in
                    if let hubItems = hub.Metadata, !hubItems.isEmpty {
                        let isContinueWatching = isContinueWatchingHub(hub)
                        InfiniteContentRow(
                            rowID: libraryRowID(for: hub, section: "essential", index: index),
                            title: hub.title ?? "Untitled",
                            initialItems: hubItems,
                            hubKey: hub.key ?? hub.hubKey,
                            hubIdentifier: hub.hubIdentifier,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            contextMenuSource: isContinueWatching ? .continueWatching : .library,
                            onItemSelected: { item in
                                selectedItem = item
                            },
                            onRefreshNeeded: {
                                await refresh()
                            },
                            onPreviewRequested: isContinueWatching ? nil : { request in
                                withAnimation(previewEntryAnimation) {
                                    rowPreviewRequest = request
                                }
                            },
                            restorePreviewFocusTarget: $previewRestoreTarget
                        )

                        if enablePersonalizedRecommendations,
                           shouldShowRecommendationsRow,
                           continueWatchingIndex == index {
                            recommendationsSection
                        }
                    }
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.top, 100)  // Extra top padding since essential rows are first
        }
    }

    // MARK: - Recommendations Section

    @ViewBuilder
    private var recommendationsSection: some View {
        if isLoadingRecommendations && recommendations.isEmpty {
            HStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Building Personalized Recommendations")
                        .font(.system(size: 22, weight: .semibold))
                    Text("This may take a moment")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else if let error = recommendationsError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personalized Recommendations Unavailable")
                        .font(.system(size: 20, weight: .semibold))
                    Text(error)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") {
                    Task { await refreshRecommendations(force: true) }
                }
                .buttonStyle(AppStoreButtonStyle())
            }
        } else if !recommendations.isEmpty {
            InfiniteContentRow(
                rowID: "library:\(libraryKey):recommendations",
                title: "Personalized Recommendations",
                initialItems: recommendations,
                hubKey: nil,
                hubIdentifier: nil,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                contextMenuSource: .library,
                onItemSelected: { item in
                    selectedItem = item
                },
                onRefreshNeeded: {
                    await refreshRecommendations(force: true)
                },
                onPreviewRequested: { request in
                    withAnimation(previewEntryAnimation) {
                        rowPreviewRequest = request
                    }
                },
                restorePreviewFocusTarget: $previewRestoreTarget
            )
        }
    }

    // MARK: - Discovery Rows View (Rediscover, Recommendations, etc.)

    @ViewBuilder
    private var discoveryRowsView: some View {
        if showLibraryRecommendations && !discoveryHubs.isEmpty {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(discoveryHubs, id: \.hubIdentifier) { hub in
                    if let hubItems = hub.Metadata, !hubItems.isEmpty {
                        InfiniteContentRow(
                            rowID: libraryRowID(for: hub, section: "discovery", index: discoveryHubs.firstIndex(where: { $0.hubIdentifier == hub.hubIdentifier }) ?? 0),
                            title: hub.title ?? "Untitled",
                            initialItems: hubItems,
                            hubKey: hub.key ?? hub.hubKey,
                            hubIdentifier: hub.hubIdentifier,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            contextMenuSource: .library,
                            onItemSelected: { item in
                                selectedItem = item
                            },
                            onRefreshNeeded: {
                                await refresh()
                            },
                            onPreviewRequested: { request in
                                withAnimation(previewEntryAnimation) {
                                    rowPreviewRequest = request
                                }
                            },
                            restorePreviewFocusTarget: $previewRestoreTarget
                        )
                    }
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.top, 48)
        }
    }

    // MARK: - Library Section Header

    private var librarySectionHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(libraryTitle)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .id("library-title-\(libraryKey)")  // Force instant update when library changes
                    .transaction { transaction in
                        // Disable animation for instant title update
                        transaction.animation = nil
                    }

                Text("\(totalItemCount > 0 ? totalItemCount : items.count) items")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            sortButton
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 60)
        .padding(.bottom, 32)
    }

    // MARK: - Sort Button

    @FocusState private var isSortButtonFocused: Bool

    private var sortButton: some View {
        Menu {
            ForEach(LibrarySortOption.options(for: currentLibraryType), id: \.self) { option in
                Button {
                    if currentSortOption != option {
                        currentSortOption = option
                        librarySettings.setSortOption(option, for: libraryKey)
                        Task {
                            await reloadWithNewSort(sortOption: option)
                        }
                    }
                } label: {
                    HStack {
                        Text(option.displayName)
                        if currentSortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 20, weight: .semibold))

                Text(currentSortOption.displayName)
                    .font(.system(size: 20, weight: .medium))
            }
            .foregroundStyle(isSortButtonFocused ? .black : .white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSortButtonFocused ? .white : .white.opacity(0.15))
            )
            .scaleEffect(isSortButtonFocused ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .focused($isSortButtonFocused)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSortButtonFocused)
    }

    private var currentLibraryType: String? {
        dataStore.libraries.first(where: { $0.key == libraryKey })?.type
    }

    private func reloadWithNewSort(sortOption: LibrarySortOption) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Clear cache for this library since sort changed
        let itemType = items.first?.type
        if itemType == "movie" {
            await cacheManager.clearMoviesCache(forLibrary: libraryKey)
        } else if itemType == "show" {
            await cacheManager.clearShowsCache(forLibrary: libraryKey)
        }

        // Fetch new sorted items without clearing existing display
        // This keeps the hubs visible and only updates the grid
        hasMoreItems = true

        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: pageSize,
                sort: sortOption.apiParameter
            )

            // Update total count
            if let total = result.totalSize {
                totalItemCount = total
                hasMoreItems = result.items.count < total
            } else {
                hasMoreItems = result.items.count >= pageSize
            }

            // Replace items with new sorted results
            items = result.items

            // Cache the new results
            if itemType == "movie" {
                await cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
            } else if itemType == "show" {
                await cacheManager.cacheShows(result.items, forLibrary: libraryKey)
            }
        } catch {
            print("Failed to reload with new sort: \(error)")
        }
    }

    // MARK: - Library Grid View

    private var libraryGridView: some View {
        // NOTE: visibleItemCount batching removed — LazyVGrid already only
        // measures on-screen items. Batching added complexity and could break
        // scroll/focus restoration when returning from detail views.
        // If performance regresses on first load, re-enable the batching logic
        // (see visibleItemCount, updateVisibleItems, initialVisibleBatch).

        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                libraryGridItem(item: item, index: index)
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.vertical, 28)
        .padding(.bottom, 60)
        .focusSection()  // Help focus engine navigate the grid efficiently
    }

    @ViewBuilder
    private func libraryGridItem(item: PlexMetadata, index: Int) -> some View {
        Button {
            selectedItem = item
        } label: {
            // EquatableView tells SwiftUI to use our custom == to skip unnecessary re-renders
            EquatableView(content: MediaPosterCard(
                item: item,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? ""
            ))
        }
        .buttonStyle(CardButtonStyle())
        .focused($focusedItemId, equals: gridFocusId(for: item))
        .onAppear {
            // Trigger loading more items when nearing the end
            if index >= items.count - 12 && hasMoreItems && !isLoadingMore {
                Task { await loadMoreItems() }
            }
            // Prefetch images ahead of scroll position
            if index > lastPrefetchIndex + 3 {
                lastPrefetchIndex = index
                prefetchImagesAhead(from: index)
            }
        }
        .mediaItemContextMenu(
            item: item,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            source: .library,
            onRefreshNeeded: {
                await refresh()
            }
        )
    }

    // MARK: - Loading View (Skeleton Placeholders)

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Skeleton header
                skeletonHeader

                // Skeleton grid
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(0..<18, id: \.self) { _ in
                        skeletonPosterCard
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, 28)
            }
        }
    }

    private var skeletonHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title placeholder
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 200, height: 32)

            // Subtitle placeholder
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.05))
                .frame(width: 80, height: 17)
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 60)
        .padding(.bottom, 32)
    }

    private var skeletonPosterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Poster placeholder - square for music, rectangle for video
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 220, height: isMusicLibrary ? 220 : 330)

            // Title placeholder
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .frame(width: 100, height: 12)
            }
            .frame(height: 52, alignment: .top)
        }
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Unable to Load")
                .font(.title2)
                .fontWeight(.medium)

            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                Task { await refresh() }
            } label: {
                Text("Try Again")
                    .fontWeight(.medium)
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Content")
                .font(.title2)
                .fontWeight(.medium)

            Text("This library appears to be empty.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                Task { await refresh() }
            } label: {
                Text("Refresh")
                    .fontWeight(.medium)
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Not Connected View

    private var notConnectedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Not Connected")
                .font(.title2)
                .fontWeight(.medium)

            Text("Connect to your Plex server in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    /// Full load with loading state (used when no cache exists)
    private func loadItems() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            error = "Not authenticated"
            items = []
            hubs = []
            return
        }

        // No cache - show loading and fetch both
        isLoading = true
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: true)
        async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
        _ = await (itemsFetch, hubsFetch)
        // Select hero after data loads
        selectHeroItem()
    }

    /// Background refresh without loading state (used when cache exists)
    private func loadItemsInBackground() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Fetch items and hubs silently in background, skipping hubs if recently fetched
        let hubsFresh = dataStore.isFresh("libraryHubs:\(libraryKey)", within: 60)
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: false)
        if !hubsFresh {
            async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
            _ = await (itemsFetch, hubsFetch)
        } else {
            await itemsFetch
        }

        // Only reselect hero if hubs loaded and we don't have one yet
        // or if hubs have better candidates (recently added)
        if heroItem == nil {
            selectHeroItem()
        }
    }
    
    /// Select hero from currently loaded items/hubs (for instant display)
    private func selectHeroItemFromCurrentData() {
        // Check cache first - heroes persist across navigation
        if let cachedHero = dataStore.getCachedHero(forLibrary: libraryKey) {
            heroItem = cachedHero
            return
        }

        // When switching libraries, hubs might not be loaded yet, so prioritize items
        // Try items first (they're available immediately from cache)
        if !items.isEmpty {
            if let newHero = mostRecentItem(from: items) {
                heroItem = newHero
                dataStore.cacheHero(newHero, forLibrary: libraryKey)
            }
            return
        }

        // Fallback to hubs if items are empty but hubs are available
        if !hubs.isEmpty {
            let recentlyAddedHub = hubs.first { hub in
                let identifier = hub.hubIdentifier?.lowercased() ?? ""
                let title = hub.title?.lowercased() ?? ""
                return identifier.contains("recentlyadded") || title.contains("recently added")
            }

            if let hubItems = recentlyAddedHub?.Metadata, !hubItems.isEmpty {
                if let newHero = hubItems.randomElement() {
                    heroItem = newHero
                    dataStore.cacheHero(newHero, forLibrary: libraryKey)
                }
            }
        }
    }

    /// Pick the most recently added item without sorting the entire array (avoids main-thread spikes)
    private func mostRecentItem(from items: [PlexMetadata]) -> PlexMetadata? {
        items.max { lhs, rhs in
            let lAdded = lhs.addedAt ?? 0
            let rAdded = rhs.addedAt ?? 0
            return lAdded < rAdded
        }
    }

    private func getCachedItems() async -> [PlexMetadata] {
        // Determine type based on library (this is simplified - ideally we'd know the library type)
        if let cached = await cacheManager.getCachedMovies(forLibrary: libraryKey) {
            return cached
        }
        if let cached = await cacheManager.getCachedShows(forLibrary: libraryKey) {
            return cached
        }
        return []
    }

    // MARK: - Personalized Recommendations

    private func refreshRecommendations(force: Bool = false) async {
        guard enablePersonalizedRecommendations else { return }
        await MainActor.run {
            if force || recommendations.isEmpty {
                isLoadingRecommendations = true
            }
            recommendationsError = nil
        }

        do {
            let items = try await recommendationService.recommendations(
                forceRefresh: force,
                contentType: recommendationsContentType,
                libraryKey: shouldShowRecommendationsRow ? libraryKey : nil
            )
            await MainActor.run {
                recommendations = items
                isLoadingRecommendations = false
            }
        } catch {
            await MainActor.run {
                recommendations = []
                recommendationsError = error.localizedDescription
                isLoadingRecommendations = false
            }
        }
    }

    private func handleRecommendationsToggle() {
        if enablePersonalizedRecommendations {
            Task { await refreshRecommendations(force: true) }
        } else {
            recommendations = []
            recommendationsError = nil
            isLoadingRecommendations = false
        }
    }

    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("continuewatching") || title.contains("continue watching")
    }

    private let pageSize = 60  // Smaller initial batch to reduce main-thread layout work

    private func fetchFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: pageSize,
                sort: currentSortOption.apiParameter
            )

            // Update total count for pagination
            if let total = result.totalSize {
                totalItemCount = total
                hasMoreItems = result.items.count < total
            } else {
                // If no totalSize, assume there might be more if we got a full page
                hasMoreItems = result.items.count >= pageSize
            }

            // Only update items if they're actually different (prevents unnecessary re-renders).
            // When refreshing in background (!updateLoading), don't truncate if we already
            // have more items loaded via infinite scroll — just update the overlapping portion.
            if !updateLoading && items.count > result.items.count {
                // Merge: update existing items with fresh data, keep the rest
                var merged = items
                let existingKeys = Dictionary(uniqueKeysWithValues: result.items.compactMap { item in
                    item.ratingKey.map { ($0, item) }
                })
                for i in merged.indices {
                    if let key = merged[i].ratingKey, let fresh = existingKeys[key] {
                        merged[i] = fresh
                    }
                }
                if !itemsAreEqual(items, merged) {
                    items = merged
                }
            } else if !itemsAreEqual(items, result.items) {
                items = result.items
            }

            // Cache based on type
            if let firstItem = result.items.first {
                if firstItem.type == "movie" {
                    await cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
                } else if firstItem.type == "show" {
                    await cacheManager.cacheShows(result.items, forLibrary: libraryKey)
                }
            }

            dataStore.recordFetch(for: "libraryItems:\(libraryKey)")
            error = nil
        } catch {
            // Ignore cancellation errors - they happen when views are recreated
            if (error as NSError).code == NSURLErrorCancelled {
                if updateLoading { isLoading = false }
                return
            }
            if items.isEmpty {
                self.error = error.localizedDescription
            }
        }
        if updateLoading { isLoading = false }
    }

    /// Load more items for infinite scroll
    private func loadMoreItems() async {
        guard hasMoreItems,
              !isLoadingMore,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoadingMore = true

        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: items.count,
                size: pageSize,
                sort: currentSortOption.apiParameter
            )

            // Update total count
            if let total = result.totalSize {
                totalItemCount = total
            }

            if result.items.isEmpty {
                // No more items
                hasMoreItems = false
            } else {
                // Append new items, avoiding duplicates
                let existingKeys = Set(items.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !existingKeys.contains(key)
                }

                if !newItems.isEmpty {
                    items.append(contentsOf: newItems)
                    if let firstItem = items.first {
                        if firstItem.type == "movie" {
                            await cacheManager.cacheMovies(items, forLibrary: libraryKey)
                        } else if firstItem.type == "show" {
                            await cacheManager.cacheShows(items, forLibrary: libraryKey)
                        }
                    }
                }

                // Check if we've reached the end
                if let total = result.totalSize {
                    hasMoreItems = items.count < total
                } else {
                    hasMoreItems = result.items.count >= pageSize
                }
            }
        } catch {
            // Ignore errors for pagination - just stop loading more
            if (error as NSError).code != NSURLErrorCancelled {
                print("Failed to load more items: \(error)")
            }
        }

        isLoadingMore = false
    }

    /// Compare two item arrays by ratingKey to avoid unnecessary state updates
    private func itemsAreEqual(_ lhs: [PlexMetadata], _ rhs: [PlexMetadata]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        // Compare by ratingKey which is the unique identifier
        let lhsKeys = lhs.compactMap { $0.ratingKey }
        let rhsKeys = rhs.compactMap { $0.ratingKey }
        return lhsKeys == rhsKeys
    }

    private func fetchLibraryHubs(serverURL: String, token: String) async {
        do {
            let fetchedHubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey
            )

            // Only update hubs if they're actually different
            if !hubsAreEqual(hubs, fetchedHubs) {
                hubs = fetchedHubs
                cachedProcessedHubs = computeProcessedHubs(from: fetchedHubs)
            }

            // Write back to DataStore for cross-view sharing
            dataStore.libraryHubs[libraryKey] = fetchedHubs
            dataStore.recordFetch(for: "libraryHubs:\(libraryKey)")

            // Cache for instant loading next time
            await cacheManager.cacheLibraryHubs(fetchedHubs, forLibrary: libraryKey)
        } catch {
            // Ignore cancellation errors
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            print("📚 Failed to fetch hubs for library \(libraryKey): \(error)")
            // Don't show error for hubs - they're optional enhancement
        }
    }

    /// Compare two hub arrays to avoid unnecessary state updates
    private func hubsAreEqual(_ lhs: [PlexHub], _ rhs: [PlexHub]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        // Compare by hubIdentifier and item counts
        for (l, r) in zip(lhs, rhs) {
            if l.hubIdentifier != r.hubIdentifier { return false }
            if l.Metadata?.count != r.Metadata?.count { return false }
        }
        return true
    }

    private func refresh() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoading = true
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: true)
        async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
        _ = await (itemsFetch, hubsFetch)

        if enablePersonalizedRecommendations {
            await refreshRecommendations(force: true)
        }
    }

    // MARK: - Focus Management

    /// Prefetch poster images for visible and upcoming items
    private func prefetchImages() {
        guard !items.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        hasPrefetched = true

        // Prefetch first 20 items (visible + next row)
        let prefetchCount = min(20, items.count)
        let urlsToPreload: [URL] = items.prefix(prefetchCount).compactMap { item in
            guard let thumb = posterThumb(for: item) else { return nil }
            var urlString = "\(serverURL)\(thumb)"
            if !urlString.contains("X-Plex-Token") {
                urlString += urlString.contains("?") ? "&" : "?"
                urlString += "X-Plex-Token=\(token)"
            }
            return URL(string: urlString)
        }

        // Fire off prefetch in background
        Task.detached(priority: .background) {
            await ImageCacheManager.shared.prefetch(urls: urlsToPreload)
        }
    }

    /// Prefetch images ahead of the current scroll position
    /// Called frequently to ensure images are loaded before user reaches them
    private func prefetchImagesAhead(from index: Int) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Prefetch the next 30 items (~5 rows of 6) ahead of current position
        let prefetchStart = index + 3  // Start just ahead of current position
        let prefetchEnd = min(prefetchStart + 30, items.count)

        guard prefetchStart < items.count else { return }

        let itemsToPrefetch = Array(items[prefetchStart..<prefetchEnd])
        guard !itemsToPrefetch.isEmpty else { return }

        let urlsToPreload: [URL] = itemsToPrefetch.compactMap { item in
            guard let thumb = posterThumb(for: item) else { return nil }
            var urlString = "\(serverURL)\(thumb)"
            if !urlString.contains("X-Plex-Token") {
                urlString += urlString.contains("?") ? "&" : "?"
                urlString += "X-Plex-Token=\(token)"
            }
            return URL(string: urlString)
        }

        guard !urlsToPreload.isEmpty else { return }

        // Fire off prefetch with utility priority for timely loading
        Task.detached(priority: .utility) {
            await ImageCacheManager.shared.prefetch(urls: urlsToPreload)
        }
    }

    /// Handle items count change - triggers prefetch on tvOS
    private func handleItemsCountChange(oldCount: Int, newCount: Int) {
        // Batching disabled — LazyVGrid handles lazy rendering natively.
        // if newCount == 0 {
        //     visibleItemExpandTask?.cancel()
        //     visibleItemCount = 0
        // } else if oldCount == 0 {
        //     updateVisibleItems(for: newCount, animated: true)
        // } else if newCount > visibleItemCount {
        //     updateVisibleItems(for: newCount, animated: false)
        // }

        if oldCount == 0 && newCount > 0 {
            prefetchImages()
        } else if !hasPrefetched && newCount > 0 {
            prefetchImages()
        }
        ensureInitialFocusIfNeeded()
    }

    // Batching disabled — LazyVGrid handles lazy rendering natively.
    // Uncomment if first-load performance regresses.
    /*
    /// Limit first-frame grid layout to a small batch, then reveal the rest
    private func updateVisibleItems(for total: Int, animated: Bool) {
        guard total > 0 else {
            visibleItemCount = 0
            return
        }

        visibleItemExpandTask?.cancel()

        // If we're already showing most items, just jump to total
        if !animated || total <= initialVisibleBatch {
            visibleItemCount = total
            return
        }

        let initial = min(initialVisibleBatch, total)
        visibleItemCount = initial

        visibleItemExpandTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
            await MainActor.run {
                visibleItemCount = total
            }
        }
    }
    */

    /// Ensure the first grid item receives focus when entering a library
    private func ensureInitialFocusIfNeeded() {
        guard focusedItemId == nil else { return }
        guard let first = firstDisplayedItem else { return }

        focusedItemId = gridFocusId(for: first)
    }

    private func posterThumb(for item: PlexMetadata) -> String? {
        if item.type == "episode" {
            return item.grandparentThumb ?? item.parentThumb ?? item.thumb
        }
        return item.thumb
    }
}

#Preview {
    NavigationStack {
        PlexLibraryView(libraryKey: "1", libraryTitle: "Movies")
    }
}
