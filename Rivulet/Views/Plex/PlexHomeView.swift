//
//  PlexHomeView.swift
//  Rivulet
//
//  Home screen for Plex with Continue Watching and Recently Added
//

import SwiftUI
import Combine
import UIKit
import os.log

private let homeLog = Logger(subsystem: "com.rivulet.app", category: "PlexHome")

private struct HomeCatalogSection: Identifiable {
    let id: String
    let title: String
    let items: [PlexMetadata]
    let hubKey: String?
    let hubIdentifier: String?
    let isContinueWatching: Bool
    let serverURL: String
    let authToken: String
    let usesReadOnlyDetail: Bool
    let contextMenuSource: MediaItemContextSource
    let refreshAction: (() async -> Void)?
    let previewAction: ((PreviewRequest) -> Void)?
}

private struct HomeDiscoverNavigationTarget: Identifiable, Hashable {
    let item: PlexMetadata
    let assetServerURL: String
    let assetAuthToken: String

    var id: String {
        let key = item.ratingKey ?? item.guid ?? item.key ?? item.title ?? UUID().uuidString
        return "\(assetServerURL)|\(key)"
    }
}

struct PlexHomeView: View {
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @AppStorage("showHomeHero") private var showHomeHero = true
    @AppStorage("didMigrateHomeHeroDefault") private var didMigrateHomeHeroDefault = false
    @AppStorage("showLibraryRecommendations") private var showDiscoveryRows = true
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false
    @AppStorage("mediaOpenStyle") private var mediaOpenStyleRaw = MediaOpenStyle.previewCard.rawValue
    @Environment(\.nestedNavigationState) private var nestedNavState
    @State private var selectedItem: PlexMetadata?
    @State private var selectedDiscoverItem: HomeDiscoverNavigationTarget?
    @State private var heroItems: [PlexMetadata] = []
    @State private var heroCurrentIndex: Int = 0
    @State private var cachedProcessedHubs: [PlexHub] = []  // Memoized to avoid recalculation on every render
    @State private var discoverHubs: [PlexHub] = []
    @State private var isLoadingDiscoverHubs = false
    @State private var discoverHubsError: String?
    @State private var recommendations: [PlexMetadata] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationsError: String?
    @State private var rowPreviewRequest: PreviewRequest?
    @State private var previewRestoreTarget: PreviewSourceTarget?
    @State private var capturedSourceFrames: [PreviewSourceTarget: CGRect] = [:]
    @State private var showPreviewCover = false
    @State private var currentCatalogIndex: Int = 0
    @State private var currentCatalogID: String?
    @State private var catalogFocusRequestID = UUID()
    @State private var heroFocusRequestID = UUID()
    @State private var catalogFocusTargets: [String: String] = [:]
    @State private var lastCatalogNavigationAt: Date = .distantPast

    private let recommendationService = PersonalizedRecommendationService.shared
    private let networkManager = PlexNetworkManager.shared
    private let recommendationsContentType: RecommendationContentType = .moviesAndShows
    private let catalogNavigationCooldown: TimeInterval = 0.24

    private var mediaOpenStyle: MediaOpenStyle {
        MediaOpenStyle(rawValue: mediaOpenStyleRaw) ?? .previewCard
    }

    // MARK: - Processed Hubs

    /// Home's server-backed hubs are limited to Continue Watching.
    /// Library-specific recent/discovery rows belong on the library pages.
    private func computeProcessedHubs(from hubsToProcess: [PlexHub]) -> [PlexHub] {
        if let continueWatchingHub = extractContinueWatchingHub(from: hubsToProcess) {
            return [continueWatchingHub]
        }
        return []
    }

    /// Extract Continue Watching / On Deck items and merge into a single hub
    private func extractContinueWatchingHub(from hubs: [PlexHub]) -> PlexHub? {
        var continueWatchingItems: [PlexMetadata] = []
        var seenRatingKeys: Set<String> = []

        for hub in hubs {
            if isContinueWatchingHub(hub) {
                if let items = hub.Metadata {
                    for item in items {
                        if let key = item.ratingKey, !seenRatingKeys.contains(key) {
                            seenRatingKeys.insert(key)
                            continueWatchingItems.append(item)
                        }
                    }
                }
            }
        }

        guard !continueWatchingItems.isEmpty else { return nil }

        // Sort by lastViewedAt (most recent first)
        continueWatchingItems.sort { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }

        var mergedHub = PlexHub()
        mergedHub.hubIdentifier = "continueWatching"
        mergedHub.title = "Continue Watching"
        mergedHub.Metadata = continueWatchingItems
        return mergedHub
    }

