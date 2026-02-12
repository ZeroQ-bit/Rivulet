//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS sidebar navigation view with sliding glass panel
//

import SwiftUI

#if os(tvOS)

struct TVSidebarView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var liveTVDataStore = LiveTVDataStore.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var librarySettings = LibrarySettingsManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var focusScopeManager = FocusScopeManager()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @State private var selectedDestination: TVDestination = .home
    @State private var selectedLibraryKey: String?
    @State private var selectedLiveTVSourceId: String?  // nil = all sources, non-nil = specific source
    @FocusState private var sidebarFocusedItem: String?  // Track focused item in sidebar
    @State private var pendingDestination: TVDestination?
    @State private var pendingLibraryKey: String?
    @State private var pendingLiveTVSourceId: String?
    @State private var showProfilePicker = false
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var showWhatsNew = false
    @State private var whatsNewVersion = ""

    /// Computed property for sidebar visibility based on active scope
    private var isSidebarVisible: Bool {
        focusScopeManager.isScopeActive(.sidebar)
    }

    private let sidebarWidth: CGFloat = 340

    private var uiScale: CGFloat {
        (DisplaySize(rawValue: displaySizeRaw) ?? .normal).scale
    }

    var body: some View {
        ZStack {
            // Full-screen content with left-edge trigger
            HStack(spacing: 0) {
                // Left-edge trigger - completely removed when guide is active to prevent focus interference
                // Also disabled as fallback in case conditional render has timing issues
                if !focusScopeManager.isScopeActive(.guide) {
                    LeftEdgeTrigger(
                        action: openSidebar,
                        isDisabled: isSidebarVisible || nestedNavState.isNested || focusScopeManager.isScopeActive(.guide)
                    )
                    .opacity(isSidebarVisible || nestedNavState.isNested ? 0 : 1)
                    .allowsHitTesting(!isSidebarVisible && !nestedNavState.isNested && !focusScopeManager.isScopeActive(.guide))
                }

                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Disable content when sidebar visible to prevent focus from escaping
                    .disabled(isSidebarVisible)
                    .environment(\.openSidebar, openSidebar)
                    .environment(\.nestedNavigationState, nestedNavState)
                    .environment(\.isSidebarVisible, isSidebarVisible)
                    .environment(\.focusScopeManager, focusScopeManager)
                    .environment(\.uiScale, uiScale)
            }
            .zIndex(0)

            // Dim overlay - animated separately
            Color.black
                .opacity(isSidebarVisible ? 0.4 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(isSidebarVisible)
                .onTapGesture {
                    closeSidebar()
                }
                .animation(.easeOut(duration: 0.12), value: isSidebarVisible)
                .zIndex(1)

            HStack(spacing: 0) {
                sidebarContent
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                    .clipped()
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 44, style: .continuous)
                    )
                    // GPU-accelerated shadow using blur instead of CPU-rendered .shadow()
                    .background(
                        RoundedRectangle(cornerRadius: 44, style: .continuous)
                            .fill(.black)
                            .blur(radius: 30)
                            .offset(x: 15)
                            .opacity(0.5)
                    )
                    .padding(.leading, 12)
                    .offset(x: isSidebarVisible ? 0 : -sidebarWidth - 60)

                Spacer()
            }
            .zIndex(2)
            .animation(.spring(response: 0.16, dampingFraction: 0.9), value: isSidebarVisible)
        }
        .ignoresSafeArea()
        // Handle exit command based on current state
        .onExitCommand {
            if isSidebarVisible {
                closeSidebar()
            } else if nestedNavState.isNested {
                nestedNavState.goBack()
            } else {
                openSidebar()
            }
        }
        .task(id: authManager.hasCredentials) {
            guard authManager.selectedServerToken != nil else { return }

            // If profile picker on launch is enabled, block content immediately
            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                isAwaitingProfileSelection = true
            }

            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                // Must await profile data before showing picker
                await profileManager.fetchHomeUsers()
                hasCheckedProfilePicker = true

                if profileManager.hasMultipleProfiles {
                    showProfilePicker = true
                    // Content will load after profile is selected
                    return
                } else {
                    isAwaitingProfileSelection = false
                }
            } else {
                // Fire and forget — data used later in settings
                Task { await profileManager.fetchHomeUsers() }
                hasCheckedProfilePicker = true
            }

            // Load data optimistically (will use cache first, then background refresh)
            async let hubsLoad: () = dataStore.loadHubsIfNeeded()
            async let librariesLoad: () = dataStore.loadLibrariesIfNeeded()
            _ = await (hubsLoad, librariesLoad)

            // Load library hubs early so Home screen rows are ready from cache
            await dataStore.loadLibraryHubsIfNeeded()

            // Start background prefetch of library content for faster navigation
            dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
        }
        .task {
            // Start background preloading of Live TV data (low priority)
            liveTVDataStore.startBackgroundPreload()
        }
        // Handle deep links from Top Shelf
        .onChange(of: deepLinkHandler.pendingPlayback) { _, metadata in
            guard let metadata else { return }
            presentPlayerForDeepLink(metadata)
            deepLinkHandler.pendingPlayback = nil
        }
        // What's New overlay
        .fullScreenCover(isPresented: $showWhatsNew) {
            WhatsNewView(isPresented: $showWhatsNew, version: whatsNewVersion)
        }
        .onAppear {
            // Defer What's New check if profile picker needs to be shown first
            if profileManager.showProfilePickerOnLaunch && authManager.selectedServerToken != nil {
                return
            }
            checkAndShowWhatsNew()
        }
        // Profile picker overlay
        .fullScreenCover(isPresented: $showProfilePicker) {
            ProfilePickerOverlay(isPresented: $showProfilePicker)
        }
        .onChange(of: showProfilePicker) { _, isShowing in
            if !isShowing {
                // Profile selected, unblock content
                isAwaitingProfileSelection = false

                // Load content if not already loaded (profile switch handles its own reload)
                Task {
                    if dataStore.hubs.isEmpty {
                        async let hubsLoad: () = dataStore.loadHubsIfNeeded()
                        async let librariesLoad: () = dataStore.loadLibrariesIfNeeded()
                        _ = await (hubsLoad, librariesLoad)
                        await dataStore.loadLibraryHubsIfNeeded()
                        dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
                    }
                }

                // Now show What's New if applicable (was deferred for profile picker)
                checkAndShowWhatsNew()
            }
        }
    }

    // MARK: - Deep Link Player

    /// Present player for a deep link from Top Shelf
    private func presentPlayerForDeepLink(_ metadata: PlexMetadata) {
        // Get images for loading screen (from cache or fetch if needed)
        Task {
            let (artImage, thumbImage) = await getPlayerImages(for: metadata)

            await MainActor.run {
                let viewModel = UniversalPlayerViewModel(
                    metadata: metadata,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: metadata.viewOffset.map { Double($0) / 1000.0 },
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let inputCoordinator = PlaybackInputCoordinator()

                let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)
                let container = PlayerContainerViewController(
                    rootView: playerView,
                    viewModel: viewModel,
                    inputCoordinator: inputCoordinator
                )

                // Present from top-most view controller
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    container.modalPresentationStyle = .fullScreen
                    topVC.present(container, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen (from cache or fetch)
    private func getPlayerImages(for metadata: PlexMetadata) async -> (UIImage?, UIImage?) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return (nil, nil) }

        let art = metadata.bestArt
        let thumb = metadata.thumb ?? metadata.bestThumb

        // Build URLs
        let artURL = art.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        let thumbURL = thumb.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }

        // Fetch both images concurrently (from cache or network)
        async let artTask: UIImage? = artURL != nil ? ImageCacheManager.shared.image(for: artURL!) : nil
        async let thumbTask: UIImage? = thumbURL != nil ? ImageCacheManager.shared.image(for: thumbURL!) : nil

        return await (artTask, thumbTask)
    }

    // MARK: - Sidebar Content

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Navigation with individually focusable items (enables native hold-to-scroll)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    GlassEffectContainer {
                        VStack(alignment: .leading, spacing: 4) {
                            // Search
                            FocusableSidebarRow(
                                id: "search",
                                icon: "magnifyingglass",
                                title: "Search",
                                isSelected: selectedDestination == .search,
                                onSelect: { queueNavigation(destination: .search, libraryKey: nil) },
                                fontScale: uiScale,
                                focusedItem: $sidebarFocusedItem
                            )

                            // Home
                            FocusableSidebarRow(
                                id: "home",
                                icon: "house.fill",
                                title: "Home",
                                isSelected: selectedDestination == .home && selectedLibraryKey == nil,
                                onSelect: { queueNavigation(destination: .home, libraryKey: nil) },
                                fontScale: uiScale,
                                focusedItem: $sidebarFocusedItem
                            )

                            // Live TV section (shown first if liveTVAboveLibraries is enabled)
                            if liveTVAboveLibraries {
                                liveTVSection
                                librariesSection
                            } else {
                                librariesSection
                                liveTVSection
                            }

                            Spacer(minLength: 60)

                            // Settings
                            Divider()
                                .background(.white.opacity(0.2))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 20)

                            FocusableSidebarRow(
                                id: "settings",
                                icon: "gearshape.fill",
                                title: "Settings",
                                isSelected: selectedDestination == .settings,
                                onSelect: { queueNavigation(destination: .settings, libraryKey: nil) },
                                fontScale: uiScale,
                                focusedItem: $sidebarFocusedItem
                            )
                        }
                        .padding(.bottom, 50)
                    }
                }
                .focusSection()
                .disabled(!focusScopeManager.isScopeActive(.sidebar))
                .onExitCommand {
                    closeSidebar()
                }
                .onChange(of: isSidebarVisible) { _, isVisible in
                    if isVisible {
                        // Focus the currently selected item when sidebar opens
                        let itemToFocus = currentSidebarItemId
                        sidebarFocusedItem = itemToFocus
                        proxy.scrollTo(itemToFocus, anchor: .center)
                    } else {
                        sidebarFocusedItem = nil
                        // Apply deferred navigation after the close animation completes
                        applyPendingNavigation()
                    }
                }
            }
        }
        .padding(.top, 50)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Returns the ID of the currently selected sidebar item
    private var currentSidebarItemId: String {
        if let libraryKey = selectedLibraryKey {
            return libraryKey
        }
        switch selectedDestination {
        case .search: return "search"
        case .home: return "home"
        case .liveTV:
            if let sourceId = selectedLiveTVSourceId {
                return "liveTV:\(sourceId)"
            }
            return "liveTV"
        case .settings: return "settings"
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16 * uiScale, weight: .bold))
            .tracking(1.8 * uiScale)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        Group {
            // Block content while awaiting profile selection (privacy)
            if isAwaitingProfileSelection {
                Color.black
                    .ignoresSafeArea()
            } else if let libraryKey = selectedLibraryKey,
               let library = dataStore.libraries.first(where: { $0.key == libraryKey }) {
                PlexLibraryView(libraryKey: library.key, libraryTitle: library.title)
                // Removed .id() to preserve AsyncImage caches across library switches
                // The .task(id: libraryKey) in PlexLibraryView handles data switching
            } else {
                switch selectedDestination {
                case .search:
                    PlexSearchView()
                case .home:
                    // Show PlexHomeView if user has credentials (even if disconnected - will show cache)
                    if authManager.hasCredentials {
                        PlexHomeView()
                    } else {
                        welcomeView
                    }
                case .liveTV:
                    LiveTVContainerView(sourceIdFilter: selectedLiveTVSourceId)
                case .settings:
                    SettingsView()
                }
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.3))

            VStack(spacing: 12) {
                Text("Welcome to Rivulet")
                    .font(.system(size: 46, weight: .semibold))

                Text("Press the Back button or navigate left to open the sidebar, go to Settings, and scroll to the bottom to connect your Plex server.")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar Sections

    @ViewBuilder
    private var librariesSection: some View {
        // Libraries section
        if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
            sectionHeader(authManager.savedServerName?.uppercased() ?? "LIBRARY")

            ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                FocusableSidebarRow(
                    id: library.key,
                    icon: iconForLibrary(library),
                    title: library.title,
                    isSelected: selectedLibraryKey == library.key,
                    onSelect: { queueNavigation(destination: .home, libraryKey: library.key) },
                    fontScale: uiScale,
                    focusedItem: $sidebarFocusedItem
                )
            }
        }

        if dataStore.isLoadingLibraries {
            HStack(spacing: 14) {
                ProgressView()
                    .tint(.white.opacity(0.5))
                Text("Loading...")
                    .font(.system(size: 22 * uiScale))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private var liveTVSection: some View {
        // Live TV section
        if liveTVDataStore.hasConfiguredSources {
            sectionHeader("LIVE TV")

            if combineLiveTVSources {
                // Combined: Single "Channels" entry for all sources
                FocusableSidebarRow(
                    id: "liveTV",
                    icon: "tv.and.mediabox",
                    title: "Channels",
                    isSelected: selectedDestination == .liveTV && selectedLiveTVSourceId == nil,
                    onSelect: { queueLiveTVNavigation(sourceId: nil) },
                    fontScale: uiScale,
                    focusedItem: $sidebarFocusedItem
                )
            } else {
                // Separate: Individual entry for each source
                ForEach(liveTVDataStore.sources) { source in
                    FocusableSidebarRow(
                        id: "liveTV:\(source.id)",
                        icon: iconForSourceType(source.sourceType),
                        title: source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                        isSelected: selectedDestination == .liveTV && selectedLiveTVSourceId == source.id,
                        onSelect: { queueLiveTVNavigation(sourceId: source.id) },
                        fontScale: uiScale,
                        focusedItem: $sidebarFocusedItem
                    )
                }
            }
        }
    }

    // MARK: - Navigation Actions

    /// Queue navigation and close the sidebar; actual navigation applies after close to keep animation smooth
    private func queueNavigation(destination: TVDestination, libraryKey: String?) {
        pendingDestination = destination
        pendingLibraryKey = libraryKey
        pendingLiveTVSourceId = nil
        closeSidebar()
    }

    /// Queue Live TV navigation with optional source filter
    private func queueLiveTVNavigation(sourceId: String?) {
        pendingDestination = .liveTV
        pendingLibraryKey = nil
        pendingLiveTVSourceId = sourceId
        closeSidebar()
    }

    private func applyPendingNavigation() {
        guard let destination = pendingDestination else { return }

        // Apply pending navigation now that sidebar is closed
        switch destination {
        case .home:
            if let libraryKey = pendingLibraryKey,
               let library = dataStore.libraries.first(where: { $0.key == libraryKey }) {
                navigateToLibrary(library)
            } else {
                navigateToHome()
            }
        case .search:
            navigateToSearch()
        case .liveTV:
            navigateToLiveTV(sourceId: pendingLiveTVSourceId)
        case .settings:
            navigateToSettings()
        }

        pendingDestination = nil
        pendingLibraryKey = nil
        pendingLiveTVSourceId = nil
    }

    private func openSidebar() {
        // Activate sidebar scope (saves content focus automatically) with a short spring
        withAnimation(.spring(response: 0.16, dampingFraction: 0.92)) {
            focusScopeManager.activate(.sidebar)
        }
    }

    private func closeSidebar() {
        // Deactivate sidebar scope (restores content focus automatically) with a quick snap
        withAnimation(.easeOut(duration: 0.08)) {
            focusScopeManager.deactivate()
        }
    }

    private func handleExitCommand() {
        // At root level: Menu button toggles sidebar
        if isSidebarVisible {
            closeSidebar()
        } else {
            openSidebar()
        }
    }

    private func iconForLibrary(_ library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }


    // MARK: - Explicit Navigation (on button press or right arrow)

    private func navigateToHome() {
        selectedDestination = .home
        selectedLibraryKey = nil
    }

    private func navigateToSearch() {
        selectedDestination = .search
        selectedLibraryKey = nil
    }

    private func navigateToLibrary(_ library: PlexLibrary) {
        selectedLibraryKey = library.key
        // Keep destination as .home so library view shows (not .settings)
        selectedDestination = .home
    }

    private func navigateToLiveTV(sourceId: String? = nil) {
        selectedDestination = .liveTV
        selectedLibraryKey = nil
        selectedLiveTVSourceId = sourceId
    }

    private func iconForSourceType(_ sourceType: LiveTVSourceType) -> String {
        switch sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    private func navigateToSettings() {
        selectedDestination = .settings
        selectedLibraryKey = nil
    }

    // MARK: - What's New

    /// Check and show What's New overlay if applicable
    private func checkAndShowWhatsNew() {
        // Don't show if profile picker is still pending
        guard !isAwaitingProfileSelection else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let current = "\(version) (\(build))"

        if current != lastSeenBuild {
            if WhatsNewView.features(for: current) != nil {
                whatsNewVersion = current
                showWhatsNew = true
            } else {
            }
            lastSeenBuild = current
        } else {
        }
    }
}

#endif
