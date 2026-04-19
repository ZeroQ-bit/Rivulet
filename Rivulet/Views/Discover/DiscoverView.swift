//
//  DiscoverView.swift
//  Rivulet
//
//  Top-level Discover page. Fixed TMDB hero backdrop behind a scroll view
//  containing the hero overlay (Add to Watchlist / Details for in-library
//  items) and 8 TMDB curated sections plus For You. All entry points route
//  into the unified preview carousel.
//

import SwiftUI
import Combine

struct DiscoverView: View {
    @StateObject private var viewModel = DiscoverViewModel()
    @StateObject private var watchlist = PlexWatchlistService.shared

    @State private var rowPreviewRequest: PreviewRequest?
    @State private var showPreviewCover = false
    @State private var capturedSourceFrames: [PreviewSourceTarget: CGRect] = [:]
    @State private var previewRestoreTarget: PreviewSourceTarget?

    @State private var heroCurrentIndex: Int = 0
    @State private var heroScrollOffset: CGFloat = 0

    var body: some View {
        mainBody
            .watchlistToast(message: watchlist.transientWriteError)
    }

    private var mainBody: some View {
        let screenHeight = UIScreen.main.bounds.height
        let heroSectionHeight = screenHeight - 200
        let heroActive = !viewModel.heroItems.isEmpty
        let currentHeroItem: MediaItem? = {
            guard heroActive else { return nil }
            let clamped = max(0, min(heroCurrentIndex, viewModel.heroItems.count - 1))
            return viewModel.heroItems[clamped]
        }()

        return ZStack(alignment: .top) {
            // Fixed backdrop — fills the screen, parallaxes with scroll.
            if heroActive {
                DiscoverHeroBackdrop(currentItem: currentHeroItem)
                    .ignoresSafeArea()
                    .offset(y: -heroScrollOffset * 1.3 - min(122, heroScrollOffset * 1.22))
                    .allowsHitTesting(false)
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if heroActive {
                            DiscoverHeroOverlay(
                                items: viewModel.heroItems,
                                currentIndex: $heroCurrentIndex,
                                onSelect: emitPreviewRequest,
                                onHeroFocused: {
                                    withAnimation(.smooth(duration: 0.8)) {
                                        scrollProxy.scrollTo("discoverHero", anchor: .top)
                                    }
                                }
                            )
                            .frame(height: heroSectionHeight)
                            .focusSection()
                            .id("discoverHero")
                        }

                        VStack(alignment: .leading, spacing: 40) {
                            ForEach(TMDBDiscoverSection.allCases) { section in
                                let items = viewModel.items(for: section)
                                if !items.isEmpty {
                                    DiscoverRow(
                                        title: section.title,
                                        items: items,
                                        isInLibrary: { $0.plexMatch != nil },
                                        isOnWatchlist: { item in
                                            guard let tmdbId = item.tmdbId else { return false }
                                            return watchlist.contains(tmdbId: tmdbId)
                                        },
                                        onSelect: emitPreviewRequest
                                    )
                                }
                            }

                            // "For You" trails the curated sections.
                            if !viewModel.forYou.isEmpty {
                                DiscoverRow(
                                    title: "For You",
                                    items: viewModel.forYou,
                                    isInLibrary: { $0.plexMatch != nil },
                                    isOnWatchlist: { item in
                                        guard let tmdbId = item.tmdbId else { return false }
                                        return watchlist.contains(tmdbId: tmdbId)
                                    },
                                    onSelect: emitPreviewRequest
                                )
                            }
                        }
                        .padding(.top, heroActive ? 0 : 48)
                        .padding(.bottom, 40)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    heroScrollOffset = max(0, offset)
                }
                .scrollClipDisabled()
                .ignoresSafeArea(.container, edges: heroActive ? [.top, .horizontal] : [])
            }
        }
        .task { await viewModel.load() }
        .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
            GeometryReader { proxy in
                Color.clear
                    .hidden()
                    .task(id: anchors.count) {
                        capturedSourceFrames = Dictionary(
                            uniqueKeysWithValues: anchors.map { ($0.key, proxy[$0.value]) }
                        )
                    }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: showPreviewCover) { _, isShowing in
            if isShowing, let request = rowPreviewRequest {
                presentPreview(request: request)
            }
        }
    }

    private func emitPreviewRequest(_ request: PreviewRequest) {
        withAnimation(previewEntryAnimation) {
            rowPreviewRequest = request
            showPreviewCover = true
        }
    }

    // MARK: - Preview Presentation (UIKit Modal — mirrors PlexHomeView)

    private func presentPreview(request: PreviewRequest) {
        let menuBridge = PreviewMenuBridge()
        let auth = PlexAuthManager.shared

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: capturedSourceFrames,
            serverURL: auth.selectedServerURL ?? "",
            authToken: auth.selectedServerToken ?? "",
            onDismiss: { [weak menuBridge] sourceTarget in
                _ = menuBridge
                previewRestoreTarget = sourceTarget
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    if let previewVC = topVC as? PreviewContainerViewController {
                        previewVC.dismissPreview()
                    }
                }
            },
            menuBridge: menuBridge
        )

        let container = PreviewContainerViewController(
            content: previewContent,
            menuHandler: { menuBridge.triggerMenu() }
        )
        container.onDismiss = {
            showPreviewCover = false
            rowPreviewRequest = nil
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(container, animated: false)
        }
    }
}

