//
//  PreviewOverlayHost.swift
//  Rivulet
//
//  In-tree Apple TV-style preview overlay for hub rows.
//

import SwiftUI
import Combine

let previewEntryAnimation = Animation.spring(response: 0.45, dampingFraction: 0.88)
let previewPagingDuration: Double = 0.78
let previewPagingAnimation = Animation.timingCurve(0.40, 0.02, 0.18, 1.0, duration: previewPagingDuration)
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
    @State private var vignetteVisible = false
    @State private var metadataVisible = false
    @State private var expandedChromeVisible = false
    @State private var verticalScrollEnabled = false
    @State private var capturedSourceFrame: CGRect?
    @State private var pagingMotionActive = false
    @State private var pagingFromIndex: Int?
    @State private var pagingProgress: CGFloat = 0
    @State private var metadataGate = PreviewLoadGate()
    @FocusState private var focusedArea: PreviewFocusArea?

    private let topInset: CGFloat = 52
    private let cornerRadius: CGFloat = 28
    private let centeredHorizontalInset: CGFloat = 88
    private let sideCardGap: CGFloat = 14
    private let carouselParallaxFactor: CGFloat = 0.70

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
            return [selectedIndex - 1, selectedIndex, selectedIndex + 1]
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
                Color.black.ignoresSafeArea()

                ForEach(visibleIndices, id: \.self) { index in
                    let cardFrame = frame(
                        for: index,
                        centeredFrame: centeredFrame,
                        fullFrame: fullFrame,
                        entryFrame: entryFrame
                    )
                    PreviewCarouselCard(
                        item: request.items[index],
                        serverURL: serverURL,
                        authToken: authToken,
                        frame: cardFrame,
                        stageSize: geo.size,
                        stageWindowFrame: cardFrame,
                        phase: stateMachine.phase,
                        isCurrent: index == selectedIndex,
                        vignetteVisible: index == selectedIndex && vignetteVisible && !pagingMotionActive,
                        metadataVisible: index == selectedIndex && metadataVisible && !pagingMotionActive,
                        showExpandedChrome: expandedChromeVisible,
                        allowVerticalScroll: verticalScrollEnabled,
                        allowActionRowInteraction: expandedChromeVisible,
                        motionLocked: stateMachine.motionLocked,
                        backgroundParallaxOffset: parallaxOffset(for: index, centeredFrame: centeredFrame),
                        onPreviewExitRequested: handleExpandedExit,
                        onDetailsBecameVisible: {
                            if index == selectedIndex {
                                stateMachine.markDetailsStable()
                            }
                        },
                        cornerRadius: cardCornerRadius(for: index),
                        opacity: cardOpacity(for: index)
                    )
                    .zIndex(cardZIndex(for: index))
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
        vignetteVisible = false
        metadataVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        pagingMotionActive = false
        pagingFromIndex = nil
        pagingProgress = 0
        let token = metadataGate.begin()

        Task { @MainActor in
            await Task.yield()
            withAnimation(previewEntryAnimation) {
                stateMachine.completeEntryMorph()
            }

            // Phase 1: Vignette fades in after card settles
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.setMotionLocked(false)
            withAnimation(.easeOut(duration: 0.6)) {
                vignetteVisible = true
            }

            // Phase 2: Text fades in after vignette established
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.34)) {
                metadataVisible = true
            }
        }
    }

    private func page(by delta: Int) {
        guard stateMachine.isCarouselInputEnabled else { return }
        guard !pagingMotionActive else { return }

        let nextIndex = selectedIndex + delta
        guard request.items.indices.contains(nextIndex) else { return }

        // Fade text + vignette out quickly before horizontal travel
        metadataVisible = false
        vignetteVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false
        pagingMotionActive = true
        pagingFromIndex = selectedIndex
        pagingProgress = 0

        let token = metadataGate.begin()
        stateMachine.beginPaging()

        // Drive both card motion and inner-image parallax from one progress track.
        withAnimation(previewPagingAnimation) {
            selectedIndex = nextIndex
            pagingProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(previewPagingDuration * 1_000_000_000))
            guard metadataGate.isCurrent(token) else { return }
            stateMachine.finishPaging()
            pagingMotionActive = false
            pagingFromIndex = nil
            pagingProgress = 0

            // Brief settle, then staged in-place fade for vignette then text.
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.26)) {
                vignetteVisible = true
            }

            try? await Task.sleep(nanoseconds: 70_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeOut(duration: 0.48)) {
                metadataVisible = true
            }
        }
    }

    private func expandCurrentCard() {
        guard !stateMachine.isExpanded else { return }

        pagingMotionActive = false
        pagingFromIndex = nil
        pagingProgress = 0
        expandedChromeVisible = false
        verticalScrollEnabled = false
        let token = metadataGate.begin()

        // Ensure vignette is showing during expansion
        if !vignetteVisible {
            withAnimation(.easeOut(duration: 0.3)) {
                vignetteVisible = true
            }
        }

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
            pagingFromIndex = nil
            pagingProgress = 0
            stateMachine.beginExit()
            onDismiss(request.sourceTarget)

        case .collapseToCarousel:
            let token = metadataGate.begin()
            pagingMotionActive = false
            pagingFromIndex = nil
            pagingProgress = 0
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
                // Vignette should already be visible; ensure it is
                if !vignetteVisible {
                    withAnimation(.easeOut(duration: 0.4)) {
                        vignetteVisible = true
                    }
                }
                withAnimation(.easeOut(duration: 0.25)) {
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
            case .carouselStable, .exiting:
                return carouselFrame(for: index, centeredFrame: centeredFrame)
            case .expandingHero, .expandedHero, .detailsStable:
                // Card expands to full screen — the mask reveals the backdrop
                return fullFrame
            }
        }

        if stateMachine.phase == .carouselStable {
            return carouselFrame(for: index, centeredFrame: centeredFrame)
        }

        let offset = CGFloat(index - selectedIndex)
        let x = centeredFrame.minX + offset * (centeredFrame.width + sideCardGap)

        return CGRect(
            x: x,
            y: centeredFrame.minY,
            width: centeredFrame.width,
            height: centeredFrame.height
        )
    }

    private func carouselFrame(for index: Int, centeredFrame: CGRect) -> CGRect {
        let slot = carouselSlotPosition(for: index)
        let x = centeredFrame.minX + slot * (centeredFrame.width + sideCardGap)

        return CGRect(
            x: x,
            y: centeredFrame.minY,
            width: centeredFrame.width,
            height: centeredFrame.height
        )
    }

    private func carouselSlotPosition(for index: Int) -> CGFloat {
        let fromIndex = pagingFromIndex ?? selectedIndex
        let toIndex = selectedIndex
        let startPos = CGFloat(index - fromIndex)
        let endPos = CGFloat(index - toIndex)
        if stateMachine.phase == .carouselStable, pagingMotionActive {
            return startPos + ((endPos - startPos) * pagingProgress)
        }
        return endPos
    }

    private func parallaxOffset(for index: Int, centeredFrame: CGRect) -> CGFloat {
        guard stateMachine.phase == .carouselStable else { return 0 }
        // Keep parallax tied to the same slot position as the card's x-translation.
        // Side cards are pre-offset while idle, so there is no jump on paging start.
        let slot = carouselSlotPosition(for: index)
        let deltaFromCenter = slot * (centeredFrame.width + sideCardGap)
        return -deltaFromCenter * carouselParallaxFactor
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
        if index == selectedIndex {
            switch stateMachine.phase {
            case .expandingHero, .expandedHero, .detailsStable:
                return 0
            default:
                break
            }
        }
        return cornerRadius
    }

    private func cardOpacity(for index: Int) -> Double {
        if index == selectedIndex {
            return 1  // Selected card always visible — mask reveals/hides
        }

        switch stateMachine.phase {
        case .carouselStable:
            return 1
        case .entryMorph, .expandingHero, .expandedHero, .detailsStable, .exiting:
            return 0
        }
    }

    private func cardZIndex(for index: Int) -> Double {
        switch stateMachine.phase {
        case .entryMorph, .carouselStable:
            // Apple TV+ carousel behavior: cards stay on a single visual plane.
            return 1
        case .expandingHero, .expandedHero, .detailsStable, .exiting:
            return index == selectedIndex ? 2 : 1
        }
    }

}

