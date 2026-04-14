//
//  WatchlistHubRow.swift
//  Rivulet
//
//  Renders the user's Plex Watchlist as a horizontal row on Home.
//  Items in library route to PlexDetailView; items not in library route to
//  TMDBItemDetailView.
//

import SwiftUI

struct WatchlistHubRow: View {
    @ObservedObject var watchlist: PlexWatchlistService

    let onSelectPlex: (PlexMetadata) -> Void
    let onSelectTMDB: (TMDBListItem) -> Void

    @FocusState private var focusedItemId: String?

    var body: some View {
        if watchlist.watchlistItems.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Watchlist")
                    .font(.system(size: 28, weight: .semibold))
                    .padding(.horizontal, 60)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(watchlist.watchlistItems.prefix(20)) { item in
                            tile(for: item)
                                .focused($focusedItemId, equals: item.id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 12)
                }
            }
            .focusSection()
            .remembersFocus(key: "watchlistHubRow", focusedId: $focusedItemId)
        }
    }

    @ViewBuilder
    private func tile(for item: PlexWatchlistItem) -> some View {
        Button {
            Task { await select(item) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                poster(for: item)
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func poster(for item: PlexWatchlistItem) -> some View {
        Group {
            if let url = item.posterURL {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(2/3, contentMode: .fit)
                    } else {
                        placeholder(for: item)
                    }
                }
            } else {
                placeholder(for: item)
            }
        }
        .frame(width: 200, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func placeholder(for item: PlexWatchlistItem) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: item.type == .movie ? "film" : "tv")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func select(_ item: PlexWatchlistItem) async {
        if let tmdbId = item.tmdbId {
            let mediaType: TMDBMediaType = item.type == .movie ? .movie : .tv
            if let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType) {
                onSelectPlex(match)
                return
            }
            // Not in library — build a TMDBListItem stub for the detail view
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