// MARK: - View Model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var sectionItems: [TMDBDiscoverSection: [MediaItem]] = [:]
    @Published private(set) var forYou: [MediaItem] = []
    @Published private(set) var heroItems: [MediaItem] = []
    @Published private(set) var loading = false

    private let discoverService = TMDBDiscoverService.shared
    private let recommendationService = DiscoverRecommendationService.shared
    private let libraryIndex = LibraryGUIDIndex.shared

    /// Minimum watched items required before we try to personalize the "For You"
    /// row. Fewer watches produce noisy recommendations that feel random.
    private let forYouColdStartMinWatched = 5

    /// Cap on hero carousel items. Matches the home page's cap.
    private let heroItemCap = 9

    func load() async {
        loading = true
        defer { loading = false }

        // Fetch all 8 sections in parallel, then convert each TMDB list into
        // MediaItem (which resolves any in-library Plex match per item).
        await withTaskGroup(of: (TMDBDiscoverSection, [MediaItem]).self) { group in
            for section in TMDBDiscoverSection.allCases {
                group.addTask { [discoverService] in
                    let raw = await discoverService.fetchSection(section)
                    var converted: [MediaItem] = []
                    for tmdb in raw {
                        converted.append(await MediaItem.from(tmdb: tmdb))
                    }
                    return (section, converted)
                }
            }
            for await (section, items) in group {
                sectionItems[section] = items
            }
        }

        // Pick hero items from the same popular sources the home page uses.
        heroItems = computeHeroItems(cap: heroItemCap)

        // Warm the image cache for every hero backdrop/poster so paging the
        // carousel doesn't flash a blank frame while the image downloads.
        prefetchHeroAssets(heroItems)

        // "For You" appends below the curated sections once watch-history
        // features resolve, so it doesn't shift the layout out from under
        // the user. Hides itself on cold-start (too few watched items).
        let watchedItems = await collectWatchHistory()
        if watchedItems.count >= forYouColdStartMinWatched {
            let profile = await WatchProfileBuilder.build(from: watchedItems)
            let raw = await recommendationService.forYouRow(profile: profile)
            var converted: [MediaItem] = []
            for tmdb in raw {
                converted.append(await MediaItem.from(tmdb: tmdb))
            }
            forYou = converted
        } else {
            forYou = []
        }
    }

    func items(for section: TMDBDiscoverSection) -> [MediaItem] {
        sectionItems[section] ?? []
    }

    /// Warm the image cache for the full hero carousel so paging doesn't
    /// trigger a blank flash.
    private func prefetchHeroAssets(_ items: [MediaItem]) {
        let urls = items.flatMap { item -> [URL] in
            [item.backdropURL, item.posterURL].compactMap { $0 }
        }
        guard !urls.isEmpty else { return }
        Task { await ImageCacheManager.shared.prefetch(urls: urls) }
    }

    /// Interleave Popular Movies + Popular TV (already fetched for the curated
    /// rows) to seed the hero carousel. Prefers items with backdrops.
    private func computeHeroItems(cap: Int) -> [MediaItem] {
        let movies = sectionItems[.moviePopular] ?? []
        let shows = sectionItems[.tvPopular] ?? []

        var interleaved: [MediaItem] = []
        let count = max(movies.count, shows.count)
        for i in 0..<count {
            if i < movies.count { interleaved.append(movies[i]) }
            if i < shows.count { interleaved.append(shows[i]) }
            if interleaved.count >= cap * 2 { break }
        }

        let ranked = interleaved.sorted { (a, b) in
            let aHas = (a.backdropURL != nil) ? 1 : 0
            let bHas = (b.backdropURL != nil) ? 1 : 0
            return aHas > bHas
        }

        return Array(ranked.prefix(cap))
    }

    private func collectWatchHistory() async -> [PlexMetadata] {
        let dataStore = PlexDataStore.shared
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken else { return [] }
        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = dataStore.visibleVideoLibraries

        var watched: [PlexMetadata] = []
        for library in visibleLibraries.prefix(3) {  // Cap to keep latency sane
            if let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: 200
            ) {
                watched.append(contentsOf: result.items.filter { ($0.viewCount ?? 0) > 0 })
            }
        }
        return Array(watched.prefix(120))
    }
}