private struct PreviewCarouselCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let frame: CGRect
    let stageSize: CGSize
    let stageWindowFrame: CGRect
    let phase: PreviewPhase
    let isCurrent: Bool
    let vignetteVisible: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let motionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void
    let cornerRadius: CGFloat
    let opacity: Double

    private var showsCarouselOverlay: Bool {
        phase == .carouselStable && isCurrent
    }

    private var isCardExpanded: Bool {
        isCurrent && (phase == .expandedHero || phase == .detailsStable)
    }

    private var usesExpandedSurface: Bool {
        isCurrent && (phase == .expandingHero || phase == .expandedHero || phase == .detailsStable)
    }

    var body: some View {
        ZStack {
            if usesExpandedSurface {
                PreviewHeroSurface(
                    item: item,
                    isExpanded: isCardExpanded,
                    vignetteVisible: vignetteVisible,
                    metadataVisible: metadataVisible,
                    showExpandedChrome: showExpandedChrome,
                    showBackdropLayer: true,
                    allowVerticalScroll: allowVerticalScroll,
                    allowActionRowInteraction: allowActionRowInteraction,
                    heroBackdropMotionLocked: motionLocked,
                    backgroundParallaxOffset: backgroundParallaxOffset,
                    backdropStageSize: stageSize,
                    backdropWindowFrame: stageWindowFrame,
                    onPreviewExitRequested: onPreviewExitRequested,
                    onDetailsBecameVisible: onDetailsBecameVisible
                )
            } else if phase == .carouselStable {
                // Keep all carousel cards on the same rendering path so the
                // incoming card's artwork slides in with the card instead of
                // swapping surface type at the moment it becomes centered.
                PreviewHeroSurface(
                    item: item,
                    isExpanded: false,
                    vignetteVisible: isCurrent ? vignetteVisible : false,
                    metadataVisible: isCurrent ? metadataVisible : false,
                    showExpandedChrome: isCurrent ? showExpandedChrome : false,
                    showBackdropLayer: true,
                    allowVerticalScroll: isCurrent ? allowVerticalScroll : false,
                    allowActionRowInteraction: isCurrent ? allowActionRowInteraction : false,
                    heroBackdropMotionLocked: motionLocked,
                    backgroundParallaxOffset: backgroundParallaxOffset,
                    backdropStageSize: stageSize,
                    backdropWindowFrame: stageWindowFrame,
                    onPreviewExitRequested: onPreviewExitRequested,
                    onDetailsBecameVisible: onDetailsBecameVisible
                )
                .allowsHitTesting(false)
                if showsCarouselOverlay {
                    PreviewCarouselStageWindow(cornerRadius: cornerRadius)
                }
            } else {
                PreviewCarouselSideCard(
                    item: item,
                    serverURL: serverURL,
                    authToken: authToken,
                    motionLocked: motionLocked
                )
            }
        }
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
        .allowsHitTesting(usesExpandedSurface && isCardExpanded)
    }
}

