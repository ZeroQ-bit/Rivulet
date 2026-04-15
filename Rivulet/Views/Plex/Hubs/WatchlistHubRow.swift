//
//  WatchlistHubRow.swift
//  Rivulet
//
//  Renders the user's Plex Watchlist as a horizontal row on Home. Mirrors the
//  visual style of MediaRow / MediaPosterCard so it blends with other hubs.
//

import SwiftUI

struct WatchlistHubRow: View {
    @ObservedObject var watchlist: PlexWatchlistService

    let onSelectPlex: (PlexMetadata) -> Void
    let onSelectTMDB: (TMDBListItem) -> Void

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    @FocusState private var focusedItemId: String?

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
                                Task { await select(item) }
                            } label: {
                                WatchlistTile(item: item)
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focusedItemId, equals: item.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .defaultFocus($focusedItemId, watchlist.watchlistItems.first?.id)
        }
    }

    private func select(_ item: PlexWatchlistItem) async {
        if let tmdbId = item.tmdbId {
            let mediaType: TMDBMediaType = item.type == .movie ? .movie : .tv
            if let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType) {
                onSelectPlex(match)
                return
            }
            let stub = TMDBListItem(
                id: tmdbId,
                title: item.title,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: item.year.map { "\($0)" },
                voteAverage: nil,
                mediaType: mediaType
            )
            onSelectTMDB(stub)
        }
        // If no tmdb id, no-op for v1 (would need IMDB/TVDB resolution)
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
