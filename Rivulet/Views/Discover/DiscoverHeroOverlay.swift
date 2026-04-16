//
//  DiscoverHeroOverlay.swift
//  Rivulet
//
//  Discover-page hero overlay. Layout mirrors HeroOverlayContent (title/meta/
//  tagline + button row + paging dots pinned to bottom), but items are
//  TMDBListItem and the primary action becomes Add/Remove Watchlist (or Play
//  when the item is already in the user's library).
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
    let items: [TMDBListItem]
    @Binding var currentIndex: Int
    let inLibraryTMDBIds: Set<Int>
    let libraryMatch: (TMDBListItem) async -> PlexMetadata?

    /// Callback when the user activates the primary button for an item that
    /// matches their library. Parent presents `PlexDetailView` for the match.
    let onPresentPlex: (PlexMetadata) -> Void
    let onInfo: (TMDBListItem) -> Void
    var onHeroFocused: (() -> Void)? = nil

    @ObservedObject private var watchlistService = PlexWatchlistService.shared
    @FocusState private var focusedButton: DiscoverHeroButton?
    @State private var displayedIndex: Int = 0

    private static let slideSwapDelay: Duration = .milliseconds(100)
    private let pillButtonHeight: CGFloat = 66
    private let circleButtonSize: CGFloat = 66

    private var displayedItem: TMDBListItem? {
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
                            .id("\(item.id)")
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
    private func buttonRow(for item: TMDBListItem) -> some View {
        HStack(spacing: 16) {
            primaryButton(for: item)
            infoButton(for: item)
            if canAdvance {
                nextButton
            }
        }
    }

    /// When the item is in library: "Details" pill (opens PlexDetailView).
    /// Otherwise: "Add/Remove from Watchlist".
    @ViewBuilder
    private func primaryButton(for item: TMDBListItem) -> some View {
        if inLibraryTMDBIds.contains(item.id) {
            Button(action: { Task { await presentDetailsIfMatched(item) } }) {
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
        } else {
            let onList = watchlistService.contains(tmdbId: item.id)
            Button(action: { Task { await toggleWatchlist(item) } }) {
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

    private func infoButton(for item: TMDBListItem) -> some View {
        Button(action: { onInfo(item) }) {
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

    private func toggleWatchlist(_ item: TMDBListItem) async {
        let guid = "tmdb://\(item.id)"
        if watchlistService.contains(guid: guid) {
            discoverHeroLog.info("Watchlist remove \(guid, privacy: .public)")
            await watchlistService.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = item.mediaType == .movie ? .movie : .show
            let yearInt: Int? = {
                guard let raw = item.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
                return Int(raw)
            }()
            let posterURL: URL? = item.posterPath.flatMap {
                URL(string: "https://image.tmdb.org/t/p/w500\($0)")
            }
            let wli = PlexWatchlistItem(
                id: guid,
                title: item.title,
                year: yearInt,
                type: watchType,
                posterURL: posterURL,
                guids: [guid]
            )
            discoverHeroLog.info("Watchlist add \(guid, privacy: .public)")
            await watchlistService.add(guid: guid, item: wli)
        }
    }

    private func presentDetailsIfMatched(_ item: TMDBListItem) async {
        if let match = await libraryMatch(item) {
            onPresentPlex(match)
        }
    }
}

// MARK: - Per-slide content

private struct DiscoverHeroSlide: View {
    let item: TMDBListItem

    private var meta: String {
        var parts: [String] = []
        parts.append(item.mediaType == .movie ? "Movie" : "TV Show")
        if let yearText = item.releaseDate?.prefix(4), !yearText.isEmpty {
            parts.append(String(yearText))
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
