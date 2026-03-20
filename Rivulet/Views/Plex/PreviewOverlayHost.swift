//
//  PreviewOverlayHost.swift
//  Rivulet
//
//  In-tree Apple TV-style preview overlay for hub rows.
//

import SwiftUI
import Combine

let previewEntryAnimation = Animation.spring(response: 0.45, dampingFraction: 0.88)
let previewPagingAnimation = Animation.easeInOut(duration: 0.58)
let previewBackdropPagingAnimation = Animation.easeOut(duration: 0.48)
let previewExpandAnimation = Animation.easeInOut(duration: 0.35)

/// Bridge object that allows PreviewContainerViewController to trigger Menu actions
/// on the SwiftUI PreviewOverlayHost.
@MainActor
class PreviewMenuBridge: ObservableObject {
    @Published var menuPressCount: Int = 0

    /// Optional intercept handler set by the expanded detail view.
    /// Returns true if the press was consumed (e.g., popping internal navigation).
    var interceptHandler: (() -> Bool)?

    func triggerMenu() {
        if let handler = interceptHandler, handler() {
            return  // Consumed by detail view's internal nav
        }
        menuPressCount += 1
    }
}

private struct PreviewMenuBridgeKey: EnvironmentKey {
    static let defaultValue: PreviewMenuBridge? = nil
}

extension EnvironmentValues {
    var previewMenuBridge: PreviewMenuBridge? {
        get { self[PreviewMenuBridgeKey.self] }
        set { self[PreviewMenuBridgeKey.self] = newValue }
    }
}

struct PreviewOverlayHost: View {
    let request: PreviewRequest
    let sourceFrames: [PreviewSourceTarget: CGRect]
    let serverURL: String
    let authToken: String
    let onDismiss: (PreviewSourceTarget) -> Void
    @ObservedObject var menuBridge: PreviewMenuBridge

    @State private var selectedIndex: Int
    @State private var stateMachine = PreviewStateMachine()
    @State private var metadataVisible = false
    @State private var expandedChromeVisible = false
    @State private var verticalScrollEnabled = false
    @State private var capturedSourceFrame: CGRect?
    @State private var heroBackdropOffset: CGFloat = 0
    @State private var pagingMotionActive = false
    @State private var metadataGate = PreviewLoadGate()
    @FocusState private var focusedArea: PreviewFocusArea?

    private let topInset: CGFloat = 52
    private let cornerRadius: CGFloat = 28
    private let centeredHorizontalInset: CGFloat = 88
    private let sideCardGap: CGFloat = 14
    private let backdropLagDistance: CGFloat = 120

    init(
        request: PreviewRequest,
        sourceFrames: [PreviewSourceTarget: CGRect],
        serverURL: String,
        authToken: String,
        onDismiss: @escaping (PreviewSourceTarget) -> Void,
        menuBridge: PreviewMenuBridge
    ) {
        self.request = request
        self.sourceFrames = sourceFrames
        self.serverURL = serverURL
        self.authToken = authToken
        self.onDismiss = onDismiss
        self.menuBridge = menuBridge
        self._selectedIndex = State(initialValue: request.selectedIndex)
    }

