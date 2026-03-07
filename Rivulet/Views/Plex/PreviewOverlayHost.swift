//
//  PreviewOverlayHost.swift
//  Rivulet
//
//  In-tree Apple TV-style preview overlay for hub rows.
//

import SwiftUI

let previewEntryAnimation = Animation.spring(response: 0.46, dampingFraction: 0.86)
let previewPagingAnimation = Animation.interactiveSpring(response: 0.40, dampingFraction: 0.90)
let previewExpandAnimation = Animation.spring(response: 0.44, dampingFraction: 0.84)

struct PreviewOverlayHost: View {
    let request: PreviewRequest
    let sourceFrames: [PreviewSourceTarget: CGRect]
    let serverURL: String
    let authToken: String
    let onDismiss: (PreviewSourceTarget) -> Void

    @State private var selectedIndex: Int
    @State private var stateMachine = PreviewStateMachine()
    @State private var metadataVisible = false
    @State private var expandedChromeVisible = false
    @State private var verticalScrollEnabled = false
    @State private var currentParallaxOffset: CGFloat = 0
    @State private var capturedSourceFrame: CGRect?
    @State private var metadataGate = PreviewLoadGate()
    @FocusState private var focusedArea: PreviewFocusArea?

    private let topInset: CGFloat = 52
    private let bottomInset: CGFloat = 128
    private let cardAspectRatio: CGFloat = 16.0 / 9.0
    private let cornerRadius: CGFloat = 44
    private let sidePeek: CGFloat = 160
    private let sideScale: CGFloat = 0.94
    private let sideOpacity: Double = 0.55
    private let parallaxTravel: CGFloat = 36

    init(
        request: PreviewRequest,
        sourceFrames: [PreviewSourceTarget: CGRect],
        serverURL: String,
        authToken: String,
        onDismiss: @escaping (PreviewSourceTarget) -> Void
    ) {
        self.request = request
        self.sourceFrames = sourceFrames
        self.serverURL = serverURL
        self.authToken = authToken
        self.onDismiss = onDismiss
        self._selectedIndex = State(initialValue: request.selectedIndex)
    }

    private var currentItem: PlexMetadata {
        request.items[selectedIndex]
    }

