//
//  DiscoverTile.swift
//  Rivulet
//
//  Single tile in a Discover row showing a TMDB item. Visually matches
//  MediaPosterCard so Discover blends with library/home rows.
//

import SwiftUI

struct DiscoverTile: View, Equatable {
    let item: TMDBListItem
    let isInLibrary: Bool
    let isOnWatchlist: Bool

    @Environment(\.uiScale) private var scale

    static func == (lhs: DiscoverTile, rhs: DiscoverTile) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isInLibrary == rhs.isInLibrary &&
        lhs.isOnWatchlist == rhs.isOnWatchlist
    }

    private static let imageBase = "https://image.tmdb.org/t/p/w500"

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        posterImage
            .frame(width: posterWidth, height: posterHeight)
            .overlay(alignment: .topTrailing) { statusBadge }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let path = item.posterPath, let url = URL(string: "\(Self.imageBase)\(path)") {
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
                Image(systemName: item.mediaType == .movie ? "film" : "tv")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isInLibrary {
            badge(symbol: "checkmark", color: .green)
        } else if isOnWatchlist {
            badge(symbol: "bookmark.fill", color: .white.opacity(0.95))
        }
    }

    private func badge(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .padding(8)
            .background(
                Circle()
                    .fill(color)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            )
            .padding(10)
    }
}