private struct PreviewCarouselStageWindow: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.clear
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct PreviewHeroSurface: View {
    let item: PlexMetadata
    let isExpanded: Bool
    let vignetteVisible: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let showBackdropLayer: Bool
    let allowVerticalScroll: Bool
    let allowActionRowInteraction: Bool
    let heroBackdropMotionLocked: Bool
    let backgroundParallaxOffset: CGFloat
    let backdropStageSize: CGSize
    let backdropWindowFrame: CGRect
    let onPreviewExitRequested: () -> Void
    let onDetailsBecameVisible: () -> Void

    var body: some View {
        PlexDetailView(
            item: item,
            presentationMode: isExpanded ? .expandedDetail : .previewCarousel,
            backgroundParallaxOffset: backgroundParallaxOffset,
            showVignette: vignetteVisible,
            showMetadata: metadataVisible,
            showExpandedChrome: showExpandedChrome,
            showsBackdropLayer: showBackdropLayer,
            allowVerticalScroll: allowVerticalScroll,
            allowActionRowInteraction: allowActionRowInteraction,
            heroBackdropMotionLocked: heroBackdropMotionLocked,
            backdropStageSize: backdropStageSize,
            backdropWindowFrame: backdropWindowFrame,
            onPreviewExitRequested: onPreviewExitRequested,
            onDetailsBecameVisible: onDetailsBecameVisible
        )
    }
}

private struct PreviewCarouselSideCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let motionLocked: Bool

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
        // Scale so image is already ~full-screen sized even inside the narrower card.
        // When the card expands during hero transition, the image doesn't resize —
        // the mask just reveals more of the already-positioned image.
        .scaleEffect(1.08)
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
