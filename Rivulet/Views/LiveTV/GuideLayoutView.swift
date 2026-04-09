//
//  GuideLayoutView.swift
//  Rivulet
//

import SwiftUI


/// Display mode for Live TV player in guide view
enum LiveTVDisplayMode: Equatable {
    case hidden      // No player visible
    case fullscreen  // Player is fullscreen overlay
    case pip         // Player is in PIP (small, top-right)
}

struct GuideLayoutView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @StateObject private var dataStore = LiveTVDataStore.shared

    /// Channels filtered by source (if specified)
    private var channels: [UnifiedChannel] {
        if let sourceId = sourceIdFilter {
            return dataStore.channels.filter { $0.sourceId == sourceId }
        }
        return dataStore.channels
    }

    // PIP state management
    @State private var activeChannel: UnifiedChannel?
    @State private var playerSessionId = UUID()
    @State private var displayMode: LiveTVDisplayMode = .hidden
    @State private var debugId = String(UUID().uuidString.prefix(8))

    @State private var guideStartTime = Date()
    @State private var focusedRow = 0
    @State private var focusedColumn = 0
    @State private var timeOffset = 0  // In 30-min increments for scrolling ahead
    @FocusState private var hasFocus: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background
                Rectangle().fill(.background).ignoresSafeArea()

                // Guide content - always rendered but visually hidden when fullscreen
                if channels.isEmpty {
                    ProgressView()
                } else {
                    guideView(size: geo.size)
                        .opacity(displayMode == .fullscreen ? 0 : 1)
                        .disabled(displayMode == .fullscreen)
                }

                // Player layer - present when activeChannel exists
                if let channel = activeChannel {
                    liveTVPlayerLayer(channel: channel, screenSize: geo.size)
                        .zIndex(displayMode == .fullscreen ? 100 : 10)
                }
            }
        }
        .onAppear {
            setupStartTime()
        }
        .task {
            if dataStore.channels.isEmpty { await dataStore.loadChannels() }
            if dataStore.epg.isEmpty { await dataStore.loadEPG(startDate: Date(), hours: 6) }
        }
        // Animation disabled for instant PIP transitions
        .onChange(of: displayMode) { oldMode, newMode in
            if oldMode == .fullscreen && newMode == .pip {
                // Transitioning to PIP - focus guide immediately (no animation delay)
                DispatchQueue.main.async {
                    hasFocus = true
                }
            } else if oldMode == .pip && newMode == .fullscreen {
                // Returning to fullscreen - clear guide focus
                hasFocus = false
            } else if newMode == .hidden {
                // Player dismissed - focus guide
                hasFocus = true
            }
        }
    }

    // MARK: - PIP Player Layer

    /// PIP sizing constants
    private var pipScale: CGFloat { 0.28 }
    private var pipMargin: CGFloat { 60 }

    @ViewBuilder
    private func liveTVPlayerLayer(channel: UnifiedChannel, screenSize: CGSize) -> some View {
        let isPIP = displayMode == .pip
        // Keep PiP at exact 16:9 with integral 16px width steps to avoid
        // fractional scaling artifacts (can appear as a bottom strip).
        let rawPipWidth = screenSize.width * pipScale
        let pipWidth = max(16, floor(rawPipWidth / 16.0) * 16.0)
        let pipHeight = pipWidth * 9.0 / 16.0
        let pipSize = CGSize(width: pipWidth, height: pipHeight)
        let targetSize = isPIP ? pipSize : screenSize
        let targetCenter = CGPoint(
            x: isPIP ? (screenSize.width - pipMargin - targetSize.width / 2) : (screenSize.width / 2),
            y: isPIP ? (pipMargin + targetSize.height / 2) : (screenSize.height / 2)
        )

        LiveTVPlayerView(
            channel: channel,
            onDismiss: {
                displayMode = .hidden
                activeChannel = nil
                playerSessionId = UUID()
                hasFocus = false
                DispatchQueue.main.async {
                    hasFocus = true
                }
            },
            onEnterPIP: {
                // Instant transition to PIP - no animation
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    displayMode = .pip
                }
            },
            isInteractive: displayMode == .fullscreen  // Disable focus capture in PIP mode
        )
        // Force a fresh player session when changing channels or after exit/reopen.
        .id("\(playerSessionId.uuidString)-\(channel.id)")
        .frame(width: targetSize.width, height: targetSize.height)
        // Keep player frame changes immediate to avoid transient scale/zoom artifacts.
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(nil, value: displayMode)
        .clipShape(RoundedRectangle(cornerRadius: isPIP ? 14 : 0, style: .continuous))
        .shadow(color: isPIP ? .black.opacity(0.5) : .clear, radius: 20, x: 0, y: 10)
        .position(x: targetCenter.x, y: targetCenter.y)
        .allowsHitTesting(displayMode == .fullscreen)
    }

    private func setupStartTime() {
        let now = Date()
        let cal = Calendar.current
        let min = cal.component(.minute, from: now)
        guideStartTime = cal.date(bySettingHour: cal.component(.hour, from: now),
                                   minute: (min / 30) * 30, second: 0, of: now) ?? now
    }

    // MARK: - Main Guide View

    private func guideView(size: CGSize) -> some View {
        let channelWidth: CGFloat = 280
        let rowHeight: CGFloat = 110
        let headerHeight: CGFloat = 52
        let gridWidth = size.width - channelWidth
        let pxPerMin = gridWidth / 180  // Show 3 hours
        let visibleStart = guideStartTime.addingTimeInterval(Double(timeOffset * 30 * 60))
        let visibleEnd = visibleStart.addingTimeInterval(180 * 60)

        return Button {
            selectFocusedChannel(trigger: "button")
        } label: {
            VStack(spacing: 0) {
                // EPG failure banner — surfaced so an empty guide doesn't look
                // like a Rivulet bug when the real cause is a broken third-party
                // EPG URL (404/DNS/timeout/etc).
                if !dataStore.epgIssues.isEmpty {
                    EPGIssueBanner(issues: dataStore.epgIssues)
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                }

                // Header row with time slots
                HStack(spacing: 0) {
                    Color(white: 0.08)
                        .frame(width: channelWidth, height: headerHeight)
                    TimeHeaderView(startTime: visibleStart, width: gridWidth,
                                  height: headerHeight, pxPerMin: pxPerMin)
                }

                // Divider between header and channel list
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)

                // Scrollable channel list
                ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            ZStack(alignment: .topLeading) {
                                // Use LazyVStack to avoid rendering all channels at once
                                // This prevents memory pressure and focus system overload on older devices
                                LazyVStack(spacing: 0, pinnedViews: []) {
                                    ForEach(Array(channels.enumerated()), id: \.element.id) { idx, ch in
                                        HStack(spacing: 0) {
                                            ChannelCell(channel: ch, isSelected: idx == focusedRow,
                                                       width: channelWidth, height: rowHeight)
                                            ProgramRowView(
                                                programs: dataStore.getPrograms(for: ch, startDate: visibleStart, endDate: visibleEnd),
                                                startTime: visibleStart,
                                                width: gridWidth,
                                                height: rowHeight,
                                                pxPerMin: pxPerMin,
                                                isRowFocused: idx == focusedRow,
                                                focusedCol: idx == focusedRow ? focusedColumn : nil
                                            )
                                        }
                                        .id(idx)
                                    }
                                }

                                // Time line overlay (inside scroll content)
                                TimeLineView(now: Date(), startTime: visibleStart, endTime: visibleEnd,
                                            headerHeight: 0, pxPerMin: pxPerMin,
                                            totalHeight: CGFloat(channels.count) * rowHeight)
                                    .offset(x: channelWidth)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: focusedRow) { _, row in
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(row, anchor: .center)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
            }
        }
        .buttonStyle(GuideButtonStyle())
        // Fallback for cases where tvOS focus remains visible but primary Button action
        // is not delivered after overlay dismissal.
        .simultaneousGesture(TapGesture().onEnded {
            selectFocusedChannel(trigger: "tap_fallback")
        })
        .focused($hasFocus)
        .focusSection()  // Prevent focus from escaping to sidebar trigger
        .focusable(displayMode != .fullscreen)  // Disable focus when player is fullscreen
        .onAppear { hasFocus = true }
        .onChange(of: channels.count) { _, count in
            if count > 0, focusedRow >= count {
                focusedRow = max(0, count - 1)
            } else {
            }
        }
        .onMoveCommand { dir in
            guard displayMode != .fullscreen else { return }  // Don't handle when player is fullscreen
            handleNav(dir)
        }
        .onExitCommand {
            guard displayMode != .fullscreen else { return }  // Don't handle when player is fullscreen
            hasFocus = false
        }
    }

    // MARK: - Channel Selection

    private func selectFocusedChannel(trigger: String) {
        if displayMode == .fullscreen {
            return
        }

        guard focusedRow < channels.count else {
            return
        }

        let channel = channels[focusedRow]
        selectChannel(channel)
    }

    private func selectChannel(_ channel: UnifiedChannel) {
        if displayMode == .pip {
            // Already playing - switch channel if different, then go fullscreen
            if activeChannel?.id != channel.id {
                playerSessionId = UUID()
                activeChannel = channel
            }
            // Instant transition to fullscreen - no animation
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                displayMode = .fullscreen
            }
        } else {
            // Start fresh - no animation needed
            playerSessionId = UUID()
            activeChannel = channel
            displayMode = .fullscreen
        }
    }

    private func handleNav(_ dir: MoveCommandDirection) {
        guard !channels.isEmpty else { return }

        switch dir {
        case .up:
            if focusedRow > 0 {
                focusedRow -= 1
                clampCol()
            } else if displayMode == .pip {
                // At top of guide and PIP is showing - return to fullscreen (no animation)
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    displayMode = .fullscreen
                }
            }
        case .down:
            if focusedRow < channels.count - 1 {
                focusedRow += 1
                clampCol()
            }
        case .left:
            if focusedColumn > 0 {
                focusedColumn -= 1
            } else if timeOffset > 0 {
                // Scroll back in time
                timeOffset -= 1
                focusedColumn = 0  // Start at first program when scrolling back
            }
        case .right:
            let visibleStart = guideStartTime.addingTimeInterval(Double(timeOffset * 30 * 60))
            let visibleEnd = visibleStart.addingTimeInterval(180 * 60)
            let count = progCountFor(start: visibleStart, end: visibleEnd)
            if focusedColumn < count - 1 {
                focusedColumn += 1
            } else if timeOffset < 18 {  // Allow 9 hours ahead (18 x 30min)
                // Scroll forward in time
                timeOffset += 1
                focusedColumn = 0
            }
        @unknown default: break
        }
    }

    private func clampCol() {
        let visibleStart = guideStartTime.addingTimeInterval(Double(timeOffset * 30 * 60))
        let visibleEnd = visibleStart.addingTimeInterval(180 * 60)
        focusedColumn = min(focusedColumn, max(0, progCountFor(start: visibleStart, end: visibleEnd) - 1))
    }

    private func progCountFor(start: Date, end: Date) -> Int {
        guard focusedRow >= 0 && focusedRow < channels.count else { return 1 }
        return max(1, dataStore.getPrograms(for: channels[focusedRow],
                                            startDate: start, endDate: end).count)
    }
}

