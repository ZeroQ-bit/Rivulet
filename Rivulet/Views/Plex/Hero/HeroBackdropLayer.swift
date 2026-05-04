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
            Color.black

            GeometryReader { proxy in
                let artworkWidth = min(proxy.size.width, 1280)
                let artworkHeight = min(proxy.size.height, 720)

                HeroBackdropImage(
                    url: backdrop.session.displayedBackdropURL,
                    imageAlignment: .topTrailing
                ) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.15), Color(white: 0.05)],
                                startPoint: .topTrailing,
                                endPoint: .bottomLeading
                            )
                        )
                }
                .frame(width: artworkWidth, height: artworkHeight)
                .mask(HeroBackdropCornerFadeMask())
                .scaleEffect(shouldAnimateBackdrop ? backdropScale : 1, anchor: .topTrailing)
                .offset(
                    x: shouldAnimateBackdrop ? backdropOffset.width : 0,
                    y: shouldAnimateBackdrop ? backdropOffset.height : 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .clipped()
            }

            // Keep the left-aligned logo/actions readable while letting the
            // artwork sit high and to the trailing side.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.96), location: 0),
                    .init(color: .black.opacity(0.88), location: 0.18),
                    .init(color: .black.opacity(0.52), location: 0.38),
                    .init(color: .black.opacity(0.16), location: 0.58),
                    .init(color: .clear, location: 0.74)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.16), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.7), location: 0.74),
                    .init(color: .black.opacity(1.0), location: 1)
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

struct HeroBackdropCornerFadeMask: View {
    var body: some View {
        Rectangle()
            .fill(Color.white)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.18), location: 0.12),
                        .init(color: .white, location: 0.34),
                        .init(color: .white, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.52),
                        .init(color: .white.opacity(0.34), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}
