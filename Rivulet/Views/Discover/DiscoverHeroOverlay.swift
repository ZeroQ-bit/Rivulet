//
//  DiscoverHeroOverlay.swift
//  Rivulet
//
//  Discover-page hero overlay. Layout mirrors HeroOverlayContent (title/meta/
//  tagline + button row + paging dots pinned to bottom). Items are MediaItem;
//  the primary action becomes Add/Remove Watchlist (or Details when the item
//  is already in the user's library — which opens the unified carousel).
//

import SwiftUI
import os.log

private let discoverHeroLog = Logger(subsystem: "com.rivulet.app", category: "DiscoverHero")

enum DiscoverHeroButton: Hashable {
    case primary
    case info
    case next
}

struct DiscoverHeroOverlay: View {
    let items: [MediaItem]
    @Binding var currentIndex: Int

    /// Emits a PreviewRequest when the user activates the Info or "Details"
    /// button — opens the unified carousel rooted at the current hero item.
    let onSelect: (PreviewRequest) -> Void
    var onHeroFocused: (() -> Void)? = nil

    @ObservedObject private var watchlistService = PlexWatchlistService.shared
    @FocusState private var focusedButton: DiscoverHeroButton?
    @State private var displayedIndex: Int = 0

    private static let slideSwapDelay: Duration = .milliseconds(100)
    private let pillButtonHeight: CGFloat = 66
    private let circleButtonSize: CGFloat = 66

    private static let rowID = "discoverHero"

    private var displayedItem: MediaItem? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(displayedIndex, items.count - 1))
        return items[clamped]
    }

    private var canAdvance: Bool { items.count > 1 }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                if let item = displayedItem {
                    VStack(alignment: .leading, spacing: 28) {
                        DiscoverHeroSlide(item: item)
                            .id(item.id)
                            .transition(.opacity)

                        buttonRow(for: item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 120)
                }

                Spacer().frame(height: 120)
            }

            if canAdvance {
                pagingDots
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 24)
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            Task { @MainActor in
                try? await Task.sleep(for: Self.slideSwapDelay)
                withAnimation(.easeInOut(duration: 0.25)) {
                    displayedIndex = newIndex
                }
            }
        }
        .onChange(of: focusedButton) { _, new in
            if new != nil { onHeroFocused?() }
        }
    }

    // MARK: - Button row

    @ViewBuilder
    private func buttonRow(for item: MediaItem) -> some View {
        HStack(spacing: 16) {
            primaryButton(for: item)
            infoButton(for: item)
            if canAdvance {
                nextButton
            }
        }
    }

    /// In-library items: "Details" pill (opens the unified carousel rooted at
    /// the hero item). Otherwise: "Add/Remove from Watchlist".
    @ViewBuilder
    private func primaryButton(for item: MediaItem) -> some View {
        if item.plexMatch != nil {
            Button(action: { emitPreview(for: item) }) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                    Text("Details")
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 32)
                .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedButton == .primary,
                cornerRadius: pillButtonHeight / 2
            ))
            .focused($focusedButton, equals: .primary)
        } else if let tmdbId = item.tmdbId {
            let onList = watchlistService.contains(tmdbId: tmdbId)
            Button(action: { Task { await toggleWatchlist(item: item, tmdbId: tmdbId) } }) {
                HStack(spacing: 10) {
                    Image(systemName: onList ? "bookmark.fill" : "bookmark")
                    Text(onList ? "Remove from Watchlist" : "Add to Watchlist")
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 32)
                .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedButton == .primary,
                cornerRadius: pillButtonHeight / 2
            ))
            .focused($focusedButton, equals: .primary)
        }
    }

    private func infoButton(for item: MediaItem) -> some View {
        Button(action: { emitPreview(for: item) }) {
            Image(systemName: "info.circle")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(AppStoreActionButtonStyle(
            isFocused: focusedButton == .info,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .info)
        .accessibilityLabel("More info")
    }

    private var nextButton: some View {
        Button(action: advance) {
            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: circleButtonSize, height: circleButtonSize)
        }
        .buttonStyle(AppStoreActionButtonStyle(
            isFocused: focusedButton == .next,
            cornerRadius: circleButtonSize / 2,
            isPrimary: false
        ))
        .focused($focusedButton, equals: .next)
        .accessibilityLabel("Next featured item")
    }

    // MARK: - Paging dots

    private var pagingDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<items.count, id: \.self) { i in
                Circle()
                    .fill(i == displayedIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        guard !items.isEmpty else { return }
        let next = (currentIndex + 1) % items.count
        currentIndex = next
    }

    private func emitPreview(for item: MediaItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        onSelect(PreviewRequest(
            items: items,
            selectedIndex: idx,
            sourceRowID: Self.rowID,
            sourceItemID: item.id
        ))
    }

    private func toggleWatchlist(item: MediaItem, tmdbId: Int) async {
        let guid = "tmdb://\(tmdbId)"
        if watchlistService.contains(guid: guid) {
            discoverHeroLog.info("Watchlist remove \(guid, privacy: .public)")
            await watchlistService.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = item.kind == .movie ? .movie : .show
            let wli = PlexWatchlistItem(
                id: guid,
                title: item.title,
                year: item.year,
                type: watchType,
                posterURL: item.posterURL,
                guids: [guid]
            )
            discoverHeroLog.info("Watchlist add \(guid, privacy: .public)")
            await watchlistService.add(guid: guid, item: wli)
        }
    }
}

// MARK: - Per-slide content

private struct DiscoverHeroSlide: View {
    let item: MediaItem

    private var meta: String {
        var parts: [String] = []
        parts.append(item.kind == .movie ? "Movie" : "TV Show")
        if let year = item.year {
            parts.append("\(year)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
                .lineLimit(2)
                .frame(maxWidth: 720, alignment: .leading)

            Text(meta)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }
}
