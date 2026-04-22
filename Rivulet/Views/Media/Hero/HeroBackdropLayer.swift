//
//  HeroBackdropLayer.swift
//  Rivulet
//
//  Pure decoration layer: the current hero item's backdrop art with the
//  shared `HeroBackdropCoordinator` crossfade, plus the dark scrim that
//  keeps title/metadata/button text legible. Owns no focusable content —
//  it sits behind the scroll view on the home screen and lets the overlay
//  controls and content rows scroll on top.
//

import SwiftUI

struct HeroBackdropLayer: View {
    let currentItem: PlexMetadata?
    let serverURL: String
    let authToken: String

    @StateObject private var backdrop = HeroBackdropCoordinator()

    var body: some View {
        ZStack {
            HeroBackdropImage(url: backdrop.session.displayedBackdropURL) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Horizontal scrim so the left-aligned logo/metadata/buttons stay legible.
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

            // Vertical scrim so content rows below blend into the bottom of the art.
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
        .task(id: currentItem?.ratingKey) {
            loadBackdrop()
        }
    }

    private func loadBackdrop() {
        guard let item = currentItem else { return }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
        backdrop.load(request: request, motionLocked: false)
    }
}
