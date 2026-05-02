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
    var allowsBackdropMotion: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var backdrop = HeroBackdropCoordinator()
    @State private var backdropScale: CGFloat = 1.018
    @State private var backdropOffset: CGSize = .zero

    private var shouldAnimateBackdrop: Bool {
        allowsBackdropMotion && !reduceMotion
    }

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
            .scaleEffect(shouldAnimateBackdrop ? backdropScale : 1)
            .offset(
                x: shouldAnimateBackdrop ? backdropOffset.width : 0,
                y: shouldAnimateBackdrop ? backdropOffset.height : 0
            )
            .clipped()

            // Cinematic readability pass: preserve the art while giving the
            // left-aligned logo and actions a stable contrast field.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.96), location: 0),
                    .init(color: .black.opacity(0.84), location: 0.18),
                    .init(color: .black.opacity(0.38), location: 0.42),
                    .init(color: .black.opacity(0.08), location: 0.66),
                    .init(color: .clear, location: 0.82)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.38), location: 0.84),
                    .init(color: .black.opacity(0.93), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.2), location: 0.72),
                    .init(color: .black.opacity(1.0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .onAppear {
            startBackdropMotion()
        }
        .task(id: currentItem?.ratingKey) {
            loadBackdrop()
            startBackdropMotion()
        }
    }

    private func loadBackdrop() {
        guard let item = currentItem else { return }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
        backdrop.load(request: request, motionLocked: false)
    }

    private func startBackdropMotion() {
        guard shouldAnimateBackdrop else {
            backdropScale = 1
            backdropOffset = .zero
            return
        }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            backdropScale = 1.018
            backdropOffset = .zero
        }

        withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
            backdropScale = 1.055
            backdropOffset = CGSize(width: -22, height: -8)
        }
    }
}
