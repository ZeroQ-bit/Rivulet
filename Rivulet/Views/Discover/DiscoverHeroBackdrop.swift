//
//  DiscoverHeroBackdrop.swift
//  Rivulet
//
//  Pure-decoration backdrop behind the Discover page hero. Loads the current
//  item's backdrop from the TMDB image CDN and applies the same left + bottom
//  scrims the Plex hero uses so the overlay text stays legible.
//

import SwiftUI

struct DiscoverHeroBackdrop: View {
    let currentItem: TMDBListItem?

    private static let backdropBase = "https://image.tmdb.org/t/p/original"

    private var backdropURL: URL? {
        guard let path = currentItem?.backdropPath, !path.isEmpty else { return nil }
        return URL(string: "\(Self.backdropBase)\(path)")
    }

    var body: some View {
        ZStack {
            if let url = backdropURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }

            // Horizontal scrim so left-aligned hero text stays legible.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.88), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.28),
                    .init(color: .black.opacity(0.08), location: 0.55),
                    .init(color: .clear, location: 0.7)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Vertical scrim so content rows below blend into the backdrop.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.15), location: 0.55),
                    .init(color: .black.opacity(0.85), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var fallback: some View {
        Rectangle().fill(
            LinearGradient(
                colors: [Color(white: 0.15), Color(white: 0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