    private var visibleIndices: [Int] {
        switch stateMachine.phase {
        case .entryMorph:
            return [selectedIndex]
        case .carouselStable, .expandingHero, .expandedHero, .detailsStable, .exiting:
            // Two on each side so outgoing edge cards animate away instead of vanishing
            return [selectedIndex - 2, selectedIndex - 1, selectedIndex, selectedIndex + 1, selectedIndex + 2]
                .filter { request.items.indices.contains($0) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Card extends from topInset to below the screen bottom (overflows by cornerRadius to hide bottom corners)
            let cardWidth = max(0, geo.size.width - (centeredHorizontalInset * 2))
            let cardHeight = geo.size.height - topInset + cornerRadius
            let centeredFrame = CGRect(
                x: (geo.size.width - cardWidth) / 2,
                y: topInset,
                width: cardWidth,
                height: cardHeight
            )
            let fullFrame = CGRect(origin: .zero, size: geo.size)
            let entryFrame = sanitizedSourceFrame(
                capturedSourceFrame ?? sourceFrames[request.sourceTarget],
                fallback: centeredFrame,
                in: geo.size
            )

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                if stateMachine.isExpanded {
                    PreviewHeroSurface(
                        item: request.items[selectedIndex],
                        isExpanded: true,
                        metadataVisible: metadataVisible,
                        showExpandedChrome: expandedChromeVisible,
                        showBackdropLayer: true,
                        allowVerticalScroll: verticalScrollEnabled,
                        allowActionRowInteraction: expandedChromeVisible,
                        heroBackdropMotionLocked: stateMachine.motionLocked,
                        backgroundParallaxOffset: heroBackdropOffset,
                        onPreviewExitRequested: handleExpandedExit,
                        onDetailsBecameVisible: {
                            stateMachine.markDetailsStable()
                        }
                    )
                    .allowsHitTesting(true)
                }

                ForEach(visibleIndices, id: \.self) { index in
                    PreviewCarouselCard(
                        item: request.items[index],
                        serverURL: serverURL,
                        authToken: authToken,
                        frame: frame(
                            for: index,
                            centeredFrame: centeredFrame,
                            fullFrame: fullFrame,
                            entryFrame: entryFrame
                        ),
                        phase: stateMachine.phase,
                        isCurrent: index == selectedIndex,
                        metadataVisible: index == selectedIndex && metadataVisible,
                        showExpandedChrome: expandedChromeVisible,
                        allowVerticalScroll: verticalScrollEnabled,
                        allowActionRowInteraction: expandedChromeVisible,
                        pagingMotionActive: pagingMotionActive,
                        motionLocked: stateMachine.motionLocked,
                        backgroundParallaxOffset: 0,
                        onPreviewExitRequested: handleExpandedExit,
                        onDetailsBecameVisible: {
                            if index == selectedIndex {
                                stateMachine.markDetailsStable()
                            }
                        },
                        cornerRadius: cardCornerRadius(for: index),
                        opacity: cardOpacity(for: index)
                    )
                    .zIndex(0)
                }

                if stateMachine.isCarouselInputEnabled {
                    Color.clear
                        .focusable(true)
                        .focused($focusedArea, equals: .carousel)
                        .focusSection()
                        .contentShape(Rectangle())
                        .onMoveCommand(perform: performCarouselMove)
                        .onTapGesture {
                            expandCurrentCard()
                        }
                        .onKeyPress(.return) {
                            expandCurrentCard()
                            return .handled
                        }
                        .onPlayPauseCommand {
                            expandCurrentCard()
                        }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                capturedSourceFrame = sourceFrames[request.sourceTarget]
                focusedArea = .carousel
                prefetchAssets(around: selectedIndex)
                startEntryAnimation()
            }
            .onChange(of: selectedIndex) { _, newIndex in
                prefetchAssets(around: newIndex)
            }
            .onChange(of: sourceFrames[request.sourceTarget]) { _, newFrame in
                if capturedSourceFrame == nil {
                    capturedSourceFrame = newFrame
                }
            }
            .onChange(of: menuBridge.menuPressCount) { _, _ in
                handleExit()
            }
        }
        .environment(\.previewMenuBridge, menuBridge)
        .ignoresSafeArea()
    }

    private func performCarouselMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            page(by: -1)
        case .right:
            page(by: 1)
        case .down:
            expandCurrentCard()
        default:
            break
        }
    }

    private func startEntryAnimation() {
        metadataVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        heroBackdropOffset = 0
        pagingMotionActive = false
        let token = metadataGate.begin()

        Task { @MainActor in
            await Task.yield()
            withAnimation(previewEntryAnimation) {
                stateMachine.completeEntryMorph()
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.setMotionLocked(false)
            withAnimation(.easeOut(duration: 0.22)) {
                metadataVisible = true
            }
        }
    }

    private func page(by delta: Int) {
        guard stateMachine.isCarouselInputEnabled else { return }

        let nextIndex = selectedIndex + delta
        guard request.items.indices.contains(nextIndex) else { return }

        metadataVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        pagingMotionActive = true

        heroBackdropOffset = CGFloat(delta) * backdropLagDistance

        let token = metadataGate.begin()
        stateMachine.beginPaging()

        withAnimation(previewPagingAnimation) {
            selectedIndex = nextIndex
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(previewBackdropPagingAnimation) {
                heroBackdropOffset = 0
            }

            try? await Task.sleep(nanoseconds: 480_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.finishPaging()
            pagingMotionActive = false

            // Brief pause after card settles before metadata fade-in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                metadataVisible = true
            }
        }
    }

    private func expandCurrentCard() {
        guard !stateMachine.isExpanded else { return }

        pagingMotionActive = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        let token = metadataGate.begin()

        withAnimation(previewExpandAnimation) {
            stateMachine.beginExpand()
            focusedArea = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard metadataGate.isCurrent(token) else { return }
            if !metadataVisible {
                withAnimation(.easeOut(duration: 0.22)) {
                    metadataVisible = true
                }
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                expandedChromeVisible = true
            }

            try? await Task.sleep(nanoseconds: 130_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.finishExpand()
            verticalScrollEnabled = true
        }
    }

    private func handleExpandedExit() {
        handleExit()
    }

    private func handleExit() {
        var nextState = stateMachine
        let action = nextState.exitAction()

        switch action {
        case .dismissOverlay:
            pagingMotionActive = false
            stateMachine.beginExit()
            onDismiss(request.sourceTarget)

        case .collapseToCarousel:
            let token = metadataGate.begin()
            pagingMotionActive = false
            expandedChromeVisible = false
            verticalScrollEnabled = false

            var collapsedState = nextState
            collapsedState.setMotionLocked(true)
            withAnimation(previewExpandAnimation) {
                stateMachine = collapsedState
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard metadataGate.isCurrent(token) else { return }
                stateMachine.setMotionLocked(false)
                withAnimation(.easeOut(duration: 0.22)) {
                    metadataVisible = true
                }
                focusedArea = .carousel
            }
        }
    }

    @MainActor
    private func prefetchAssets(around index: Int) {
        let requests = [index - 1, index, index + 1]
            .filter { request.items.indices.contains($0) }
            .map { request.items[$0].heroBackdropRequest(serverURL: serverURL, authToken: authToken) }

        Task.detached(priority: .utility) { [requests] in
            for request in requests {
                _ = await HeroBackdropResolver.shared.resolveAssets(for: request)
            }
        }
    }

    private func frame(
        for index: Int,
        centeredFrame: CGRect,
        fullFrame: CGRect,
        entryFrame: CGRect
    ) -> CGRect {
        if index == selectedIndex {
            switch stateMachine.phase {
            case .entryMorph:
                return entryFrame
            case .carouselStable, .expandingHero, .expandedHero, .detailsStable, .exiting:
                return centeredFrame
            }
        }

        let offset = index - selectedIndex
        let x = centeredFrame.minX + CGFloat(offset) * (centeredFrame.width + sideCardGap)

        return CGRect(
            x: x,
            y: centeredFrame.minY,
            width: centeredFrame.width,
            height: centeredFrame.height
        )
    }

    private func sanitizedSourceFrame(_ frame: CGRect?, fallback: CGRect, in containerSize: CGSize) -> CGRect {
        guard let frame, frame.width > 0, frame.height > 0 else {
            return fallback
        }

        let clippedX = min(max(frame.minX, 0), max(0, containerSize.width - frame.width))
        let clippedY = min(max(frame.minY, 0), max(0, containerSize.height - frame.height))
        return CGRect(x: clippedX, y: clippedY, width: frame.width, height: frame.height)
    }

    private func cardCornerRadius(for index: Int) -> CGFloat {
        return cornerRadius
    }

    private func cardOpacity(for index: Int) -> Double {
        if index == selectedIndex {
            switch stateMachine.phase {
            case .entryMorph, .carouselStable:
                return 1
            case .expandingHero, .expandedHero, .detailsStable, .exiting:
                return 0
            }
        }

        switch stateMachine.phase {
        case .carouselStable:
            return 1
        case .entryMorph, .expandingHero, .expandedHero, .detailsStable, .exiting:
            return 0
        }
    }

}

private struct PreviewCarouselCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let frame: CGRect
    let phase: PreviewPhase
    let isCurrent: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let pagingMotionActive: Bool
    let motionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void
    let cornerRadius: CGFloat
    let opacity: Double

    private var showsHeroOverlay: Bool {
        isCurrent && phase == .carouselStable && !pagingMotionActive
    }

    var body: some View {
        ZStack {
            PreviewCarouselSideCard(
                item: item,
                serverURL: serverURL,
                authToken: authToken,
                motionLocked: motionLocked,
                backgroundParallaxOffset: backgroundParallaxOffset
            )

            if isCurrent {
                PreviewHeroSurface(
                    item: item,
                    isExpanded: false,
                    metadataVisible: metadataVisible,
                    showExpandedChrome: showExpandedChrome,
                    showBackdropLayer: false,
                    allowVerticalScroll: allowVerticalScroll,
                    allowActionRowInteraction: allowActionRowInteraction,
                    heroBackdropMotionLocked: motionLocked,
                    backgroundParallaxOffset: 0,
                    onPreviewExitRequested: onPreviewExitRequested,
                    onDetailsBecameVisible: onDetailsBecameVisible
                )
                .opacity(showsHeroOverlay ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsHeroOverlay)
        .frame(width: frame.width, height: frame.height)
        .mask(
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
        )
        .opacity(opacity)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }
}

private struct PreviewHeroSurface: View {
    let item: PlexMetadata
    let isExpanded: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let showBackdropLayer: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let heroBackdropMotionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void

    var body: some View {
        PlexDetailView(
            item: item,
            presentationMode: isExpanded ? .expandedDetail : .previewCarousel,
            backgroundParallaxOffset: backgroundParallaxOffset,
            showMetadata: metadataVisible,
            showExpandedChrome: showExpandedChrome,
            showsBackdropLayer: showBackdropLayer,
            allowVerticalScroll: allowVerticalScroll,
            allowActionRowInteraction: allowActionRowInteraction,
            heroBackdropMotionLocked: heroBackdropMotionLocked,
            onPreviewExitRequested: onPreviewExitRequested,
            onDetailsBecameVisible: onDetailsBecameVisible
        )
    }
}

private struct PreviewBackdropStage: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let motionLocked: Bool
    let backgroundParallaxOffset: CGFloat

    @StateObject private var backdropCoordinator = HeroBackdropCoordinator()

    private var request: HeroBackdropRequest {
        item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
    }

    var body: some View {
        HeroBackdropImage(
            url: backdropCoordinator.session.displayedBackdropURL,
            animationDuration: 0.38
        ) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .aspectRatio(contentMode: .fill)
        .scaleEffect(1.08)
        .offset(x: backgroundParallaxOffset)
        .ignoresSafeArea()
        .task(id: request) {
            backdropCoordinator.load(request: request, motionLocked: motionLocked)
        }
        .onChange(of: motionLocked) { _, locked in
            backdropCoordinator.setMotionLocked(locked)
        }
        .animation(previewBackdropPagingAnimation, value: backgroundParallaxOffset)
    }
}

private struct PreviewCarouselSideCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let motionLocked: Bool
    let backgroundParallaxOffset: CGFloat

    @StateObject private var backdropCoordinator = HeroBackdropCoordinator()

    private var request: HeroBackdropRequest {
        item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
    }

    var body: some View {
        HeroBackdropImage(url: backdropCoordinator.session.displayedBackdropURL) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .offset(x: backgroundParallaxOffset)
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .task(id: request) {
            backdropCoordinator.load(request: request, motionLocked: motionLocked)
        }
        .onChange(of: motionLocked) { _, locked in
            backdropCoordinator.setMotionLocked(locked)
        }
    }
}
