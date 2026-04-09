//
//  HeroOverlayContent.swift
//  Rivulet
//
//  The focusable foreground of the hero — logo/metadata/tagline + button row
//  + paging dots — with a transparent background so the layer behind shows
//  through. Used by the home screen inside a ScrollView so it sits at the
//  same level as the Continue Watching row (and scrolls together with it).
//

import SwiftUI
import os.log

private let overlayLog = Logger(subsystem: "com.rivulet.app", category: "HeroOverlay")

struct HeroOverlayContent: View {
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    @Binding var currentIndex: Int
    let onInfo: (PlexMetadata) -> Void
    let onPlay: (PlexMetadata) -> Void

    @State private var resolvedPlayTargets: [String: PlexMetadata] = [:]
    @State private var watchedOverrides: [String: Bool] = [:]
    @State private var isResolvingPlay: Bool = false
    /// Lags behind `currentIndex` by `slideSwapDelay` so the backdrop has
    /// time to crossfade before the logo/metadata/buttons swap in.
    @State private var displayedIndex: Int = 0
    @FocusState private var focusedButton: HeroButton?

    /// How long to wait after `currentIndex` changes before swapping the
    /// visible slide content. Keeps the metadata from popping in ahead of
    /// the backdrop art (matches the detail view's brief hold).
    private static let slideSwapDelay: Duration = .milliseconds(100)

    private var currentItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(currentIndex, items.count - 1))
        return items[clamped]
    }

    private var displayedItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(displayedIndex, items.count - 1))
        return items[clamped]
    }

    private var canAdvance: Bool { items.count > 1 }

    private func isWatched(_ item: PlexMetadata) -> Bool {
        if let key = item.ratingKey, let override = watchedOverrides[key] {
            return override
        }
        return item.isWatched
    }

    /// Must match the hero-section height computed in `PlexHomeView.contentView`
    /// and `PlexLibraryView.contentView` (`UIScreen.main.bounds.height - 180`).
    /// Set here explicitly so the layout doesn't depend on SwiftUI propagating
    /// the parent's `.frame(height:)` through the ZStack — which wasn't
    /// reaching the VStack reliably and caused the controls to overflow below
    /// the clipped hero bounds.
    private static let heroHeight: CGFloat = UIScreen.main.bounds.height - 180

    var body: some View {
        VStack(spacing: 0) {
            // Push everything to the bottom of the hero.
            Spacer(minLength: 0)

            if let item = displayedItem {
                VStack(alignment: .leading, spacing: 28) {
                    HeroSlideContent(
                        item: item,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                    .id(item.ratingKey ?? "idx-\(displayedIndex)")
                    .transition(.opacity)

                    HeroButtonRow(
                        isResolvingPlay: isResolvingPlay,
                        isWatched: isWatched(item),
                        canAdvance: canAdvance,
                        focusedButton: $focusedButton,
                        onPlay: { handlePlay(item) },
                        onToggleWatched: { handleToggleWatched(item) },
                        onInfo: { onInfo(item) },
                        onNext: { advance() }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 120)
            }

            // Gap between buttons and paging dots.
            if canAdvance {
                Spacer().frame(height: 44)

                pagingDots
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Bottom inset — distance from the very bottom of the hero.
            Spacer().frame(height: 80)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.heroHeight)
        .onAppear {
            // Sync the displayed slide with the active index on first load.
            if displayedIndex != currentIndex {
                displayedIndex = currentIndex
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            Task { @MainActor in
                try? await Task.sleep(for: Self.slideSwapDelay)
                withAnimation(.easeInOut(duration: 0.22)) {
                    displayedIndex = newIndex
                }
            }
        }
        .onChange(of: items.map(\.ratingKey)) { _, _ in
            if currentIndex >= items.count { currentIndex = 0 }
            if displayedIndex >= items.count { displayedIndex = 0 }
        }
    }

    // MARK: - Paging Dots

    private var pagingDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<items.count, id: \.self) { idx in
                Capsule()
                    .fill(Color.white.opacity(idx == displayedIndex ? 1.0 : 0.35))
                    .frame(width: idx == displayedIndex ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: displayedIndex)
            }
        }
    }

    // MARK: - Paging

    private func advance() {
        guard canAdvance else { return }
        // The backdrop reacts to `currentIndex` immediately; the visible
        // overlay follows ~100ms later via the onChange handler in `body`.
        currentIndex = (currentIndex + 1) % items.count
    }

    // MARK: - Play

    private func handlePlay(_ item: PlexMetadata) {
        guard !isResolvingPlay else { return }

        if let key = item.ratingKey, let cached = resolvedPlayTargets[key] {
            overlayLog.info("[HeroOverlay] Play (cached resolution) for \(key, privacy: .public)")
            onPlay(cached)
            return
        }

        // Fast path: movies and episodes need no resolution.
        if let type = item.type, type == "movie" || type == "episode" {
            onPlay(item)
            return
        }

        isResolvingPlay = true
        Task { @MainActor in
            let resolved = await HeroPlaySession.resolvePlaybackTarget(
                for: item,
                serverURL: serverURL,
                authToken: authToken
            )
            if let key = item.ratingKey {
                resolvedPlayTargets[key] = resolved
            }
            isResolvingPlay = false
            onPlay(resolved)
        }
    }

    // MARK: - Watched Toggle

    private func handleToggleWatched(_ item: PlexMetadata) {
        guard let key = item.ratingKey else { return }
        let nextState = !isWatched(item)
        watchedOverrides[key] = nextState

        Task { @MainActor in
            let network = PlexNetworkManager.shared
            do {
                if nextState {
                    try await network.markWatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: key
                    )
                } else {
                    try await network.markUnwatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: key
                    )
                }
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            } catch {
                overlayLog.error("[HeroOverlay] markWatched(\(nextState)) failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                watchedOverrides[key] = !nextState
            }
        }
    }
}
