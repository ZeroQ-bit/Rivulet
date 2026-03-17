//
//  LiveTVPlayerView.swift
//  Rivulet
//
//  Unified Live TV player supporting 1-4 simultaneous streams
//

import SwiftUI
import Combine

@MainActor
private final class LiveTVPlaybackInputTarget: PlaybackInputTarget {
    weak var viewModel: MultiStreamViewModel?
    var canHandleTransport: (() -> Bool)?
    var canHandleDirectionalNavigation: (() -> Bool)?
    var onDirectionalNavigation: ((MoveCommandDirection) -> Void)?
    var onFocusPulse: (() -> Void)?
    var onBack: (() -> Void)?
    var onShowInfo: (() -> Void)?

    init(viewModel: MultiStreamViewModel) {
        self.viewModel = viewModel
    }

    var isScrubbingForInput: Bool {
        viewModel?.isScrubbing ?? false
    }

    private func transitionForScrubNudge(
        wasScrubbing: Bool,
        speedBefore: Int,
        speedAfter: Int
    ) -> PlaybackInputTelemetry.ScrubTransition {
        if !wasScrubbing || speedBefore == 0 {
            return .start
        }

        let beforeDirection = speedBefore > 0 ? 1 : -1
        let afterDirection = speedAfter > 0 ? 1 : -1
        if beforeDirection != afterDirection {
            return .reverse
        }
        if abs(speedAfter) > abs(speedBefore) {
            return .speedUp
        }
        if abs(speedAfter) < abs(speedBefore) {
            return .slowDown
        }
        return .start
    }

    private func navigationDirection(
        for action: PlaybackInputAction,
        source: PlaybackInputSource
    ) -> MoveCommandDirection? {
        // In multiview, left/right directional intent should switch focused stream.
        switch action {
        case .scrubNudge(let forward):
            return forward ? .right : .left
        case .seekRelative(let seconds):
            guard source != .mpRemoteCommand else { return nil }
            guard abs(seconds) < InputConfig.jumpSeekSeconds else { return nil }
            return seconds >= 0 ? .right : .left
        default:
            return nil
        }
    }

    func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
        guard let viewModel else { return }

        if viewModel.streamCount > 1,
           canHandleDirectionalNavigation?() ?? true,
           let direction = navigationDirection(for: action, source: source) {
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .cancel,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                viewModel.cancelScrubFocused()
            }
            onDirectionalNavigation?(direction)
            onFocusPulse?()
            return
        }

        switch action {
        case .play:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                viewModel.commitScrubFocused()
            } else {
                viewModel.playFocused()
            }
            onFocusPulse?()

        case .pause:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                viewModel.commitScrubFocused()
            } else {
                viewModel.pauseFocused()
            }
            onFocusPulse?()

        case .playPause:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                viewModel.commitScrubFocused()
            } else {
                viewModel.togglePlayPauseOnFocused()
            }
            onFocusPulse?()

        case .seekRelative(let seconds):
            guard canHandleTransport?() ?? true else { return }
            if viewModel.isScrubbing {
                viewModel.updateScrubFocusedPosition(by: seconds)
            } else {
                viewModel.seekFocused(by: seconds)
            }
            onFocusPulse?()

        case .seekAbsolute:
            // Live TV does not currently expose absolute seek control.
            break

        case .stepSeek, .jumpSeek:
            // Coordinator normalizes these to .seekRelative before dispatch.
            break

        case .scrubNudge(let forward):
            guard canHandleTransport?() ?? true else { return }
            let wasScrubbing = viewModel.isScrubbing
            let speedBefore = viewModel.scrubSpeed
            viewModel.scrubFocusedInDirection(forward: forward)
            let speedAfter = viewModel.scrubSpeed
            PlaybackInputTelemetry.shared.recordScrubTransition(
                surface: .liveTV,
                transition: transitionForScrubNudge(
                    wasScrubbing: wasScrubbing,
                    speedBefore: speedBefore,
                    speedAfter: speedAfter
                ),
                source: source,
                speedBefore: speedBefore,
                speedAfter: speedAfter
            )
            onFocusPulse?()

        case .scrubRelative(let seconds):
            guard canHandleTransport?() ?? true else { return }
            viewModel.updateScrubFocusedPosition(by: seconds)
            onFocusPulse?()

        case .scrubCommit:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .commit,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
            }
            viewModel.commitScrubFocused()
            onFocusPulse?()

        case .scrubCancel:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .cancel,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
            }
            viewModel.cancelScrubFocused()
            onFocusPulse?()

        case .showInfo:
            onShowInfo?()

        case .back:
            if viewModel.isScrubbing {
                let speedBefore = viewModel.scrubSpeed
                PlaybackInputTelemetry.shared.recordScrubTransition(
                    surface: .liveTV,
                    transition: .cancel,
                    source: source,
                    speedBefore: speedBefore,
                    speedAfter: 0
                )
                viewModel.cancelScrubFocused()
            } else {
                onBack?()
            }
            onFocusPulse?()
        }
    }
}

