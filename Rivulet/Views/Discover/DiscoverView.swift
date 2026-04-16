//
//  DiscoverView.swift
//  Rivulet
//
//  Top-level Discover page. Renders 8 TMDB sections plus an optional For You
//  row driven by the user's watch history.
//

import SwiftUI
import Combine

struct DiscoverView: View {
    @StateObject private var viewModel = DiscoverViewModel()
    @StateObject private var watchlist = PlexWatchlistService.shared

    @State private var presentedPlexItem: PlexMetadata?
    @State private var presentedTMDBItem: TMDBListItem?

    var body: some View {
        mainBody
            .watchlistToast(message: watchlist.transientWriteError)
    }

    private var mainBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(TMDBDiscoverSection.allCases) { section in
                    let items = viewModel.items(for: section)
                    if !items.isEmpty {
                        DiscoverRow(
                            title: section.title,
                            items: items,
                            isInLibrary: { viewModel.inLibraryTMDBIds.contains($0.id) },
                            isOnWatchlist: { watchlist.contains(tmdbId: $0.id) },
                            onSelect: { handleSelection($0) }
                        )
                    }
                }

                // "For You" trails the curated sections so its async load
                // (watch-history profile build + TMDB discover call) doesn't
                // push other rows down when it resolves.
                if !viewModel.forYou.isEmpty {
                    DiscoverRow(
                        title: "For You",
                        items: viewModel.forYou,
                        isInLibrary: { _ in false },  // For You is always not-in-library (filtered upstream)
                        isOnWatchlist: { watchlist.contains(tmdbId: $0.id) },
                        onSelect: { handleSelection($0) }
                    )
                }
            }
            .padding(.vertical, 40)
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $presentedPlexItem) { metadata in
            PlexDetailView(item: metadata)
                .presentationBackground(.black)
        }
        .fullScreenCover(item: $presentedTMDBItem) { item in
            TMDBItemDetailView(item: item)
                .presentationBackground(.black)
        }
    }

    private func handleSelection(_ item: TMDBListItem) {
        Task {
            if let plex = await viewModel.libraryMatch(for: item) {
                presentedPlexItem = plex
            } else {
                presentedTMDBItem = item
            }
        }
    }
}

// MARK: - View Model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var sectionItems: [TMDBDiscoverSection: [TMDBListItem]] = [:]
    @Published private(set) var forYou: [TMDBListItem] = []
    @Published private(set) var inLibraryTMDBIds: Set<Int> = []
    @Published private(set) var loading = false

    private let discoverService = TMDBDiscoverService.shared
    private let recommendationService = DiscoverRecommendationService.shared
    private let libraryIndex = LibraryGUIDIndex.shared

    /// Minimum watched items required before we try to personalize the "For You"
    /// row. Fewer watches produce noisy recommendations that feel random.
    private let forYouColdStartMinWatched = 5

    func load() async {
        loading = true
        defer { loading = false }

        // Fetch all 8 sections in parallel.
        await withTaskGroup(of: (TMDBDiscoverSection, [TMDBListItem]).self) { group in
            for section in TMDBDiscoverSection.allCases {
                group.addTask { [discoverService] in
                    let items = await discoverService.fetchSection(section)
                    return (section, items)
                }
            }
            for await (section, items) in group {
                sectionItems[section] = items
            }
        }

        // Precompute the in-library TMDB id set for sync lookup from row closures.
        await recomputeInLibrarySet()

        // "For You" appends below the curated sections once watch-history
        // features resolve, so it doesn't shift the layout out from under
        // the user. Hides itself on cold-start (too few watched items to
        // produce a meaningful profile).
        let watchedItems = await collectWatchHistory()
        if watchedItems.count >= forYouColdStartMinWatched {
            let profile = await WatchProfileBuilder.build(from: watchedItems)
            forYou = await recommendationService.forYouRow(profile: profile)
        } else {
            forYou = []
        }
    }

    func items(for section: TMDBDiscoverSection) -> [TMDBListItem] {
        sectionItems[section] ?? []
    }

    func libraryMatch(for item: TMDBListItem) async -> PlexMetadata? {
        await libraryIndex.lookup(tmdbId: item.id, type: item.mediaType)
    }

    /// Rebuild `inLibraryTMDBIds` by asking the library index for each fetched item.
    /// This runs after section items load. Single pass, one actor hop per id — cheap.
    private func recomputeInLibrarySet() async {
        let allIds = sectionItems.values.flatMap { $0.map { ($0.id, $0.mediaType) } }
        var newSet: Set<Int> = []
        for (id, mediaType) in allIds {
            if await libraryIndex.lookup(tmdbId: id, type: mediaType) != nil {
                newSet.insert(id)
            }
        }
        inLibraryTMDBIds = newSet
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
