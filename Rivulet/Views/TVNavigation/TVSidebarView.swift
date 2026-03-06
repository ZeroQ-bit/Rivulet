//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI


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
                    Text(profileName)
                } icon: {
                    SidebarProfileAvatar(user: profileManager.selectedUser, size: 28)
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

            Tab("Settings", systemImage: "gearshape.fill",
                value: SidebarTab.settings) {
                tabContent(for: .settings)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .scrollBounceBehavior(.basedOnSize)
        .task { await Self.installSidebarFocusGuard() }
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
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        Group {
            if isAwaitingProfileSelection {
                Color.clear.ignoresSafeArea()
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

    // MARK: - Sidebar Focus Containment

    /// Monitors for the sidebar's collection view and installs a UIFocusGuide
    /// below it to prevent focus from escaping downward.
    @MainActor
    private static func installSidebarFocusGuard() async {
        try? await Task.sleep(for: .seconds(1))

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        // The sidebar's collection view (UpdateCoalescingCollectionView) only exists
        // when expanded. Poll until we find it, then install a focus guide.
        // Also re-check periodically in case it gets recreated.
        var installedGuide: UIFocusGuide?
        weak var lastCollectionView: UICollectionView?

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))

            // Find the sidebar collection view (narrow, left-side UICollectionView)
            let collectionView = Self.findSidebarCollectionView(in: window)

            if let cv = collectionView, cv !== lastCollectionView {
                // New sidebar collection view found — install focus guide
                lastCollectionView = cv

                // Remove old guide if any
                if let old = installedGuide {
                    old.owningView?.removeLayoutGuide(old)
                }

                // Add a focus guide to the window below the sidebar area.
                // When focus tries to move down past the last sidebar item,
                // the guide catches it and redirects back into the sidebar.
                let guide = UIFocusGuide()
                guide.preferredFocusEnvironments = [cv]
                window.addLayoutGuide(guide)

                // Position the guide in the sidebar column, below the content
                guide.topAnchor.constraint(equalTo: cv.bottomAnchor).isActive = true
                guide.leadingAnchor.constraint(equalTo: window.leadingAnchor).isActive = true
                guide.widthAnchor.constraint(equalToConstant: cv.frame.width).isActive = true
                guide.heightAnchor.constraint(equalToConstant: 200).isActive = true

                installedGuide = guide

                // Also disable scroll bounce on the sidebar
                cv.bounces = false
                cv.alwaysBounceVertical = false
            }
        }
    }

    /// Finds the sidebar's UICollectionView by looking for a narrow, left-aligned collection view
    private static func findSidebarCollectionView(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView {
            let frame = cv.frame
            // Sidebar is narrow (< 500pt) and left-aligned
            if frame.origin.x == 0 && frame.width > 0 && frame.width < 500 {
                return cv
            }
        }
        for subview in view.subviews {
            if let found = findSidebarCollectionView(in: subview) {
                return found
            }
        }
        return nil
    }

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

    @State private var circularImage: UIImage?

    var body: some View {
        Group {
            if let circularImage {
                Image(uiImage: circularImage)
                    .resizable()
                    .renderingMode(.original)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: user?.thumb) {
            await loadCircularAvatar()
        }
    }

    private func loadCircularAvatar() async {
        guard let thumbURL = user?.thumb, let url = URL(string: thumbURL) else {
            circularImage = nil
            return
        }

        // Try loading from ImageCacheManager first, then network
        let image: UIImage?
        if let cached = await ImageCacheManager.shared.image(for: url) {
            image = cached
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let downloaded = UIImage(data: data) else {
                return
            }
            image = downloaded
        }

        guard let source = image else { return }

        // Render circular image with border
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let circular = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let circlePath = UIBezierPath(ovalIn: rect)
            circlePath.addClip()

            // Draw image scaled to fill
            let imageSize = source.size
            let scale = max(size / imageSize.width, size / imageSize.height)
            let drawWidth = imageSize.width * scale
            let drawHeight = imageSize.height * scale
            let drawRect = CGRect(
                x: (size - drawWidth) / 2,
                y: (size - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            source.draw(in: drawRect)

            // Draw subtle border
            ctx.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }

        circularImage = circular
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