struct LiveTVPlayerView: View {
    @StateObject private var viewModel: MultiStreamViewModel
    @StateObject private var remoteInput = RemoteInputHandler()
    @State private var inputCoordinator = PlaybackInputCoordinator()
    @State private var inputTarget: LiveTVPlaybackInputTarget?
    @AppStorage("confirmExitMultiview") private var confirmExitMultiview = true
    @AppStorage("classicTVMode") private var classicTVMode = false
    @State private var showExitConfirmation = false
    @State private var showChannelBadges = true
    @State private var channelBadgeTimer: Timer?
    @State private var showFocusBorder = true
    @State private var focusBorderTimer: Timer?
    @State private var hasStoppedStreams = false
    @State private var debugId = String(UUID().uuidString.prefix(8))

    // Dismiss callback - used instead of @Environment(\.dismiss) since we use ZStack overlay
    private let onDismiss: () -> Void
    // PIP callback - called when user wants to enter PIP mode instead of dismissing
    private let onEnterPIP: (() -> Void)?
    // When false, player doesn't capture focus (used for PIP mode)
    private let isInteractive: Bool

    // Focus management
    @FocusState private var focusArea: FocusArea?

    enum FocusArea: Hashable {
        case streamGrid
        case controlButton(Int)
        case exitConfirmButton(Int)
    }

    init(channel: UnifiedChannel, onDismiss: @escaping () -> Void, onEnterPIP: (() -> Void)? = nil, isInteractive: Bool = true) {
        _viewModel = StateObject(wrappedValue: MultiStreamViewModel(initialChannel: channel))
        self.onDismiss = onDismiss
        self.onEnterPIP = onEnterPIP
        self.isInteractive = isInteractive
    }

    @Namespace private var playerFocusNamespace

    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()

            // Stream grid (or single stream fullscreen)
            // Transaction prevents animations from affecting player views when state changes
            streamContent
                .transaction { transaction in
                    transaction.animation = nil
                }

            if isInteractive && !viewModel.showControls && !viewModel.showChannelPicker && !showExitConfirmation {
                LiveTVPressCatcher { action in
                    inputCoordinator.handle(action: action, source: .irPress)
                }
                .ignoresSafeArea()
                .zIndex(50)
            }