// Custom button style with no focus chrome
private struct GuideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Subviews

private struct ChannelCell: View {
    let channel: UnifiedChannel
    let isSelected: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            // Channel logo - use CachedAsyncImage for better memory management
            Group {
                if let logoURL = channel.logoURL {
                    CachedAsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        default:
                            Image(systemName: "tv")
                                .font(.system(size: 36))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(width: 100, height: 70)

            // Channel info
            VStack(alignment: .leading, spacing: 4) {
                if let n = channel.channelNumber {
                    Text("\(n)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(channel.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .frame(width: width, height: height)
        .background(Color(white: isSelected ? 0.2 : 0.1))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

private struct TimeHeaderView: View {
    let startTime: Date
    let width: CGFloat
    let height: CGFloat
    let pxPerMin: CGFloat

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { i in  // 6 x 30min = 3hrs
                Text(Self.fmt.string(from: startTime.addingTimeInterval(Double(i * 30 * 60))))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: pxPerMin * 30, alignment: .leading)
                    .padding(.leading, 14)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color(white: 0.12))
    }
}

private struct ProgramRowView: View {
    let programs: [UnifiedProgram]
    let startTime: Date
    let width: CGFloat
    let height: CGFloat
    let pxPerMin: CGFloat
    let isRowFocused: Bool
    let focusedCol: Int?

    private let endTime: Date

    init(programs: [UnifiedProgram], startTime: Date, width: CGFloat, height: CGFloat,
         pxPerMin: CGFloat, isRowFocused: Bool, focusedCol: Int?) {
        self.programs = programs
        self.startTime = startTime
        self.width = width
        self.height = height
        self.pxPerMin = pxPerMin
        self.isRowFocused = isRowFocused
        self.focusedCol = focusedCol
        self.endTime = startTime.addingTimeInterval(180 * 60)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color(white: isRowFocused ? 0.08 : 0.05))

            if programs.isEmpty {
                ProgramCell(title: "No Data", time: nil, x: 2, cellWidth: width - 4,
                           height: height, isFocused: isRowFocused, isAiring: false)
            } else {
                ForEach(Array(programs.enumerated()), id: \.element.id) { idx, prog in
                    let (x, w) = position(prog)
                    let now = Date()
                    ProgramCell(
                        title: prog.title,
                        time: Self.fmt.string(from: prog.startTime),
                        x: x,
                        cellWidth: w,
                        height: height,
                        isFocused: isRowFocused && focusedCol == idx,
                        isAiring: prog.startTime <= now && prog.endTime > now
                    )
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func position(_ p: UnifiedProgram) -> (CGFloat, CGFloat) {
        let visStart = max(p.startTime, startTime)
        let visEnd = min(p.endTime, endTime)
        let x = CGFloat(visStart.timeIntervalSince(startTime) / 60) * pxPerMin
        let w = max(CGFloat(visEnd.timeIntervalSince(visStart) / 60) * pxPerMin, 60)
        return (x, w)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

private struct ProgramCell: View {
    let title: String
    let time: String?
    let x: CGFloat
    let cellWidth: CGFloat
    let height: CGFloat
    let isFocused: Bool
    let isAiring: Bool

    var body: some View {
        // Match the native tvOS highlight effect styling
        // Normal: 0.12, Airing: 0.18, Focused: 0.35 (distinct from airing)
        let bg: Color = {
            if isFocused {
                return Color(white: 0.35)
            } else if isAiring {
                return Color(white: 0.18)
            } else {
                return Color(white: 0.12)
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            if let t = time {
                Text(t)
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: cellWidth - 6, height: height - 14, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bg)
        )
        // Lift shadow when focused (mimics tvOS highlight)
        .shadow(color: isFocused ? .black.opacity(0.6) : .clear, radius: 12, x: 0, y: 6)
        .scaleEffect(isFocused ? 1.02 : 1.0, anchor: .leading)
        .zIndex(isFocused ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .offset(x: x + 3)
    }
}

private struct TimeLineView: View {
    let now: Date
    let startTime: Date
    let endTime: Date
    let headerHeight: CGFloat
    let pxPerMin: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        if now >= startTime && now <= endTime {
            let x = CGFloat(now.timeIntervalSince(startTime) / 60) * pxPerMin
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: totalHeight)
                .offset(x: x)
        }
    }
}

// MARK: - EPG Issue Banner

/// Passive banner shown above the guide when one or more EPG fetches failed.
/// Tells the user *which* source failed and *why* in a short phrase, so that
/// an empty guide reads as "your EPG server is down" rather than "Rivulet is
/// broken". Non-focusable by design — the fix belongs in Settings or on the
/// upstream server, not behind a button here.
private struct EPGIssueBanner: View {
    let issues: [LiveTVDataStore.EPGFetchIssue]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.9))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(issues.count == 1
                     ? "Guide data unavailable"
                     : "Guide data unavailable (\(issues.count) sources)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                ForEach(issues) { issue in
                    Text("\(issue.sourceName): \(issue.reason)")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

