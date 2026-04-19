//
//  WatchlistHubRow.swift
//  Rivulet
//
//  Renders the user's Plex Watchlist as a horizontal row on Home. Mirrors the
//  visual style of MediaRow / MediaPosterCard so it blends with other hubs.
//

import SwiftUI
import os.log

private let watchlistRowLog = Logger(subsystem: "com.rivulet.app", category: "WatchlistHubRow")

struct WatchlistHubRow: View {
    @ObservedObject var watchlist: PlexWatchlistService

    /// Emits a `PreviewRequest` rooted at the tapped tile so the unified
    /// carousel opens with the full watchlist as side cards. Callers route
    /// this into their `rowPreviewRequest` state.
    let onSelect: (PreviewRequest) -> Void
    var onRowFocused: (() -> Void)?

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    @FocusState private var focusedItemId: String?

    /// Stable per-tile identifier shared between the focus state, the source
    /// anchor for the preview transition, and the carousel's selected index
    /// lookup. Uses the tmdbId when present (matches the MediaItem.id format
    /// `tmdb:<id>`) so the carousel's selectedIndex resolution succeeds.
    private func itemMediaId(_ item: PlexWatchlistItem) -> String {
        if let tmdbId = item.tmdbId { return "tmdb:\(tmdbId)" }
        return "wl:\(item.id)"
    }

    var body: some View {
        if watchlist.watchlistItems.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Watchlist")
                    .font(.system(size: titleSize, weight: .bold))
                    .padding(.horizontal, horizontalPadding)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: itemSpacing) {
                        ForEach(watchlist.watchlistItems.prefix(20)) { item in
                            Button {
                                emitPreviewRequest(for: item)
                            } label: {
                                WatchlistTile(item: item)
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focusedItemId, equals: item.id)
                            .previewSourceAnchor(rowID: "watchlist", itemID: itemMediaId(item))
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .defaultFocus($focusedItemId, watchlist.watchlistItems.first?.id)
            .onChange(of: focusedItemId) { oldValue, newValue in
                // Mirror InfiniteContentRow: notify parent when this row first
                // takes focus so it can scroll itself to vertical center.
                if oldValue == nil && newValue != nil {
                    onRowFocused?()
                }
            }
        }
    }

    private func emitPreviewRequest(for item: PlexWatchlistItem) {
        let mediaItems = watchlist.mediaItems
        let targetID = itemMediaId(item)
        guard let idx = mediaItems.firstIndex(where: { $0.id == targetID }) else {
            // The mediaItems projection may briefly lag a fresh add — surface a
            // log so the cause is visible if a tap silently no-ops.
            watchlistRowLog.warning("[Select] no MediaItem match for \(targetID, privacy: .public)")
            return
        }
        onSelect(PreviewRequest(
            items: mediaItems,
            selectedIndex: idx,
            sourceRowID: "watchlist",
            sourceItemID: targetID
        ))
    }
}

private struct WatchlistTile: View {
    let item: PlexWatchlistItem

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        poster
            .frame(width: posterWidth, height: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = item.posterURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay { ProgressView().tint(.white.opacity(0.3)) }
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.12)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: item.type == .movie ? "film" : "tv")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }
}