    /// Check if a hub is a Continue Watching or On Deck hub
    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("continuewatching") ||
               identifier.contains("ondeck") ||
               title.contains("continue watching") ||
               title.contains("on deck")
    }

    /// Check if a hub is a Recently Added hub
    private func isRecentlyAddedHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("recentlyadded") ||
               title.contains("recently added")
    }

    private var selectedServerURL: String {
        authManager.selectedServerURL ?? ""
    }

    private var selectedServerToken: String {
        authManager.selectedServerToken ?? ""
    }

    private var discoverAuthToken: String {
        authManager.authToken ?? ""
    }

    private func updateHomeContentReady() {
        let hasSections = !homeCatalogSections.isEmpty
        let discoverSettled = !showDiscoveryRows || !isLoadingDiscoverHubs
        let recommendationsSettled = !enablePersonalizedRecommendations || !isLoadingRecommendations
        dataStore.isHomeContentReady = hasSections || (!dataStore.isLoadingHubs && discoverSettled && recommendationsSettled)
    }

    private func refreshDiscoverHubs(force: Bool = false) async {
        guard showDiscoveryRows else {
            await MainActor.run {
                isLoadingDiscoverHubs = false
                discoverHubsError = nil
                updateHomeContentReady()
            }
            return
        }

        let token = discoverAuthToken
        guard !token.isEmpty else {
            await MainActor.run {
                discoverHubs = []
                isLoadingDiscoverHubs = false
                discoverHubsError = nil
                updateHomeContentReady()
            }
            return
        }

        await MainActor.run {
            if force || discoverHubs.isEmpty {
                isLoadingDiscoverHubs = true
            }
            discoverHubsError = nil
        }

        do {
            let hubs = try await networkManager.getDiscoverHubs(authToken: token)
            let usableHubs = hubs.compactMap { hub -> PlexHub? in
                guard let items = hub.Metadata, !items.isEmpty else { return nil }
                var cleanedHub = hub
                cleanedHub.Metadata = items
                return cleanedHub
            }

            await MainActor.run {
                discoverHubs = usableHubs
                isLoadingDiscoverHubs = false
                discoverHubsError = nil
                updateHomeContentReady()
            }
        } catch {
            await MainActor.run {
                if force {
                    discoverHubs = []
                }
                discoverHubsError = error.localizedDescription
                isLoadingDiscoverHubs = false
                updateHomeContentReady()
            }
        }
    }

    private func showDetail(for item: PlexMetadata, in section: HomeCatalogSection? = nil) {
        if let section, section.usesReadOnlyDetail {
            selectedItem = nil
            selectedDiscoverItem = HomeDiscoverNavigationTarget(
                item: item,
                assetServerURL: section.serverURL,
                assetAuthToken: section.authToken
            )
        } else {
            selectedDiscoverItem = nil
            selectedItem = item
        }
    }

    private func handlePreviewRequest(_ request: PreviewRequest) {
        if mediaOpenStyle == .fullScreenDetail {
            guard request.items.indices.contains(request.selectedIndex) else { return }
            rowPreviewRequest = nil
            showPreviewCover = false
            selectedDiscoverItem = nil
            selectedItem = request.items[request.selectedIndex]
            return
        }

        rowPreviewRequest = request
        showPreviewCover = true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if !authManager.hasCredentials {
                    notConnectedView
                } else {
                    contentView
                }
            }
            .refreshable {
                await dataStore.refreshHubs()
                if showDiscoveryRows {
                    await refreshDiscoverHubs(force: true)
                }
                if enablePersonalizedRecommendations {
                    await refreshRecommendations(force: true)
                }
                await MainActor.run {
                    updateHomeContentReady()
                }
            }
            .onAppear {
                if !didMigrateHomeHeroDefault {
                    if showHomeHero == false {
                        showHomeHero = true
                    }
                    didMigrateHomeHeroDefault = true
                }
                homeLog.info("PlexHomeView onAppear — cachedHubs=\(self.cachedProcessedHubs.count), dataStoreHubs=\(self.dataStore.hubs.count)")
                // Initial computation of processed hubs
                if cachedProcessedHubs.isEmpty && !dataStore.hubs.isEmpty {
                    cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                }
                updateHomeContentReady()
                // Only select hero if we don't have one yet
                if heroItems.isEmpty {
                    selectHeroItems()
                }
                if showDiscoveryRows && discoverHubs.isEmpty {
                    Task { await refreshDiscoverHubs(force: false) }
                }
                if enablePersonalizedRecommendations && recommendations.isEmpty {
                    Task { await refreshRecommendations(force: false) }
                }
            }
            .task(id: dataStore.libraries.count) {
                guard !dataStore.libraries.isEmpty else { return }
                dataStore.librarySettings.initializeHomeVisibility(for: dataStore.libraries)
            }
            .onChange(of: dataStore.hubsVersion) { _, _ in
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                selectHeroItems()
                updateHomeContentReady()
            }
            .onChange(of: dataStore.isLoadingHubs) { _, _ in
                updateHomeContentReady()
            }
            .onChange(of: showDiscoveryRows) { _, _ in
                if showDiscoveryRows {
                    updateHomeContentReady()
                    Task { await refreshDiscoverHubs(force: discoverHubs.isEmpty) }
                } else {
                    updateHomeContentReady()
                }
            }
            .onChange(of: enablePersonalizedRecommendations) { _, _ in
                handleRecommendationsToggle()
            }
            .onChange(of: authManager.authToken) { _, _ in
                guard showDiscoveryRows else { return }
                Task { await refreshDiscoverHubs(force: true) }
            }
            // Refresh hubs when notified (e.g., after playback ends, watch status changes)
            .onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)) { _ in
                Task {
                    await dataStore.refreshHubs()
                    if showDiscoveryRows {
                        await refreshDiscoverHubs(force: true)
                    }
                    if enablePersonalizedRecommendations {
                        await refreshRecommendations(force: true)
                    }
                    await MainActor.run {
                        updateHomeContentReady()
                    }
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                PlexDetailView(item: item)
            }
            .navigationDestination(item: $selectedDiscoverItem) { target in
                PlexDetailView(
                    item: target.item,
                    allowActionRowInteraction: false,
                    enableDetailDataLoading: false,
                    assetServerURL: target.assetServerURL,
                    assetAuthToken: target.assetAuthToken
                )
            }
            .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
                // Resolve anchor frames into CGRects
                GeometryReader { proxy in
                    Color.clear
                        .hidden()
                        .task(id: anchors.count) {
                            capturedSourceFrames = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key, proxy[$0.value]) })
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
        .onChange(of: selectedItem) { _, newValue in
            print("[PlexHome] selectedItem changed: \(newValue?.title ?? "nil") (ratingKey: \(newValue?.ratingKey ?? "nil"))")
            updateNestedNavigationState()
        }
        .onChange(of: selectedDiscoverItem) { _, newValue in
            print("[PlexHome] selectedDiscoverItem changed: \(newValue?.item.title ?? "nil")")
            updateNestedNavigationState()
        }
        // Handle navigation from player (Go to Season / Go to Show)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToContent)) { notification in
            guard let ratingKey = notification.userInfo?["ratingKey"] as? String else { return }

            // Fetch metadata and navigate
            Task {
                do {
                    let metadata = try await PlexNetworkManager.shared.getMetadata(
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        ratingKey: ratingKey
                    )
                    await MainActor.run {
                        selectedItem = metadata
                    }
                } catch {
                    print("❌ [Navigation] Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
                }
            }
        }
    }

    // MARK: - Direct Playback (Continue Watching)

    /// Play an item directly without navigating to detail view
    private func playItemDirectly(_ item: PlexMetadata, fromBeginning: Bool = false) {
        Task {
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }

            let (artImage, thumbImage) = await getPlayerImages(for: item, serverURL: serverURL, authToken: token)

            await MainActor.run {
                let resumeOffset: Double? = if fromBeginning {
                    nil
                } else {
                    item.viewOffset.map { Double($0) / 1000.0 }
                }

                let viewModel = UniversalPlayerViewModel(
                    metadata: item,
                    serverURL: serverURL,
                    authToken: token,
                    startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let useApplePlayer = PlaybackPreferences.useApplePlayer
                let playerVC: UIViewController
                if useApplePlayer {
                    let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                    nativePlayer.onDismiss = {
                        Task { await dataStore.refreshHubs() }
                    }
                    playerVC = nativePlayer
                } else {
                    let inputCoordinator = PlaybackInputCoordinator()
                    let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)
                    let container = PlayerContainerViewController(
                        rootView: playerView,
                        viewModel: viewModel,
                        inputCoordinator: inputCoordinator
                    )
                    container.onDismiss = {
                        Task { await dataStore.refreshHubs() }
                    }
                    playerVC = container
                }

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(playerVC, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen
    private func getPlayerImages(for metadata: PlexMetadata, serverURL: String, authToken: String) async -> (UIImage?, UIImage?) {
        let request = metadata.heroBackdropRequest(
            serverURL: serverURL,
            authToken: authToken
        )
        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - Preview Presentation (UIKit Modal)

    private func presentPreview(request: PreviewRequest) {
        let menuBridge = PreviewMenuBridge()

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: capturedSourceFrames,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            onDismiss: { [weak menuBridge] sourceTarget in
                _ = menuBridge  // prevent retain cycle warning
                previewRestoreTarget = sourceTarget
                // Find and dismiss the preview VC
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
            menuHandler: {
                menuBridge.triggerMenu()
            }
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

    // MARK: - Hero Selection

    private static let heroItemCap = 15

    /// Populates `heroItems` from the best available hub for the home screen.
    /// Priority: Plex "promoted" hub (global), then Recently Added, then the first non-empty hub.
    /// Results are capped at `heroItemCap` and cached per-screen via `PlexDataStore`.
    private func selectHeroItems() {
        // Cached result takes precedence on first appearance so navigation feels instant.
        if heroItems.isEmpty,
           let cached = dataStore.getCachedHeroItems(forLibrary: "home"),
           !cached.isEmpty {
            heroItems = cached
            return
        }

        let candidates = computeHeroItems(from: dataStore.hubs)
        guard !candidates.isEmpty else { return }

        // Avoid rebuilding the carousel when the promoted hub is unchanged.
        let newKeys = candidates.compactMap { $0.ratingKey }
        let currentKeys = heroItems.compactMap { $0.ratingKey }
        if newKeys != currentKeys {
            heroItems = candidates
        }
        dataStore.cacheHeroItems(candidates, forLibrary: "home")
    }

    /// Pure helper so the selection logic can be unit-tested or reused elsewhere.
    private func computeHeroItems(from hubs: [PlexHub]) -> [PlexMetadata] {
        let promoted = hubs.first { hub in
            (hub.hubIdentifier?.lowercased().contains("promoted") == true)
                && (hub.Metadata?.isEmpty == false)
        }
        if let items = promoted?.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Using promoted hub \(promoted?.hubIdentifier ?? "?", privacy: .public) with \(items.count) items")
            return Array(items.prefix(Self.heroItemCap))
                .filter { $0.ratingKey != nil }
        }

        let recentlyAdded = hubs.first { isRecentlyAddedHub($0) && ($0.Metadata?.isEmpty == false) }
        if let items = recentlyAdded?.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Fallback to Recently Added hub with \(items.count) items")
            return Array(items.prefix(Self.heroItemCap))
                .filter { $0.ratingKey != nil }
        }

        if let firstHub = hubs.first(where: { $0.Metadata?.isEmpty == false }),
           let items = firstHub.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Fallback to first non-empty hub \(firstHub.hubIdentifier ?? "?", privacy: .public)")
            return Array(items.prefix(Self.heroItemCap))
                .filter { $0.ratingKey != nil }
        }

        return []
    }

    // MARK: - Recommendations

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
                contentType: recommendationsContentType
            )
            await MainActor.run {
                recommendations = items
                isLoadingRecommendations = false
                updateHomeContentReady()
            }
        } catch {
            await MainActor.run {
                recommendations = []
                recommendationsError = error.localizedDescription
                isLoadingRecommendations = false
                updateHomeContentReady()
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
            updateHomeContentReady()
        }
    }

    private func homeRowID(for hub: PlexHub, index: Int, source: String) -> String {
        let identifier = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
        return "home:\(source):\(index):\(identifier)"
    }

    private func updateNestedNavigationState() {
        nestedNavState.isNested = selectedItem != nil || selectedDiscoverItem != nil
    }

    private var homeCatalogSections: [HomeCatalogSection] {
        var sections = cachedProcessedHubs.enumerated().compactMap { index, hub -> HomeCatalogSection? in
            guard let items = hub.Metadata, !items.isEmpty else { return nil }

            let isContinueWatching = isContinueWatchingHub(hub)
            return HomeCatalogSection(
                id: homeRowID(for: hub, index: index, source: "server"),
                title: hub.title ?? "Unknown",
                items: items,
                hubKey: hub.key ?? hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                isContinueWatching: isContinueWatching,
                serverURL: selectedServerURL,
                authToken: selectedServerToken,
                usesReadOnlyDetail: false,
                contextMenuSource: isContinueWatching ? .continueWatching : .other,
                refreshAction: {
                    await dataStore.refreshHubs()
                },
                    previewAction: isContinueWatching ? nil : { request in
                        homeLog.info("[Preview] Opening carousel: \(request.items.count) items, tapped index=\(request.selectedIndex), title=\(request.items[request.selectedIndex].title ?? "?")")
                        handlePreviewRequest(request)
                    }
                )
            }

        if showDiscoveryRows {
            sections.append(contentsOf: discoverHubs.enumerated().compactMap { index, hub in
                guard let items = hub.Metadata, !items.isEmpty else { return nil }

                return HomeCatalogSection(
                    id: homeRowID(for: hub, index: index, source: "discover"),
                    title: hub.title ?? "Discover",
                    items: items,
                    hubKey: hub.key ?? hub.hubKey,
                    hubIdentifier: hub.hubIdentifier,
                    isContinueWatching: false,
                    serverURL: PlexAPI.discoverBaseUrl,
                    authToken: discoverAuthToken,
                    usesReadOnlyDetail: true,
                    contextMenuSource: .discover,
                    refreshAction: {
                        await refreshDiscoverHubs(force: true)
                    },
                    previewAction: nil
                )
            })
        }

        if !recommendations.isEmpty {
            sections.append(
                HomeCatalogSection(
                    id: "home:recommendations",
                    title: "Personalized Recommendations",
                    items: recommendations,
                    hubKey: nil,
                    hubIdentifier: nil,
                    isContinueWatching: false,
                    serverURL: selectedServerURL,
                    authToken: selectedServerToken,
                    usesReadOnlyDetail: false,
                    contextMenuSource: .other,
                    refreshAction: {
                        await refreshRecommendations(force: true)
                    },
                    previewAction: { request in
                        handlePreviewRequest(request)
                    }
                )
            )
        }

        return sections
    }

    private func resolvedCurrentCatalogIndex(in sections: [HomeCatalogSection]) -> Int? {
        guard !sections.isEmpty else { return nil }

        if let currentCatalogID,
           let index = sections.firstIndex(where: { $0.id == currentCatalogID }) {
            return index
        }

        return ensureValidCatalogIndex(currentCatalogIndex, in: sections)
    }

    private func ensureValidCatalogIndex(_ index: Int, in sections: [HomeCatalogSection]) -> Int {
        guard !sections.isEmpty else { return 0 }
        return min(max(index, 0), sections.count - 1)
    }

    private func catalogItemID(for item: PlexMetadata, rowID: String, index: Int) -> String {
        if let ratingKey = item.ratingKey {
            return ratingKey
        }
        return "\(rowID)-\(index)"
    }

    private func preferredCatalogFocusTarget(for section: HomeCatalogSection) -> String? {
        if let savedTarget = catalogFocusTargets[section.id],
           section.items.enumerated().contains(where: { index, item in
               catalogItemID(for: item, rowID: section.id, index: index) == savedTarget
           }) {
            return savedTarget
        }

        guard let first = section.items.first else { return nil }
        return catalogItemID(for: first, rowID: section.id, index: 0)
    }

    private func preferredCatalogFocusIndex(for section: HomeCatalogSection) -> Int {
        guard let target = preferredCatalogFocusTarget(for: section) else { return 0 }
        return section.items.enumerated().first(where: { index, item in
            catalogItemID(for: item, rowID: section.id, index: index) == target
        })?.offset ?? 0
    }

    private func reconcileCatalogSelection(with sections: [HomeCatalogSection]) {
        guard !sections.isEmpty else {
            currentCatalogIndex = 0
            currentCatalogID = nil
            heroCurrentIndex = 0
            return
        }

        let resolvedIndex = resolvedCurrentCatalogIndex(in: sections) ?? 0
        let resolvedSection = sections[resolvedIndex]
        let didChangeSection = currentCatalogID != resolvedSection.id

        currentCatalogIndex = resolvedIndex
        currentCatalogID = resolvedSection.id
        heroCurrentIndex = preferredCatalogFocusIndex(for: resolvedSection)

        if didChangeSection {
            catalogFocusRequestID = UUID()
        }
    }

    private func consumeVerticalCatalogNavigation() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCatalogNavigationAt) >= catalogNavigationCooldown else {
            return false
        }

        lastCatalogNavigationAt = now
        return true
    }

    private func focusActiveCatalog(in sections: [HomeCatalogSection]) {
        guard let resolvedIndex = resolvedCurrentCatalogIndex(in: sections) else { return }
        currentCatalogIndex = resolvedIndex
        currentCatalogID = sections[resolvedIndex].id
        heroCurrentIndex = preferredCatalogFocusIndex(for: sections[resolvedIndex])
        catalogFocusRequestID = UUID()
    }

    private func requestHeroFocus() {
        heroFocusRequestID = UUID()
    }

    private func moveToAdjacentCatalog(
        step: Int,
        in sections: [HomeCatalogSection],
        heroActive: Bool
    ) {
        guard !sections.isEmpty, consumeVerticalCatalogNavigation() else { return }

        let candidateIndex = (resolvedCurrentCatalogIndex(in: sections) ?? 0) + step
        while candidateIndex >= 0 && candidateIndex < sections.count {
            let section = sections[candidateIndex]
            currentCatalogIndex = candidateIndex
            currentCatalogID = section.id
            heroCurrentIndex = preferredCatalogFocusIndex(for: section)
            withAnimation(.easeInOut(duration: 0.24)) {
                catalogFocusRequestID = UUID()
            }
            return
        }

        if step < 0 && heroActive {
            requestHeroFocus()
        }
    }

    @ViewBuilder
    private func catalogNavigationHint(for sections: [HomeCatalogSection]) -> some View {
        if let resolvedIndex = resolvedCurrentCatalogIndex(in: sections) {
            let previousTitle = resolvedIndex > 0 ? sections[resolvedIndex - 1].title : nil
            let nextTitle = resolvedIndex < sections.count - 1 ? sections[resolvedIndex + 1].title : nil

            HStack(spacing: 18) {
                if let previousTitle {
                    Label(previousTitle, systemImage: "chevron.up")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                if let nextTitle {
                    Label(nextTitle, systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if sections.count > 1 {
                    Text("\(resolvedIndex + 1) / \(sections.count)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding + 4)
        }
    }

    @ViewBuilder
    private func activeCatalogStage(
        in sections: [HomeCatalogSection],
        heroActive: Bool
    ) -> some View {
        if let resolvedIndex = resolvedCurrentCatalogIndex(in: sections) {
            let activeSection = sections[resolvedIndex]

            VStack(alignment: .leading, spacing: 10) {
                InfiniteContentRow(
                    rowID: activeSection.id,
                    title: activeSection.title,
                    initialItems: activeSection.items,
                    hubKey: activeSection.hubKey,
                    hubIdentifier: activeSection.hubIdentifier,
                    serverURL: activeSection.serverURL,
                    authToken: activeSection.authToken,
                    isContinueWatching: activeSection.isContinueWatching,
                    contextMenuSource: activeSection.contextMenuSource,
                    onItemSelected: { item in
                        showDetail(for: item, in: activeSection)
                    },
                    onPlayItem: { item in
                        playItemDirectly(item)
                    },
                    onPlayFromBeginning: { item in
                        playItemDirectly(item, fromBeginning: true)
                    },
                    onGoToItem: { item in
                        showDetail(for: item, in: activeSection)
                    },
                    onRefreshNeeded: activeSection.refreshAction,
                    onPreviewRequested: activeSection.previewAction,
                    restorePreviewFocusTarget: $previewRestoreTarget,
                    presentationStyle: .pinnedStage,
                    preferredFocusItemID: preferredCatalogFocusTarget(for: activeSection),
                    focusRequestID: catalogFocusRequestID,
                    onItemFocusChanged: { target in
                        catalogFocusTargets[activeSection.id] = target
                        currentCatalogIndex = resolvedIndex
                        currentCatalogID = activeSection.id
                        if let newHeroIndex = activeSection.items.enumerated().first(where: { index, item in
                            catalogItemID(for: item, rowID: activeSection.id, index: index) == target
                        })?.offset {
                            heroCurrentIndex = newHeroIndex
                        }
                    },
                    onMoveUp: {
                        moveToAdjacentCatalog(step: -1, in: sections, heroActive: heroActive)
                    },
                    onMoveDown: {
                        moveToAdjacentCatalog(step: 1, in: sections, heroActive: heroActive)
                    }
                )
                .id(activeSection.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                catalogNavigationHint(for: sections)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
    }

    @MainActor
    private var currentScreenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
            .max() ?? 1080
    }

    // MARK: - Content View

    private var contentView: some View {
        let screenHeight = currentScreenHeight
        let heroSectionHeight = screenHeight - 200
        let catalogSections = homeCatalogSections
        let catalogSignature = catalogSections.map { section in
            let keySignature = section.items.prefix(10).enumerated().map { index, item in
                catalogItemID(for: item, rowID: section.id, index: index)
            }
            .joined(separator: ",")
            return "\(section.id)|\(section.items.count)|\(keySignature)"
        }
        let currentHeroSection: HomeCatalogSection? = {
            guard let resolvedIndex = resolvedCurrentCatalogIndex(in: catalogSections),
                  catalogSections.indices.contains(resolvedIndex) else { return nil }
            return catalogSections[resolvedIndex]
        }()
        let heroSourceItems = currentHeroSection?.items ?? heroItems
        let heroActive = showHomeHero && !heroSourceItems.isEmpty

        let currentHeroItem: PlexMetadata? = {
            guard heroActive, !heroSourceItems.isEmpty else { return nil }
            let clamped = max(0, min(heroCurrentIndex, heroSourceItems.count - 1))
            return heroSourceItems[clamped]
        }()
        let heroServerURL = currentHeroSection?.serverURL ?? selectedServerURL
        let heroAuthToken = currentHeroSection?.authToken ?? selectedServerToken

        return Group {
            if catalogSections.isEmpty {
                if dataStore.isLoadingHubs || isLoadingDiscoverHubs || (enablePersonalizedRecommendations && isLoadingRecommendations) {
                    homeStatusView(
                        accent: Color(red: 0.24, green: 0.48, blue: 0.92),
                        icon: "sparkles.tv.fill",
                        title: "Loading Home",
                        message: "Preparing your home catalogs.",
                        showsProgress: true
                    )
                } else if let hubsError = dataStore.hubsError, !showDiscoveryRows {
                    errorView(hubsError)
                } else if let discoverHubsError, showDiscoveryRows {
                    homeStatusView(
                        accent: .orange,
                        icon: "exclamationmark.triangle.fill",
                        title: "Discover Unavailable",
                        message: discoverHubsError,
                        actionTitle: "Try Again",
                        action: {
                            Task { await refreshDiscoverHubs(force: true) }
                        }
                    )
                } else {
                    emptyView
                }
            } else {
                ZStack(alignment: .top) {
                    homeCanvas()
                        .ignoresSafeArea()

                    if heroActive {
                        HeroBackdropLayer(
                            currentItem: currentHeroItem,
                            serverURL: heroServerURL,
                            authToken: heroAuthToken,
                            presentationStyle: .spotlight
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }

                    if heroActive {
                        HeroOverlayContent(
                            items: heroSourceItems,
                            serverURL: heroServerURL,
                            authToken: heroAuthToken,
                            currentIndex: $heroCurrentIndex,
                            layoutStyle: .topLeading,
                            showsButtonRow: false,
                            showsPagingDots: false,
                            showsAdvanceButton: false,
                            topLeadingInsets: .init(top: 106, leading: 120, bottom: 176, trailing: 72),
                            onInfo: { item in showDetail(for: item, in: currentHeroSection) },
                            onPlay: { item in playItemDirectly(item) },
                            focusRequestID: heroFocusRequestID,
                            onMoveDownToCatalog: {
                                focusActiveCatalog(in: catalogSections)
                            }
                        )
                        .frame(height: heroSectionHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    VStack(spacing: 0) {
                        if !authManager.isConnected {
                            connectionErrorBanner
                        }

                        Spacer(minLength: 0)

                        activeCatalogStage(in: catalogSections, heroActive: heroActive)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea(edges: heroActive ? [.top, .horizontal, .bottom] : [.horizontal, .bottom])
                .onAppear {
                    reconcileCatalogSelection(with: catalogSections)
                }
                .onChange(of: catalogSignature) { _, _ in
                    reconcileCatalogSelection(with: homeCatalogSections)
                }
            }
        }
    }

    private func homeCanvas(
        accent: Color = Color(red: 0.24, green: 0.48, blue: 0.92)
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.06),
                    .black,
                    Color(red: 0.04, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    accent.opacity(0.18),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 24,
                endRadius: 860
            )

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.54)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Connection Error Banner

    private var connectionErrorBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cannot Connect to Plex")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(authManager.connectionError ?? "Showing cached content")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button("Retry") {
                Task {
                    await authManager.verifyAndFixConnection()
                    if authManager.isConnected {
                        await dataStore.refreshHubs()
                    }
                }
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.16)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.yellow.opacity(0.32), lineWidth: 1)
                )
        )
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 100)  // Below safe area
        .padding(.bottom, 28)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        homeStatusView(
            accent: Color(red: 0.24, green: 0.48, blue: 0.92),
            icon: "sparkles.tv.fill",
            title: "Loading Home",
            message: "Syncing your Plex shelves and artwork.",
            showsProgress: true
        )
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
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.top, 24)
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
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.vertical, 12)
        } else if !recommendations.isEmpty {
            InfiniteContentRow(
                rowID: "home:recommendations",
                title: "Personalized Recommendations",
                initialItems: recommendations,
                hubKey: nil,
                hubIdentifier: nil,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                contextMenuSource: .other,
                onItemSelected: { item in
                    selectedItem = item
                },
                onRefreshNeeded: {
                    await refreshRecommendations(force: true)
                },
                onPreviewRequested: { request in
                    handlePreviewRequest(request)
                },
                restorePreviewFocusTarget: $previewRestoreTarget
            )
        }
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        homeStatusView(
            accent: .orange,
            icon: "exclamationmark.triangle.fill",
            title: "Unable to Load",
            message: error,
            actionTitle: "Try Again",
            action: {
                Task { await dataStore.refreshHubs() }
            }
        )
    }

    // MARK: - Empty View

    private var emptyView: some View {
        homeStatusView(
            accent: Color(red: 0.17, green: 0.62, blue: 0.54),
            icon: "film.stack.fill",
            title: "No Content Yet",
            message: "Your Plex libraries are connected, but there is nothing on Home right now.",
            actionTitle: "Refresh",
            action: {
                Task { await dataStore.refreshHubs() }
            }
        )
    }

    // MARK: - Not Connected View

    private var notConnectedView: some View {
        homeStatusView(
            accent: Color(red: 0.44, green: 0.52, blue: 0.92),
            icon: "server.rack",
            title: "Not Connected",
            message: "Connect to your Plex server in Settings to bring Home to life."
        )
    }

    private func homeStatusView(
        accent: Color,
        icon: String,
        title: String,
        message: String,
        showsProgress: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        ZStack {
            homeCanvas(accent: accent)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 94, height: 94)

                    if showsProgress {
                        ProgressView()
                            .scaleEffect(1.35)
                            .tint(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                Text(title)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(AppStoreButtonStyle())
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 42)
            .frame(maxWidth: 640)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .background(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.18)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation Helpers

    /// Navigate to the season containing the given episode
}

// MARK: - Continue Watching Context Menu

/// Switches between a custom Continue Watching context menu and the standard one
struct ContinueWatchingContextMenuModifier: ViewModifier {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let isContinueWatching: Bool
    let contextMenuSource: MediaItemContextSource
    var onGoToItem: ((PlexMetadata) -> Void)?
    var onPlayFromBeginning: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?

    @State private var isPerformingAction = false
    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared

    func body(content: Content) -> some View {
        if isContinueWatching {
            content.contextMenu {
                // Watch from Beginning
                Button {
                    onPlayFromBeginning?(item)
                } label: {
                    Label("Watch from Beginning", systemImage: "arrow.counterclockwise")
                }

                // Go to Episode
                Button {
                    onGoToItem?(item)
                } label: {
                    Label("Go to Episode", systemImage: "info.circle")
                }

                Divider()

                // Mark as Watched
                Button {
                    performAction(optimisticWatched: true) {
                        try await networkManager.markWatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Watched", systemImage: "rectangle.badge.checkmark")
                }

                // Remove from Continue Watching
                Button {
                    performAction {
                        try await networkManager.removeFromContinueWatching(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Remove from Continue Watching", systemImage: "trash")
                }

                Divider()

                // Refresh Metadata
                Button {
                    performAction {
                        try await networkManager.refreshMetadata(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Refresh Metadata", systemImage: "arrow.clockwise")
                }
            }
        } else {
            content.mediaItemContextMenu(
                item: item,
                serverURL: serverURL,
                authToken: authToken,
                source: contextMenuSource,
                onRefreshNeeded: onRefreshNeeded
            )
        }
    }

    private func performAction(optimisticWatched: Bool? = nil, _ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task {
            do {
                try await action()
                if let watched = optimisticWatched, let ratingKey = item.ratingKey {
                    await MainActor.run {
                        dataStore.updateItemWatchStatus(ratingKey: ratingKey, watched: watched)
                    }
                }
                await onRefreshNeeded?()
            } catch {}
            isPerformingAction = false
        }
    }
}

// MARK: - Content Row (replaces MediaRow for Home)

struct ContentRow: View {
    let title: String
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    var onItemSelected: ((PlexMetadata) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Section title
            Text(title)
                .font(.system(size: ScaledDimensions.sectionTitleSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)

            // Horizontal scroll of posters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(items, id: \.ratingKey) { item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)  // Room for scale effect and shadow
            }
            .scrollClipDisabled()  // Allow shadow overflow
        }
    }
}

// MARK: - Infinite Content Row (with endless scrolling)

/// A content row that loads more items as the user scrolls near the end
enum InfiniteContentRowPresentationStyle {
    case standard
    case pinnedStage
}

struct InfiniteContentRow: View {
    let rowID: String
    let title: String
    let initialItems: [PlexMetadata]
    let hubKey: String?  // The hub's key for fetching more items
    let hubIdentifier: String?  // The hub's identifier (e.g., "home.movies.recent") - needed for /hubs/items endpoint
    let serverURL: String
    let authToken: String
    var isContinueWatching: Bool = false
    var contextMenuSource: MediaItemContextSource = .other
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onPlayItem: ((PlexMetadata) -> Void)?
    var onPlayFromBeginning: ((PlexMetadata) -> Void)?
    var onGoToItem: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onPreviewRequested: ((PreviewRequest) -> Void)?
    var restorePreviewFocusTarget: Binding<PreviewSourceTarget?> = .constant(nil)
    var presentationStyle: InfiniteContentRowPresentationStyle = .standard
    var preferredFocusItemID: String? = nil
    var focusRequestID: UUID? = nil
    var onItemFocusChanged: ((String) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onRowFocused: (() -> Void)?

    @Environment(\.uiScale) private var scale
    @State private var items: [PlexMetadata] = []
    @State private var isLoadingMore = false
    @State private var hasReachedEnd = false
    @State private var totalSize: Int?
    @FocusState private var focusedItemId: String?  // Track which item is focused (format: "context:itemId")
    @State private var pendingFocusTask: Task<Void, Never>?

    /// Create a unique focus ID for an item in this row
    private func focusId(for item: PlexMetadata, index: Int? = nil) -> String {
        focusId(forItemID: sourceItemID(for: item, index: index))
    }

    private func focusId(forItemID itemID: String) -> String {
        "\(rowID):\(itemID)"
    }

    private func sourceItemID(from focusID: String) -> String? {
        let prefix = "\(rowID):"
        guard focusID.hasPrefix(prefix) else { return nil }
        return String(focusID.dropFirst(prefix.count))
    }

    private func sourceItemID(for item: PlexMetadata, index: Int? = nil) -> String {
        if let ratingKey = item.ratingKey {
            return ratingKey
        }
        let suffix = index.map(String.init) ?? "unknown"
        return "\(rowID)-\(suffix)"
    }

    private let networkManager = PlexNetworkManager.shared
    private let pageSize = 24

    /// Check if this row contains music items (uses square posters)
    private var isMusicRow: Bool {
        guard let firstItem = items.first ?? initialItems.first else { return false }
        return firstItem.type == "album" || firstItem.type == "artist" || firstItem.type == "track"
    }

    /// Hash that changes when items or their watch status changes
    /// Note: Excludes viewOffset as it changes during playback and would cause unnecessary resets
    private var initialItemsHash: Int {
        var hasher = Hasher()
        hasher.combine(initialItems.count)
        for item in initialItems.prefix(20) {
            hasher.combine(item.ratingKey)
            hasher.combine(item.viewCount)
            // viewOffset excluded - it changes during playback and triggers unwanted list resets
        }
        return hasher.finalize()
    }

    private var rowEyebrow: String {
        let normalizedTitle = title.lowercased()

        if isContinueWatching {
            return "Resume Queue"
        }
        if normalizedTitle.contains("recently added") {
            return "Fresh In"
        }
        if normalizedTitle.contains("recommended") {
            return "Picked for You"
        }
        if normalizedTitle.contains("recently released") || normalizedTitle.contains("new releases") {
            return "New Releases"
        }
        if isMusicRow {
            return "Music Shelf"
        }
        return "Curated Shelf"
    }

    private var countLabel: String? {
        if let total = totalSize, total > items.count {
            return "\(items.count) of \(total)"
        }
        if hasReachedEnd && items.count > pageSize {
            return "All \(items.count)"
        }
        return nil
    }

    private var isPinnedStageStyle: Bool {
        presentationStyle == .pinnedStage
    }

    private var rowHeaderSpacing: CGFloat {
        isPinnedStageStyle ? 8 : 10
    }

    private var rowEyebrowFontSize: CGFloat {
        isPinnedStageStyle ? 11 : 12
    }

    private var rowTitleFontSize: CGFloat {
        isPinnedStageStyle ? 28 : 32
    }

    private var rowHeaderTopPadding: CGFloat {
        isPinnedStageStyle ? 2 : 8
    }

    private var rowVerticalPadding: CGFloat {
        isPinnedStageStyle ? 14 : ScaledDimensions.rowVerticalPadding
    }

    private var rowContainerVerticalPadding: CGFloat {
        isPinnedStageStyle ? 12 : 26
    }

    private var rowBackgroundHorizontalInset: CGFloat {
        isPinnedStageStyle ? 14 : 22
    }

    private var rowBackgroundCornerRadius: CGFloat {
        isPinnedStageStyle ? 28 : 32
    }

    private var rowCardHeight: CGFloat {
        if isContinueWatching {
            return ScaledDimensions.continueWatchingHeight * scale
        }

        let posterWidth = ScaledDimensions.posterWidth * scale
        if isMusicRow {
            return posterWidth
        }

        return ScaledDimensions.posterHeight * scale
    }

    private var rowScrollHeight: CGFloat {
        rowCardHeight + (rowVerticalPadding * 2) + 18
    }

    private var rowHeader: some View {
        VStack(alignment: .leading, spacing: rowHeaderSpacing) {
            Text(rowEyebrow.uppercased())
                .font(.system(size: rowEyebrowFontSize, weight: .semibold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.44))

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title)
                    .font(.system(size: rowTitleFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let countLabel {
                    Text(countLabel)
                        .font(.system(size: isPinnedStageStyle ? 14 : 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.70))
                        .padding(.horizontal, isPinnedStageStyle ? 9 : 10)
                        .padding(.vertical, isPinnedStageStyle ? 5 : 6)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.08))
                                .background(
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.10)
                                )
                        )
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        )
                }
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, rowHeaderTopPadding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowHeader

            // Horizontal scroll of posters with infinite loading
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ScaledDimensions.rowItemSpacing) {  // Lazy to avoid laying out hundreds of offscreen posters
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                        Button {
                            if isContinueWatching {
                                onPlayItem?(item)
                            } else if let onPreviewRequested {
                                onPreviewRequested(
                                    PreviewRequest(
                                        items: items,
                                        selectedIndex: index,
                                        sourceRowID: rowID,
                                        sourceItemID: sourceItemID(for: item, index: index)
                                    )
                                )
                            } else {
                                onItemSelected?(item)
                            }
                        } label: {
                            if isContinueWatching {
                                ContinueWatchingCard(
                                    item: item,
                                    serverURL: serverURL,
                                    authToken: authToken,
                                    isFocused: focusedItemId == focusId(for: item, index: index)
                                )
                            } else {
                                MediaPosterCard(
                                    item: item,
                                    serverURL: serverURL,
                                    authToken: authToken
                                )
                            }
                        }
                        .previewSourceAnchor(rowID: rowID, itemID: sourceItemID(for: item, index: index))
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: focusId(for: item, index: index))
                        .onMoveCommand { direction in
                            switch direction {
                            case .up:
                                onMoveUp?()
                            case .down:
                                onMoveDown?()
                            default:
                                break
                            }
                        }
                        .modifier(ContinueWatchingContextMenuModifier(
                            item: item,
                            serverURL: serverURL,
                            authToken: authToken,
                            isContinueWatching: isContinueWatching,
                            contextMenuSource: contextMenuSource,
                            onGoToItem: onGoToItem,
                            onPlayFromBeginning: onPlayFromBeginning,
                            onRefreshNeeded: onRefreshNeeded
                        ))
                        .onAppear {
                            // Load more when user is 5 items from the end
                            if index >= items.count - 5 {
                                Task {
                                    await loadMoreIfNeeded()
                                }
                            }
                        }
                    }

                    // Loading indicator at the end
                    if isLoadingMore {
                        loadingIndicator
                    } else if hasReachedEnd && items.count > pageSize {
                        endIndicator
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, rowVerticalPadding)  // Room for scale effect and shadow
            }
            .frame(height: rowScrollHeight, alignment: .topLeading)
            .scrollClipDisabled()  // Allow shadow overflow
        }
        .padding(.vertical, rowContainerVerticalPadding)
        .onAppear {
            if items.isEmpty {
                items = initialItems
                // Check if we already have all items
                if let size = totalSize, items.count >= size {
                    hasReachedEnd = true
                }
            }
            requestFocusIfNeeded()
        }
        .onChange(of: initialItemsHash) { _, _ in
            // Reset when initial items change (e.g., on refresh or watch status change)
            let savedFocusId = focusedItemId
            items = initialItems
            hasReachedEnd = false
            // Restore focus after items reset to prevent focus loss (e.g., after marking watched)
            if let savedFocusId {
                if let savedKey = sourceItemID(from: savedFocusId),
                   items.enumerated().contains(where: { index, item in
                       sourceItemID(for: item, index: index) == savedKey
                   }) {
                    // Must nil first then restore async — SwiftUI ignores setting the same value
                    focusedItemId = nil
                    DispatchQueue.main.async {
                        focusedItemId = savedFocusId
                    }
                } else {
                    requestFocusIfNeeded()
                }
            } else {
                requestFocusIfNeeded()
            }
        }
        .onChange(of: focusedItemId) { oldValue, newValue in
            if oldValue == nil && newValue != nil {
                onRowFocused?()
            }
            if let newValue, let sourceItemID = sourceItemID(from: newValue) {
                onItemFocusChanged?(sourceItemID)
            }
        }
        .onChange(of: restorePreviewFocusTarget.wrappedValue) { _, target in
            guard let target, target.rowID == rowID else { return }

            let targetFocusID = focusId(forItemID: target.itemID)
            guard items.enumerated().contains(where: { index, item in
                sourceItemID(for: item, index: index) == target.itemID
            }) else { return }

            focusedItemId = nil
            DispatchQueue.main.async {
                focusedItemId = targetFocusID
                restorePreviewFocusTarget.wrappedValue = nil
            }
        }
        .onChange(of: focusRequestID) { _, _ in
            requestFocusIfNeeded()
        }
        .onDisappear {
            pendingFocusTask?.cancel()
        }
        .focusSection()
    }

    /// Skeleton placeholder card shown while loading more items
    private var loadingIndicator: some View {
        skeletonPosterCard
    }

    /// Single skeleton card matching the appropriate card dimensions
    private var skeletonPosterCard: some View {
        Group {
            if isContinueWatching {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(
                        width: ScaledDimensions.continueWatchingWidth,
                        height: ScaledDimensions.continueWatchingHeight
                    )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 220, height: isMusicRow ? 220 : 330)

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
        }
    }

    private var endIndicator: some View {
        EmptyView()
    }

    private func requestFocusIfNeeded() {
        pendingFocusTask?.cancel()

        guard let targetFocusID = resolvedTargetFocusID() else {
            focusedItemId = nil
            return
        }

        pendingFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            if focusedItemId == targetFocusID {
                focusedItemId = nil
                await Task.yield()
            }

            focusedItemId = targetFocusID
        }
    }

    private func resolvedTargetFocusID() -> String? {
        if let preferredFocusItemID,
           let match = items.enumerated().first(where: { index, item in
               sourceItemID(for: item, index: index) == preferredFocusItemID
           }) {
            return focusId(forItemID: sourceItemID(for: match.element, index: match.offset))
        }

        guard let first = items.enumerated().first else { return nil }
        return focusId(forItemID: sourceItemID(for: first.element, index: first.offset))
    }

    private func loadMoreIfNeeded() async {
        // Don't load if we're already loading, reached the end, or have no hub key
        guard !isLoadingMore,
              !hasReachedEnd,
              let hubKey = hubKey,
              !hubKey.isEmpty else {
            return
        }

        // Check if we might have more items based on totalSize
        if let total = totalSize, items.count >= total {
            hasReachedEnd = true
            return
        }

        isLoadingMore = true

        do {
            let result = try await networkManager.getHubItems(
                serverURL: serverURL,
                authToken: authToken,
                hubKey: hubKey,
                hubIdentifier: hubIdentifier,
                start: items.count,
                count: pageSize
            )

            // Update total size if we got it
            if let size = result.totalSize {
                totalSize = size
            }

            if result.items.isEmpty {
                // No more items
                hasReachedEnd = true
            } else {
                // Append new items, deduplicating by ratingKey
                let existingKeys = Set(items.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !existingKeys.contains(key)
                }

                if newItems.isEmpty {
                    // All items were duplicates, we've reached the end
                    hasReachedEnd = true
                } else {
                    items.append(contentsOf: newItems)

                    // Check if we've loaded everything
                    if let total = totalSize, items.count >= total {
                        hasReachedEnd = true
                    }
                }
            }
        } catch {
            // Don't mark as reached end on error - user can retry by scrolling
        }

        isLoadingMore = false
    }
}

#Preview {
    PlexHomeView()
}
