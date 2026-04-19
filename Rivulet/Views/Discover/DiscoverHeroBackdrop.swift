//
//  DiscoverHeroBackdrop.swift
//  Rivulet
//
//  Pure-decoration backdrop behind the Discover page hero. Loads the current
//  item's backdrop URL via `HeroBackdropImage` so the previous image stays
//  visible during cross-fade (no white/blank flash when paging through the
//  carousel).
//

import SwiftUI

struct DiscoverHeroBackdrop: View {
    let currentItem: MediaItem?

    private var backdropURL: URL? {
        currentItem?.backdropURL
    }

    var body: some View {
        ZStack {
            HeroBackdropImage(url: backdropURL) {
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