    private var visibleIndices: [Int] {
        switch stateMachine.phase {
        case .enteringCarousel, .expanded:
            return [selectedIndex]
        case .carousel, .expanding:
            return [selectedIndex - 1, selectedIndex, selectedIndex + 1]
                .filter { request.items.indices.contains($0) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let centeredWidth = max(0, geo.size.width - (sidePeek * 2))
            let centeredHeight = max(0, min(centeredWidth / cardAspectRatio, geo.size.height - topInset - bottomInset))
            let centeredFrame = CGRect(
                x: sidePeek,
                y: topInset,
                width: centeredWidth,
                height: centeredHeight
            )
            let fullFrame = CGRect(origin: .zero, size: geo.size)
            let entryFrame = sanitizedSourceFrame(
                capturedSourceFrame ?? sourceFrames[request.sourceTarget],
                fallback: centeredFrame,
                in: geo.size
            )

            ZStack {
                PreviewOverlayBackdrop(
                    url: previewArtURL(for: currentItem),
                    parallaxOffset: currentParallaxOffset
                )

                ForEach(visibleIndices, id: \.self) { index in
                    PreviewCarouselCard(
                        item: request.items[index],
                        serverURL: serverURL,
                        authToken: authToken,
                        frame: frame(
                            for: index,
                            centeredFrame: centeredFrame,
                            fullFrame: fullFrame,
                            entryFrame: entryFrame,
                            containerSize: geo.size
                        ),
                        isCurrent: index == selectedIndex,
                        isExpanded: stateMachine.isExpanded,
                        metadataVisible: index == selectedIndex && metadataVisible,
                        showExpandedChrome: expandedChromeVisible,
                        allowVerticalScroll: verticalScrollEnabled,
                        backgroundParallaxOffset: index == selectedIndex ? currentParallaxOffset : 0,
                        cornerRadius: cardCornerRadius(for: index),
                        opacity: cardOpacity(for: index),
                        scale: cardScale(for: index),
                        onPreviewExitRequested: handleExpandedExit
                    )
                    .zIndex(index == selectedIndex ? 2 : 1)
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
                        .onExitCommand {
                            handleExit()
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
        }
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
        let token = metadataGate.begin()

        Task { @MainActor in
            await Task.yield()
            withAnimation(previewEntryAnimation) {
                stateMachine.completeEntry()
            }
            scheduleMetadataReveal(token: token, delayNanoseconds: 180_000_000)
        }
    }

    private func page(by delta: Int) {
        guard stateMachine.isCarouselInputEnabled else { return }

        let nextIndex = selectedIndex + delta
        guard request.items.indices.contains(nextIndex) else { return }

        metadataVisible = false
        expandedChromeVisible = false
        verticalScrollEnabled = false

        let token = metadataGate.begin()
        currentParallaxOffset = delta > 0 ? -parallaxTravel : parallaxTravel

        withAnimation(previewPagingAnimation) {
            selectedIndex = nextIndex
            currentParallaxOffset = 0
        }

        scheduleMetadataReveal(token: token, delayNanoseconds: 120_000_000)
    }

    private func expandCurrentCard() {
        guard !stateMachine.isExpanded else { return }

        expandedChromeVisible = false
        verticalScrollEnabled = false
        let token = metadataGate.begin()

        withAnimation(previewExpandAnimation) {
            stateMachine.beginExpand()
            focusedArea = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedChromeVisible = true
            }

            try? await Task.sleep(nanoseconds: 360_000_000)
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
            onDismiss(request.sourceTarget)

        case .collapseToCarousel:
            let token = metadataGate.begin()
            expandedChromeVisible = false
            verticalScrollEnabled = false

            withAnimation(previewExpandAnimation) {
                stateMachine = nextState
                currentParallaxOffset = 0
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard metadataGate.isCurrent(token) else { return }
                focusedArea = .carousel
            }
        }
    }

    private func scheduleMetadataReveal(token: Int, delayNanoseconds: UInt64) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard metadataGate.isCurrent(token) else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                metadataVisible = true
            }
        }
    }

    private func prefetchAssets(around index: Int) {
        let adjacentItems = [index - 1, index + 1]
            .filter { request.items.indices.contains($0) }
            .map { request.items[$0] }

        let artURLs = adjacentItems.compactMap { previewArtURL(for: $0) }
        if !artURLs.isEmpty {
            Task {
                await ImageCacheManager.shared.prefetch(urls: artURLs)
            }
        }

        let logoRequests = adjacentItems.compactMap { item -> (id: Int, type: TMDBMediaType)? in
            switch item.type {
            case "movie":
                if let tmdbId = item.tmdbId {
                    return (tmdbId, .movie)
                }
            case "show":
                if let tmdbId = item.tmdbId {
                    return (tmdbId, .tv)
                }
            case "episode":
                if let tmdbId = item.showTmdbId {
                    return (tmdbId, .tv)
                }
            default:
                break
            }
            return nil
        }

        Task.detached(priority: .utility) {
            for logoRequest in logoRequests {
                _ = await TMDBClient.shared.fetchLogoURL(tmdbId: logoRequest.id, type: logoRequest.type)
            }
        }
    }

    private func previewArtURL(for item: PlexMetadata) -> URL? {
        let path = item.bestArt ?? item.bestThumb
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }

    private func frame(
        for index: Int,
        centeredFrame: CGRect,
        fullFrame: CGRect,
        entryFrame: CGRect,
        containerSize: CGSize
    ) -> CGRect {
        let scaleCompensation = centeredFrame.width * (1 - sideScale) * 0.5

        if index == selectedIndex {
            switch stateMachine.phase {
            case .enteringCarousel:
                return entryFrame
            case .carousel:
                return centeredFrame
            case .expanding, .expanded:
                return fullFrame
            }
        }

        if index < selectedIndex {
            return CGRect(
                x: -centeredFrame.width + sidePeek + scaleCompensation,
                y: centeredFrame.minY,
                width: centeredFrame.width,
                height: centeredFrame.height
            )
        }

        return CGRect(
            x: containerSize.width - sidePeek - scaleCompensation,
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
        if index == selectedIndex && stateMachine.isExpanded {
            return 0
        }
        return cornerRadius
    }

    private func cardOpacity(for index: Int) -> Double {
        guard index != selectedIndex else { return 1 }
        switch stateMachine.phase {
        case .carousel:
            return sideOpacity
        case .expanding, .enteringCarousel, .expanded:
            return 0
        }
    }

    private func cardScale(for index: Int) -> CGFloat {
        index == selectedIndex ? 1 : sideScale
    }
}

private struct PreviewOverlayBackdrop: View {
    let url: URL?
    let parallaxOffset: CGFloat

    var body: some View {
        ZStack {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    Rectangle()
                        .fill(Color.black)
                case .failure:
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.12), Color.black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                @unknown default:
                    Rectangle()
                        .fill(Color.black)
                }
            }
            .scaleEffect(1.06)
            .offset(x: parallaxOffset * 0.4)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.58),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.16)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct PreviewCarouselCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let frame: CGRect
    let isCurrent: Bool
    let isExpanded: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let allowVerticalScroll: Bool
    let backgroundParallaxOffset: CGFloat
    let cornerRadius: CGFloat
    let opacity: Double
    let scale: CGFloat
    let onPreviewExitRequested: () -> Void

    var body: some View {
        Group {
            if isCurrent {
                PreviewHeroSurface(
                    item: item,
                    serverURL: serverURL,
                    authToken: authToken,
                    isExpanded: isExpanded,
                    metadataVisible: metadataVisible,
                    showExpandedChrome: showExpandedChrome,
                    allowVerticalScroll: allowVerticalScroll,
                    backgroundParallaxOffset: backgroundParallaxOffset,
                    onPreviewExitRequested: onPreviewExitRequested
                )
            } else {
                PreviewCarouselSideCard(
                    item: item,
                    serverURL: serverURL,
                    authToken: authToken
                )
            }
        }
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(scale)
        .opacity(opacity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(isCurrent && !isExpanded ? 0.35 : 0.18), radius: 28, y: 18)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(isCurrent && isExpanded)
    }
}

private struct PreviewHeroSurface: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let isExpanded: Bool
    let metadataVisible: Bool
    let showExpandedChrome: Bool
    let allowVerticalScroll: Bool
    let backgroundParallaxOffset: CGFloat
    let onPreviewExitRequested: () -> Void

    var body: some View {
        PlexDetailView(
            item: item,
            presentationMode: isExpanded ? .expandedDetail : .previewCarousel,
            backgroundParallaxOffset: backgroundParallaxOffset,
            showMetadata: metadataVisible,
            showExpandedChrome: showExpandedChrome,
            allowVerticalScroll: allowVerticalScroll,
            onPreviewExitRequested: onPreviewExitRequested
        )
    }
}

private struct PreviewCarouselSideCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            sideArtwork

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.28),
                    .black.opacity(0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 34)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var sideArtwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.12))
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.5))
                    }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            @unknown default:
                Rectangle()
                    .fill(Color(white: 0.12))
            }
        }
    }

    private var subtitleText: String? {
        if item.type == "episode" {
            let parts = [item.episodeString, item.durationFormatted].compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: " • ")
            }
        }
        return item.tagline ?? item.summary
    }

    private var artworkURL: URL? {
        let path = item.bestArt ?? item.bestThumb
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }
}

private extension PlexMetadata {
    var displayTitle: String {
        if type == "episode" {
            return grandparentTitle ?? title ?? "Unknown Title"
        }
        return title ?? "Unknown Title"
    }
}
