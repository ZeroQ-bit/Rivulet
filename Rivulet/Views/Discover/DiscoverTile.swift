//
//  DiscoverTile.swift
//  Rivulet
//
//  Single tile in a Discover row showing a TMDB item. Status overlay reflects
//  whether the item is in the user's library and/or on their Plex Watchlist.
//

import SwiftUI

struct DiscoverTile: View {
    let item: TMDBListItem
    let isInLibrary: Bool
    let isOnWatchlist: Bool
    let onTap: () -> Void

    private static let imageBase = "https://image.tmdb.org/t/p/w500"

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    posterImage
                    statusBadge
                        .padding(8)
                        .opacity(focused ? 1 : 0.85)
                }
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .scaleEffect(focused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
    }

    private var posterImage: some View {
        Group {
            if let path = item.posterPath, let url = URL(string: "\(Self.imageBase)\(path)") {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(2/3, contentMode: .fit)
                    case .empty: placeholder
                    case .failure: placeholder
                    @unknown default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 200, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? .white.opacity(0.3) : .white.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: item.mediaType == .movie ? "film" : "tv")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isInLibrary {
            badge(symbol: "play.circle.fill", color: .green)
        } else if isOnWatchlist {
            badge(symbol: "bookmark.fill", color: .white)
        }
    }

    private func badge(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(color)
            .padding(6)
            .background(Circle().fill(.black.opacity(0.55)))
    }
}
