//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI
import os.log

private let sidebarLog = Logger(subsystem: "com.rivulet.app", category: "Sidebar")

// MARK: - TVSidebarView

struct TVSidebarView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var liveTVDataStore = LiveTVDataStore.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @State private var selectedTab: SidebarTab = .home
    @State private var previousTab: SidebarTab = .home
    @State private var showProfilePicker = false
    @State private var showProfileSwitcher = false
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

    private var tabSelection: Binding<SidebarTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                // Block tab changes while in nested navigation (carousel, detail view)
                guard !nestedNavState.isNested else { return }

                if newTab == .account {
                    if profileManager.hasMultipleProfiles {
                        showProfileSwitcher = true
                    }
                    return  // Never store .account — selectedTab stays unchanged
                }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        sidebarTabView
        .onExitCommand { }
        .task { await Self.installSidebarFocusGuard() }
        .task { await focusRecoveryWatchdog() }
        // Sync static flag for sidebar focus guard
        .onChange(of: nestedNavState.isNested) { _, isNested in
            NestedNavigationState.isCurrentlyNested = isNested
        }
        // Handle tab selection
        .onChange(of: selectedTab) { _, newTab in
            nestedNavState.isNested = false
            nestedNavState.goBackAction = nil
            previousTab = newTab
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
        // Compact profile switcher popup (from sidebar account tab)
        .fullScreenCover(isPresented: $showProfileSwitcher) {
            ProfileSwitcherPopup(
                isPresented: $showProfileSwitcher,
                profileManager: profileManager
            )
            .presentationBackground(.clear)
        }
    }

    // MARK: - Tab Definitions

    private var sidebarTabView: some View {
        TabView(selection: tabSelection) {
            Tab(value: SidebarTab.account) {
                Color.clear.ignoresSafeArea()
            } label: {
                Label {
                    Text(selectedTab == .account ? "Switch Profile" : profileName)
                } icon: {
                    SidebarProfileAvatar(user: profileManager.selectedUser, size: 20)
                        .frame(width: 28, height: 28)
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: SidebarTab.search) {
                tabContent(for: .search)
            }

            Tab("Home", systemImage: "house.fill", value: SidebarTab.home) {
                tabContent(for: .home)
            }

            if liveTVAboveLibraries {
                if liveTVDataStore.hasConfiguredSources {
                    liveTVTabSection
                }
                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    libraryTabSection
                }
            } else {
                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    libraryTabSection
                }
                if liveTVDataStore.hasConfiguredSources {
                    liveTVTabSection
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: SidebarTab.settings) {
                tabContent(for: .settings)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbarVisibility(nestedNavState.isNested ? .hidden : .automatic, for: .tabBar)
        .animation(.easeInOut(duration: 0.18), value: nestedNavState.isNested)
        .onChange(of: nestedNavState.isNested) { _, isNested in
            guard isNested else { return }
            resetFocus(in: contentNamespace)
        }
    }

    private var libraryTabSection: some TabContent<SidebarTab> {
        TabSection(authManager.savedServerName ?? "Library") {
            ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                Tab(library.title, systemImage: iconForLibrary(library),
                    value: SidebarTab.library(key: library.key)) {
                    tabContent(for: .library(key: library.key))
                }
            }
        }
    }

    @TabContentBuilder<SidebarTab>
    private var liveTVTabSection: some TabContent<SidebarTab> {
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

    // MARK: - Focus Recovery

    /// Monitors for lost focus and restores it to the content area.
    /// Catches cases where focus ends up in limbo after overlays, popups, etc.
    @MainActor
    private func focusRecoveryWatchdog() async {
        // Wait for initial layout
        try? await Task.sleep(for: .seconds(2))

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))

            // Skip recovery while overlays are active
            guard !showProfileSwitcher, !showProfilePicker, !showWhatsNew else { continue }

            // Check if any view in the window has focus
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first,
                  let focusSystem = window.rootViewController?.view.window?.windowScene?.focusSystem
            else { continue }

            if focusSystem.focusedItem == nil {
                resetFocus(in: contentNamespace)
            }
        }
    }

    // MARK: - Sidebar Focus Containment

    /// Overrides shouldUpdateFocus on the sidebar's collection view class
    /// and the tab bar controller to prevent focus from escaping.
    @MainActor
    private static func installSidebarFocusGuard() async {
        try? await Task.sleep(for: .seconds(1))

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        var hasSwizzledCV = false
        var hasSwizzledTabBar = false
        var swizzledTabBarClasses: Set<String> = []

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))

            if let cv = findSidebarCollectionView(in: window) {
                // Disable scroll bounce
                cv.bounces = false
                cv.alwaysBounceVertical = false

                // Swizzle shouldUpdateFocus once on the collection view's class
                if !hasSwizzledCV {
                    Self.overrideSidebarFocusBehavior(on: type(of: cv))
                    hasSwizzledCV = true
                }
            }

            // Also guard the tab bar controller (which manages sidebar reveal)
            if !hasSwizzledTabBar, let rootVC = window.rootViewController {
                if let tabBarVC = findTabBarController(from: rootVC) {
                    let tabBarClass = type(of: tabBarVC)
                    let className = String(describing: tabBarClass)
                    if !swizzledTabBarClasses.contains(className) {
                        Self.overrideTabBarFocusBehavior(on: tabBarClass)
                        swizzledTabBarClasses.insert(className)
                        hasSwizzledTabBar = true
                        sidebarLog.info("[FocusGuard] Found tab bar controller: \(className)")

                        // Log hierarchy once for debugging
                        Self.logViewHierarchy(window, depth: 0, maxDepth: 4)
                    }
                }
            }
        }
    }

    /// Find the UITabBarController in the view controller hierarchy
    private static func findTabBarController(from vc: UIViewController) -> UITabBarController? {
        if let tabBarVC = vc as? UITabBarController {
            return tabBarVC
        }
        for child in vc.children {
            if let found = findTabBarController(from: child) {
                return found
            }
        }
        return nil
    }

    /// Log the UIKit view hierarchy for debugging sidebar focus issues
    private static func logViewHierarchy(_ view: UIView, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)
        let frame = view.frame
        let className = String(describing: type(of: view))
        sidebarLog.debug("[Hierarchy] \(indent)\(className) frame=\(frame.origin.x),\(frame.origin.y) \(frame.width)x\(frame.height) focusable=\(view.canBecomeFocused)")
        for subview in view.subviews {
            logViewHierarchy(subview, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Replaces shouldUpdateFocus(in:) on the sidebar collection view class
    /// to block downward focus escape and block all focus entry while in nested navigation.
    private static func overrideSidebarFocusBehavior(on cvClass: AnyClass) {
        let selector = #selector(UIView.shouldUpdateFocus(in:))
        sidebarLog.info("[FocusGuard] Swizzling shouldUpdateFocus on \(String(describing: cvClass))")

        // Save the original implementation (if any) so we can call it for non-blocked cases
        let originalIMP = class_getMethodImplementation(cvClass, selector)

        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIFocusUpdateContext) -> Bool
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIFocusUpdateContext) -> Bool = { obj, context in
            guard let selfView = obj as? UICollectionView else { return true }

            // Only apply to sidebar-width collection views (not content area lists)
            guard selfView.frame.width > 0 && selfView.frame.width < 500 else {
                return originalFunc(obj, selector, context)
            }

            let heading = context.focusHeading
            let nextClass = context.nextFocusedView.map { String(describing: type(of: $0)) } ?? "nil"
            let prevClass = context.previouslyFocusedView.map { String(describing: type(of: $0)) } ?? "nil"

            // Block all focus from entering the sidebar while in nested navigation (carousel/detail)
            if NestedNavigationState.isCurrentlyNested {
                sidebarLog.info("[FocusGuard] CV shouldUpdateFocus: heading=\(heading.rawValue) next=\(nextClass) prev=\(prevClass)")
                if let nextView = context.nextFocusedView,
                   nextView.isDescendant(of: selfView) {
                    sidebarLog.info("[FocusGuard] BLOCKED focus entering sidebar CV (nested=true)")
                    return false
                }
            }

            // Block focus from leaving the sidebar downward
            if heading.contains(.down) {
                if let nextView = context.nextFocusedView,
                   !nextView.isDescendant(of: selfView) {
                    return false
                }
            }

            return originalFunc(obj, selector, context)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIView.self, selector)!
        let types = method_getTypeEncoding(method)!
        class_replaceMethod(cvClass, selector, imp, types)
    }

    /// Overrides shouldUpdateFocus on the tab bar controller's view to block sidebar reveal when nested.
    private static func overrideTabBarFocusBehavior(on tabBarVCClass: AnyClass) {
        // The tab bar controller's view manages the sidebar reveal.
        // We override shouldUpdateFocus on its VIEW class to intercept focus moving left into the sidebar.
        let selector = #selector(UIView.shouldUpdateFocus(in:))

        // We need the view's class, but we'll also try the VC class
        // Try to install on common UIKit view classes that wrap the tab content
        sidebarLog.info("[FocusGuard] Overriding tab bar VC focus: \(String(describing: tabBarVCClass))")

        // Override on the UITabBarController itself
        let vcSelector = #selector(UIViewController.shouldUpdateFocus(in:))
        let originalIMP = class_getMethodImplementation(tabBarVCClass, vcSelector)

        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIFocusUpdateContext) -> Bool
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIFocusUpdateContext) -> Bool = { obj, context in
            let heading = context.focusHeading
            let nextClass = context.nextFocusedView.map { String(describing: type(of: $0)) } ?? "nil"
            let prevClass = context.previouslyFocusedView.map { String(describing: type(of: $0)) } ?? "nil"

            if NestedNavigationState.isCurrentlyNested {
                sidebarLog.info("[FocusGuard] TabBar shouldUpdateFocus: heading=\(heading.rawValue) next=\(nextClass) prev=\(prevClass)")
                // Block focus from moving left (toward sidebar) when nested
                if heading.contains(.left) {
                    sidebarLog.info("[FocusGuard] BLOCKED tab bar left focus (nested=true)")
                    return false
                }
            }
            return originalFunc(obj, vcSelector, context)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIViewController.self, vcSelector)!
        let types = method_getTypeEncoding(method)!
        class_replaceMethod(tabBarVCClass, vcSelector, imp, types)
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