            // Controls overlay (hidden in classic TV mode and PIP mode)
            if isInteractive && viewModel.showControls && !classicTVMode {
                controlsOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // Channel picker (for adding or replacing streams, not shown in PIP mode)
            if isInteractive && viewModel.showChannelPicker {
                // When replacing, don't exclude the current channel (user might want to re-select it)
                let excludedIds: Set<String> = {
                    if viewModel.replaceSlotIndex != nil,
                       let currentId = viewModel.focusedStream?.channel.id {
                        return viewModel.activeChannelIds.subtracting([currentId])
                    }
                    return viewModel.activeChannelIds
                }()
                ChannelPickerSheet(
                    excludedChannelIds: excludedIds,
                    onSelect: { channel in
                        Task {
                            if let replaceIndex = viewModel.replaceSlotIndex {
                                // Replace the stream at the specified index
                                await viewModel.replaceStream(at: replaceIndex, with: channel)
                            } else {
                                // Add a new stream
                                await viewModel.addChannel(channel)
                            }
                        }
                    },
                    onDismiss: {
                        viewModel.showChannelPicker = false
                        viewModel.replaceSlotIndex = nil
                    }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Exit confirmation overlay (not shown in PIP mode)
            if isInteractive && showExitConfirmation {
                exitConfirmationOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .focusScope(playerFocusNamespace)
        .focusSection()
        .defaultFocus($focusArea, .streamGrid)
        .disabled(!isInteractive)  // Disable focus capture when in PIP mode
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.25), value: showChannelBadges)
        // Don't animate stream count changes to keep stream surfaces stable during layout changes.
        .onPlayPauseCommand {
            guard isInteractive else { return }  // Ignore when in PIP mode
            inputCoordinator.handle(action: .playPause, source: .swiftUICommand)
        }
        .onExitCommand {
            guard isInteractive else { return }  // Ignore when in PIP mode
            inputCoordinator.handle(action: .back, source: .swiftUICommand)
        }
        .onChange(of: viewModel.showControls) { _, showControls in
            if showControls {
                // When controls appear, focus the play/pause button (always index 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    focusArea = .controlButton(0)
                }
            } else {
                // When controls hide, focus the stream grid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusArea = .streamGrid
                }
            }
        }
        .onChange(of: focusArea) { _, newFocus in
            // Reset hide timer when navigating between control buttons
            if case .controlButton = newFocus {
                viewModel.resetControlsTimer()
            }
        }
        .onChange(of: viewModel.focusedSlotIndex) { _, _ in
            // Show channel badges and focus border briefly when switching focused stream in multiview
            if viewModel.streamCount > 1 {
                showChannelBadgesTemporarily()
                showFocusBorderTemporarily()
            }
        }
        .onChange(of: viewModel.showControls) { _, showControls in
            // Show/hide badges and focus border with controls
            if showControls {
                channelBadgeTimer?.invalidate()
                focusBorderTimer?.invalidate()
                withAnimation(.easeInOut(duration: 0.25)) {
                    showChannelBadges = true
                    showFocusBorder = true
                }
            } else {
                // Start hide timers when controls hide
                showChannelBadgesTemporarily()
                showFocusBorderTemporarily()
            }
        }
        .onAppear {
            if isInteractive {
                let target = LiveTVPlaybackInputTarget(viewModel: viewModel)
                target.canHandleTransport = { [viewModel] in
                    !viewModel.showControls && !viewModel.showChannelPicker
                }
                target.canHandleDirectionalNavigation = { [viewModel] in
                    !viewModel.showControls && !viewModel.showChannelPicker
                }
                target.onDirectionalNavigation = { direction in
                    handleStreamNavigation(direction)
                }
                target.onFocusPulse = {
                    showFocusBorderTemporarily()
                }
                target.onBack = {
                    handleExitCommand()
                }
                target.onShowInfo = {
                    showControlsWithFocus()
                }
                inputTarget = target
                inputCoordinator.target = target

                remoteInput.isScrubbingCheck = { [weak viewModel] in
                    viewModel?.isScrubbing ?? false
                }
                remoteInput.isActivelyScrubbing = { [weak viewModel] in
                    (viewModel?.scrubSpeed ?? 0) != 0
                }
                remoteInput.isPostVideoCheck = { false }
                remoteInput.isErrorCheck = { false }
                remoteInput.isPausedCheck = { false }
                remoteInput.onAction = { [inputCoordinator] action, source in
                    inputCoordinator.handle(action: action, source: source)
                }
                remoteInput.startMonitoring()
            }
            // Start with controls hidden, focus on stream grid
            viewModel.showControls = false
            // Delay focus grab slightly to ensure view is laid out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusArea = .streamGrid
            }
            // Show badges and focus border initially then auto-hide
            showChannelBadgesTemporarily()
            showFocusBorderTemporarily()
        }
        .onDisappear {
            remoteInput.stopMonitoring()
            remoteInput.reset()
            inputCoordinator.invalidate()
            inputTarget = nil
            channelBadgeTimer?.invalidate()
            focusBorderTimer?.invalidate()
            // Only stop streams if we're actually exiting (not showing confirmation)
            if !showExitConfirmation && !hasStoppedStreams {
                hasStoppedStreams = true
                viewModel.stopAllStreams()
            }
        }
        .onChange(of: showExitConfirmation) { _, show in
            if show {
                // Focus the Cancel button (index 0) when confirmation appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusArea = .exitConfirmButton(0)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showExitConfirmation)
        // System appearance
    }

    // MARK: - Stream Content

    // Always use streamGrid for all stream counts (1-4) to prevent view hierarchy
    // destruction when transitioning from 1 to 2 streams. The grid layout handles
    // single streams as a 1x1 fullscreen layout.
    private var streamContent: some View {
        streamGrid
    }

    private var streamGrid: some View {
        GeometryReader { geometry in
            let frames = layoutFrames(for: geometry.size)

            ZStack(alignment: .topLeading) {
                ForEach(viewModel.streams, id: \.id) { slot in
                    if let rect = frames[slot.id] {
                        let index = viewModel.streams.firstIndex(where: { $0.id == slot.id }) ?? 0
                        StreamSlotView(
                            slot: slot,
                            index: index,
                            // Show focus border when: controls are visible OR the timed focus border is showing
                            isFocused: viewModel.focusedSlotIndex == index && (viewModel.showControls || showFocusBorder),
                            showBorder: viewModel.streamCount > 1,
                            showChannelBadge: showChannelBadges
                        )
                        .id(slot.id)
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .position(x: rect.midX, y: rect.midY)
                        // Prevent animations from affecting this stream when others change
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                }
            }
            // Disable animations on the entire grid when stream count changes
            .transaction { transaction in
                transaction.animation = nil
            }

            // Invisible focusable overlay for stream navigation
            // Only render when interactive (not in PIP mode)
            if isInteractive && !viewModel.showControls && !showExitConfirmation {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focusArea, equals: .streamGrid)
                    .prefersDefaultFocus(in: playerFocusNamespace)
                    .onTapGesture {
                        // Select pressed - show controls
                        showControlsWithFocus()
                    }
                    .onMoveCommand { direction in
                        handleStreamNavigation(direction)
                    }
                    .onExitCommand {
                        inputCoordinator.handle(action: .back, source: .swiftUICommand)
                    }
            }
        }
        .ignoresSafeArea(edges: isInteractive ? .all : [])
    }

    private func layoutFrames(for size: CGSize) -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]

        // Single stream: use full screen, no spacing or aspect ratio constraints.
        if viewModel.streamCount == 1, let slot = viewModel.streams.first {
            frames[slot.id] = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            return frames
        }

        let spacing: CGFloat = 8
        let aspect: CGFloat = 16.0 / 9.0

        if case .focus(let mainId) = viewModel.layoutMode, viewModel.streamCount > 1 {
            let mainSlot = viewModel.streams.first(where: { $0.id == mainId }) ?? viewModel.streams.first
            let sideStreams = viewModel.streams.filter { $0.id != mainSlot?.id }
            let sideCount = max(sideStreams.count, 1)

            // Main stream: 75% width, maintain 16:9 aspect ratio
            let mainWidth = size.width * 0.75
            let mainHeight = min(mainWidth / aspect, size.height)
            let actualMainWidth = mainHeight * aspect  // Recalculate if height-constrained

            // Side streams: remaining width, stacked vertically with 16:9 aspect
            let sideWidth = size.width - actualMainWidth - spacing * 2
            let sideSlotHeight = sideWidth / aspect
            let totalSideHeight = sideSlotHeight * CGFloat(sideCount) + spacing * CGFloat(sideCount - 1)

            // Center everything vertically
            let mainY = (size.height - mainHeight) / 2
            let sideStartY = (size.height - totalSideHeight) / 2

            // Center everything horizontally
            let totalWidth = actualMainWidth + spacing + sideWidth
            let startX = (size.width - totalWidth) / 2

            if let mainSlot {
                frames[mainSlot.id] = CGRect(x: startX, y: mainY, width: actualMainWidth, height: mainHeight)
            }

            var currentY = sideStartY
            for slot in sideStreams {
                frames[slot.id] = CGRect(x: startX + actualMainWidth + spacing, y: currentY, width: sideWidth, height: sideSlotHeight)
                currentY += sideSlotHeight + spacing
            }
        } else {
            let layout = gridLayout(for: viewModel.streamCount)
            let availableWidth = size.width - CGFloat(layout.columns - 1) * spacing
            let availableHeight = size.height - CGFloat(layout.rows - 1) * spacing
            let slotWidth = availableWidth / CGFloat(layout.columns)
            let maxRowHeight = availableHeight / CGFloat(layout.rows)
            let slotHeight = min(slotWidth / aspect, maxRowHeight)
            let totalHeight = slotHeight * CGFloat(layout.rows) + spacing * CGFloat(layout.rows - 1)
            let verticalPadding = max(0, (size.height - totalHeight) / 2)

            for row in 0..<layout.rows {
                for col in 0..<layout.columns {
                    let index = row * layout.columns + col
                    guard index < viewModel.streams.count else { continue }
                    let x = (slotWidth + spacing) * CGFloat(col)
                    let y = verticalPadding + (slotHeight + spacing) * CGFloat(row)
                    frames[viewModel.streams[index].id] = CGRect(x: x, y: y, width: slotWidth, height: slotHeight)
                }
            }
        }

        return frames
    }

    private func gridLayout(for count: Int) -> (rows: Int, columns: Int) {
        switch count {
        case 0, 1:
            return (1, 1)
        case 2:
            return (1, 2)  // Side by side
        case 3, 4:
            return (2, 2)  // 2x2 grid (3 streams = 3 videos + 1 black space)
        default:
            return (2, 2)
        }
    }

    // MARK: - Stream Navigation (when controls hidden)

    private func handleStreamNavigation(_ direction: MoveCommandDirection) {
        guard !viewModel.showControls else { return }

        // Show focus border on any remote input
        showFocusBorderTemporarily()

        // Multi-stream: d-pad navigates between streams
        if viewModel.streamCount > 1 {
            // Handle focus layout mode differently - main stream on left, side streams stacked on right
            if case .focus(let mainId) = viewModel.layoutMode {
                handleFocusLayoutNavigation(direction, mainId: mainId)
            } else {
                handleGridLayoutNavigation(direction)
            }
        } else {
            // Single stream: any d-pad press shows controls
            showControlsWithFocus()
        }
    }

    private func handleGridLayoutNavigation(_ direction: MoveCommandDirection) {
        let layout = gridLayout(for: viewModel.streamCount)
        let currentIndex = viewModel.focusedSlotIndex
        let row = currentIndex / layout.columns
        let col = currentIndex % layout.columns

        var newIndex = currentIndex

        switch direction {
        case .left:
            if col > 0 {
                newIndex = currentIndex - 1
            }
        case .right:
            if col < layout.columns - 1 && currentIndex + 1 < viewModel.streamCount {
                newIndex = currentIndex + 1
            }
        case .up:
            if row > 0 {
                let upIndex = currentIndex - layout.columns
                if upIndex >= 0 {
                    newIndex = upIndex
                }
            }
        case .down:
            if row < layout.rows - 1 {
                let downIndex = currentIndex + layout.columns
                if downIndex < viewModel.streamCount {
                    newIndex = downIndex
                }
            }
        @unknown default:
            break
        }

        if newIndex != currentIndex {
            viewModel.setFocus(to: newIndex)
        }
    }

    private func handleFocusLayoutNavigation(_ direction: MoveCommandDirection, mainId: UUID) {
        let currentIndex = viewModel.focusedSlotIndex
        guard let currentSlot = viewModel.focusedStream else { return }

        let isOnMain = currentSlot.id == mainId
        let sideStreams = viewModel.streams.filter { $0.id != mainId }

        // Find current position in side streams if not on main
        let sideIndex = sideStreams.firstIndex(where: { $0.id == currentSlot.id })

        var newIndex: Int? = nil

        switch direction {
        case .left:
            if !isOnMain {
                // On side stream, go to main (which is on the left)
                if let mainIndex = viewModel.streams.firstIndex(where: { $0.id == mainId }) {
                    newIndex = mainIndex
                }
            }
        case .right:
            if isOnMain && !sideStreams.isEmpty {
                // On main, go to first side stream (which is on the right)
                if let firstSide = sideStreams.first,
                   let idx = viewModel.streams.firstIndex(where: { $0.id == firstSide.id }) {
                    newIndex = idx
                }
            }
        case .up:
            if !isOnMain, let sideIdx = sideIndex, sideIdx > 0 {
                // On side stream, go up to previous side stream
                let prevSide = sideStreams[sideIdx - 1]
                if let idx = viewModel.streams.firstIndex(where: { $0.id == prevSide.id }) {
                    newIndex = idx
                }
            }
        case .down:
            if !isOnMain, let sideIdx = sideIndex, sideIdx < sideStreams.count - 1 {
                // On side stream, go down to next side stream
                let nextSide = sideStreams[sideIdx + 1]
                if let idx = viewModel.streams.firstIndex(where: { $0.id == nextSide.id }) {
                    newIndex = idx
                }
            }
        @unknown default:
            break
        }

        if let newIndex, newIndex != currentIndex {
            viewModel.setFocus(to: newIndex)
        }
    }

    private func showControlsWithFocus() {
        // Show focus border on any remote input
        showFocusBorderTemporarily()

        // In classic mode, Select does nothing - just watch TV
        guard !classicTVMode else { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.showControlsTemporarily()
        }
    }

    private func showChannelBadgesTemporarily() {
        // Cancel existing timer
        channelBadgeTimer?.invalidate()

        // Show badges
        withAnimation(.easeInOut(duration: 0.25)) {
            showChannelBadges = true
        }

        // Hide after 5 seconds (only if controls are not showing)
        channelBadgeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            DispatchQueue.main.async {
                if !viewModel.showControls {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showChannelBadges = false
                    }
                }
            }
        }
    }

    private func showFocusBorderTemporarily() {
        // Cancel existing timer
        focusBorderTimer?.invalidate()

        // Show border
        withAnimation(.easeInOut(duration: 0.25)) {
            showFocusBorder = true
        }

        // Hide after 5 seconds (only if controls are not showing)
        focusBorderTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            DispatchQueue.main.async {
                if !viewModel.showControls && !viewModel.showChannelPicker && !showExitConfirmation {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showFocusBorder = false
                    }
                }
            }
        }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        ZStack {
            // Gradient backgrounds
            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.8), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)

                Spacer()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
            }
            .ignoresSafeArea()

            VStack {
                // Top bar - focused channel info
                topBar
                    .padding(.horizontal, 60)
                    .padding(.top, 50)

                Spacer()

                // Bottom controls
                bottomControls
                    .padding(.bottom, 60)
            }
        }
        .onExitCommand {
            // Menu/Back pressed while controls visible - hide controls
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.showControls = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusArea = .streamGrid
            }
        }
    }

    private var exitConfirmationOverlay: some View {
        let cancelFocused = focusArea == .exitConfirmButton(0)
        let exitFocused = focusArea == .exitConfirmButton(1)

        return ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Confirmation dialog
            VStack(spacing: 24) {
                Text("Exit Multiview?")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)

                Text("You have \(viewModel.streamCount) streams open.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 24) {
                    // Cancel button
                    Button {
                        showExitConfirmation = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            focusArea = .streamGrid
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 160)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(cancelFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(
                                                cancelFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusArea, equals: .exitConfirmButton(0))
                    .scaleEffect(cancelFocused ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: cancelFocused)

                    // Exit button - destructive
                    Button {
                        forceExitPlayer()
                    } label: {
                        Text("Exit")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 160)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(exitFocused ? .red.opacity(0.25) : .white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(
                                                exitFocused ? .red.opacity(0.4) : .white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusArea, equals: .exitConfirmButton(1))
                    .scaleEffect(exitFocused ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: exitFocused)
                }
                .padding(.top, 16)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
        .onExitCommand {
            // Menu/Back on confirmation = cancel
            showExitConfirmation = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusArea = .streamGrid
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if let focusedStream = viewModel.focusedStream {
                // Channel logo
                if let logoURL = focusedStream.channel.logoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 60)
                        default:
                            channelIcon
                        }
                    }
                } else {
                    channelIcon
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        if let number = focusedStream.channel.channelNumber {
                            Text("\(number)")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Text(focusedStream.channel.name)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)

                        if focusedStream.channel.isHD {
                            Text("HD")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.white)
                                )
                        }

                        // Live indicator
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                            Text("LIVE")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    }

                    if let program = focusedStream.currentProgram {
                        Text(program.title)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.8))

                        Text(programTimeString(program))
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                // Stream count indicator (only show when multiple streams)
                if viewModel.streamCount > 1 {
                    streamCountBadge
                }
            }
        }
    }

    private var channelIcon: some View {
        Image(systemName: "tv")
            .font(.system(size: 32))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 80, height: 60)
    }

    private var streamCountBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))

            Text("\(viewModel.streamCount)/4")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.15))
        )
    }

    private var bottomControls: some View {
        HStack(spacing: 32) {
            let buttons = buildControlButtons()

            ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                PlayerControlButton(
                    icon: button.icon,
                    label: button.label,
                    isLarge: button.isLarge,
                    isFocused: focusArea == .controlButton(index),
                    action: button.action
                )
                .focused($focusArea, equals: .controlButton(index))
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
    }

    private struct ControlButtonConfig {
        let icon: String
        let label: String
        var isLarge: Bool = false
        let action: () -> Void
    }

    private func buildControlButtons() -> [ControlButtonConfig] {
        var buttons: [ControlButtonConfig] = []

        // Layout controls (only when multiple streams)
        if viewModel.streamCount > 1 {
            if viewModel.isFocusedStreamInSidebar {
                // Focused stream is in sidebar - offer to expand it to main
                buttons.append(ControlButtonConfig(
                    icon: "arrow.up.left.and.arrow.down.right",
                    label: "Expand",
                    action: {
                        viewModel.expandFocusedStream()
                    }
                ))
            } else if viewModel.isFocusLayout {
                // Focused stream is the main one - offer to reset to grid
                buttons.append(ControlButtonConfig(
                    icon: "rectangle.split.2x2",
                    label: "Grid View",
                    action: {
                        viewModel.resetLayout()
                    }
                ))
            } else {
                // Grid layout - offer to expand focused stream
                buttons.append(ControlButtonConfig(
                    icon: "arrow.up.left.and.arrow.down.right",
                    label: "Expand",
                    action: {
                        if let slotId = viewModel.focusedStream?.id {
                            viewModel.setFocusedLayout(on: slotId)
                        }
                    }
                ))
            }
        }

        // Add Stream button (2nd position)
        if viewModel.canAddStream {
            buttons.append(ControlButtonConfig(
                icon: "plus.circle.fill",
                label: "Add Stream",
                action: {
                    viewModel.replaceSlotIndex = nil  // Adding, not replacing
                    viewModel.showChannelPicker = true
                }
            ))
        }

        // Replace button (replace focused stream with new channel)
        buttons.append(ControlButtonConfig(
            icon: "arrow.triangle.2.circlepath",
            label: "Replace",
            action: {
                viewModel.replaceSlotIndex = viewModel.focusedSlotIndex
                viewModel.showChannelPicker = true
            }
        ))

        // Remove stream button (only when multiple streams)
        if viewModel.streamCount > 1 {
            buttons.append(ControlButtonConfig(
                icon: "minus.circle.fill",
                label: "Remove",
                action: {
                    viewModel.removeStream(at: viewModel.focusedSlotIndex)
                    // If only 1 stream left, hide controls
                    if viewModel.streamCount <= 1 {
                        viewModel.showControls = false
                    }
                }
            ))
        }

        // Exit button (always last on right)
        buttons.append(ControlButtonConfig(
            icon: "xmark.circle.fill",
            label: "Exit",
            action: { dismissPlayer() }
        ))

        return buttons
    }

    // MARK: - Helpers

    private func programTimeString(_ program: UnifiedProgram) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        let start = formatter.string(from: program.startTime)
        let end = formatter.string(from: program.endTime)
        return "\(start) - \(end)"
    }

    private func handleExitCommand() {
        // Show focus border on any remote input
        showFocusBorderTemporarily()

        if viewModel.isScrubbing {
            viewModel.cancelScrubFocused()
            return
        }

        if showExitConfirmation {
            // Cancel the confirmation and return to streams
            showExitConfirmation = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusArea = .streamGrid
            }
        } else if viewModel.showChannelPicker {
            viewModel.showChannelPicker = false
        } else if viewModel.showControls && !classicTVMode {
            // Hide controls and return focus to stream grid (not in classic mode)
            // UNLESS we can enter PIP mode - then go directly to PIP
            if viewModel.streamCount == 1, let onEnterPIP {
                // Single stream with PIP available - go to PIP, hide controls
                viewModel.showControls = false
                onEnterPIP()
            } else {
                // Multi-stream or no PIP - just hide controls
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.showControls = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusArea = .streamGrid
                }
            }
        } else {
            // Controls hidden
            // For single stream, try to enter PIP mode if callback is provided
            if viewModel.streamCount == 1, let onEnterPIP {
                onEnterPIP()
            } else {
                // Multi-stream or no PIP callback - exit directly
                dismissPlayer()
            }
        }
    }

    private func dismissPlayer() {
        // Check if we should show confirmation for multiview
        if confirmExitMultiview && viewModel.streamCount > 1 {
            showExitConfirmation = true
        } else {
            forceExitPlayer()
        }
    }

    private func forceExitPlayer() {
        if !hasStoppedStreams {
            hasStoppedStreams = true
            viewModel.stopAllStreams()
        }
        // Dismiss UI after cleanup request is issued
        onDismiss()
    }
}

// MARK: - Player Control Button

private struct PlayerControlButton: View {
    let icon: String
    let label: String
    var isLarge: Bool = false
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isFocused ? .white.opacity(0.4) : .white.opacity(0.2))
                        .frame(width: isLarge ? 80 : 64, height: isLarge ? 80 : 64)

                    Image(systemName: icon)
                        .font(.system(size: isLarge ? 36 : 28))
                        .foregroundStyle(.white)
                }

                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
            }
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(PlayerButtonStyle())
    }
}

// MARK: - Player Button Style

private struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    LiveTVPlayerView(
        channel: UnifiedChannel(
            id: "test",
            sourceType: .dispatcharr,
            sourceId: "test-source",
            channelNumber: 101,
            name: "Test Channel HD",
            callSign: "TEST",
            logoURL: nil,
            streamURL: URL(string: "http://example.com/stream.m3u8")!,
            tvgId: nil,
            groupTitle: "Entertainment",
            isHD: true
        ),
        onDismiss: {}
    )
}
