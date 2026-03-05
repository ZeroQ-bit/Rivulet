//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI

#if os(tvOS)

// MARK: - TVSidebarView

struct TVSidebarView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var liveTVDataStore = LiveTVDataStore.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var focusScopeManager = FocusScopeManager()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @State private var selectedTab: SidebarTab = .home
    @State private var showProfilePicker = false
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var showWhatsNew = false
    @State private var whatsNewVersion = ""
    @State private var currentTime = ""
    @Namespace private var contentNamespace
    @Environment(\.resetFocus) private var resetFocus

    private var uiScale: CGFloat {
        (DisplaySize(rawValue: displaySizeRaw) ?? .normal).scale
    }

    private var profileName: String {
        profileManager.selectedUser?.displayName ?? authManager.username ?? "Account"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: .account) {
                tabContent(for: .account)
            } label: {
                Label {
                    HStack {
                        Text(profileName)
                        if !currentTime.isEmpty {
                            Spacer()
                            Text(currentTime)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    SidebarProfileAvatar(user: profileManager.selectedUser, size: 36)
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                tabContent(for: .search)
            }

            Tab("Home", systemImage: "house.fill", value: .home) {
                tabContent(for: .home)
            }

            // Dynamic sections (order controlled by liveTVAboveLibraries)
            if liveTVAboveLibraries {
                if liveTVDataStore.hasConfiguredSources {
                    TabSection("Live TV") {
                        if combineLiveTVSources {
                            Tab("Channels", systemImage: "tv.and.mediabox",
                                value: SidebarTab.liveTV(sourceId: nil)) {
                                tabContent(for: .liveTV(sourceId: nil))
                            }
                        } else {
                            ForEach(liveTVDataStore.sources) { source in
                                Tab(source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                                    systemImage: iconForSourceType(source.sourceType),
                                    value: SidebarTab.liveTV(sourceId: source.id)) {
                                    tabContent(for: .liveTV(sourceId: source.id))
                                }
                            }
                        }
                    }
                }

                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    TabSection(authManager.savedServerName ?? "Library") {
                        ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                            Tab(library.title, systemImage: iconForLibrary(library),
                                value: SidebarTab.library(key: library.key)) {
                                tabContent(for: .library(key: library.key))
                            }
                        }
                    }
                }
            } else {
                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    TabSection(authManager.savedServerName ?? "Library") {
                        ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                            Tab(library.title, systemImage: iconForLibrary(library),
                                value: SidebarTab.library(key: library.key)) {
                                tabContent(for: .library(key: library.key))
                            }
                        }
                    }
                }

                if liveTVDataStore.hasConfiguredSources {
                    TabSection("Live TV") {
                        if combineLiveTVSources {
                            Tab("Channels", systemImage: "tv.and.mediabox",
                                value: SidebarTab.liveTV(sourceId: nil)) {
                                tabContent(for: .liveTV(sourceId: nil))
                            }
                        } else {
                            ForEach(liveTVDataStore.sources) { source in
                                Tab(source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                                    systemImage: iconForSourceType(source.sourceType),
                                    value: SidebarTab.liveTV(sourceId: source.id)) {
                                    tabContent(for: .liveTV(sourceId: source.id))
                                }
                            }
                        }
                    }
                }
            }

            TabSection("") {
                Tab("Settings", systemImage: "gearshape.fill",
                    value: SidebarTab.settings) {
                    tabContent(for: .settings)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onExitCommand {
            resetFocus(in: contentNamespace)
        }
        // Handle tab selection
        .onChange(of: selectedTab) { _, _ in
            nestedNavState.isNested = false
            nestedNavState.goBackAction = nil
        }
        // Reset tab selection when live TV source mode changes
        .onChange(of: combineLiveTVSources) { _, combined in
            if case .liveTV = selectedTab {
                selectedTab = .liveTV(sourceId: combined ? nil : liveTVDataStore.sources.first?.id)
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

            // CRITICAL PATH: Only hubs needed for home screen to render
            await dataStore.loadHubsIfNeeded()

            // BACKGROUND: Libraries -> library hubs -> prefetch (chained, not blocking home)
            Task {
                await dataStore.loadLibrariesIfNeeded()
                await dataStore.loadLibraryHubsIfNeeded()
                dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
            }
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
        // Profile picker overlay (launch-time "Who's Watching")
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
                        // CRITICAL PATH: Only hubs needed for home screen to render
                        await dataStore.loadHubsIfNeeded()

                        // BACKGROUND: Libraries -> library hubs -> prefetch
                        Task {
                            await dataStore.loadLibrariesIfNeeded()
                            await dataStore.loadLibraryHubsIfNeeded()
                            dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
                        }
                    }
                }

                // Now show What's New if applicable (was deferred for profile picker)
                checkAndShowWhatsNew()
            }
        }
        .task {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            currentTime = formatter.string(from: Date())
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                currentTime = formatter.string(from: Date())
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        Group {
            if isAwaitingProfileSelection {
                Color.black.ignoresSafeArea()
            } else {
                switch tab {
                case .account:
                    Color.clear
                case .search:
                    PlexSearchView()
                case .home:
                    if authManager.hasCredentials {
                        PlexHomeView()
                    } else {
                        welcomeView
                    }
                case .library(let key):
                    if let lib = dataStore.libraries.first(where: { $0.key == key }) {
                        PlexLibraryView(libraryKey: lib.key, libraryTitle: lib.title)
                    }
                case .liveTV(let sourceId):
                    LiveTVContainerView(sourceIdFilter: sourceId)
                case .settings:
                    SettingsView()
                }
            }
        }
        .focusScope(contentNamespace)
        .environment(\.nestedNavigationState, nestedNavState)
        .environment(\.focusScopeManager, focusScopeManager)
        .environment(\.uiScale, uiScale)
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.3))

            VStack(spacing: 12) {
                Text("Welcome to Rivulet")
                    .font(.system(size: 46, weight: .semibold))

                Text("Open the sidebar to navigate to Settings and connect your Plex server.")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Icon Helpers

    private func iconForLibrary(_ library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private func iconForSourceType(_ sourceType: LiveTVSourceType) -> String {
        switch sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    // MARK: - Deep Link Player

    /// Present player for a deep link from Top Shelf
    private func presentPlayerForDeepLink(_ metadata: PlexMetadata) {
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

        let artURL = art.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        let thumbURL = thumb.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }

        async let artTask: UIImage? = artURL != nil ? ImageCacheManager.shared.image(for: artURL!) : nil
        async let thumbTask: UIImage? = thumbURL != nil ? ImageCacheManager.shared.image(for: thumbURL!) : nil

        return await (artTask, thumbTask)
    }

    // MARK: - What's New

    private func checkAndShowWhatsNew() {
        guard !isAwaitingProfileSelection else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let current = "\(version) (\(build))"

        if current != lastSeenBuild {
            if WhatsNewView.features(for: current) != nil {
                whatsNewVersion = current
                showWhatsNew = true
            }
            lastSeenBuild = current
        }
    }
}

// MARK: - Sidebar Profile Avatar

struct SidebarProfileAvatar: View {
    let user: PlexHomeUser?
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbURL = user?.thumb, let url = URL(string: thumbURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(profileColor.gradient)
            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        (user?.displayName ?? "?").prefix(1).uppercased()
    }

    private var profileColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        guard let id = user?.id else { return .gray }
        return colors[abs(id) % colors.count]
    }
}

#endif
