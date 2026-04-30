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

enum HeroBackdropPresentationStyle {
    case immersive
    case spotlight
}

struct HeroBackdropLayer: View {
    let currentItem: PlexMetadata?
    let serverURL: String
    let authToken: String
    var presentationStyle: HeroBackdropPresentationStyle = .immersive

    @StateObject private var backdrop = HeroBackdropCoordinator()

    var body: some View {
        ZStack {
            switch presentationStyle {
            case .immersive:
                immersiveBody
            case .spotlight:
                spotlightBody
            }
        }
        .allowsHitTesting(false)
        .task(id: currentItem?.ratingKey) {
            loadBackdrop()
        }
    }

    private var immersiveBody: some View {
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
    }

    private var spotlightBody: some View {
        GeometryReader { geometry in
        let spotlightWidth: CGFloat = min(1_240, geometry.size.width * 0.67)
        let spotlightHeight: CGFloat = min(700, geometry.size.height * 0.76)
        let spotlightXOffset: CGFloat = 10
        let spotlightYOffset: CGFloat = -24

            ZStack(alignment: .topLeading) {
                Color.black

                HeroBackdropImage(
                    url: backdrop.session.displayedBackdropURL,
                    contentMode: .fit
                ) {
                    Color.clear
                }
                .frame(width: spotlightWidth, height: spotlightHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .scaleEffect(1.0, anchor: .topTrailing)
                .opacity(0.78)
                .offset(x: spotlightXOffset, y: spotlightYOffset)
                .padding(.trailing, -40)
                .ignoresSafeArea(.container, edges: [.top, .trailing])
                .overlay {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black.opacity(0.78), location: 0.0),
                            .init(color: .black.opacity(0.46), location: 0.08),
                            .init(color: .black.opacity(0.18), location: 0.18),
                            .init(color: .black.opacity(0.06), location: 0.30),
                            .init(color: .clear, location: 0.42)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.black, .black.opacity(0.82), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 96)
                    .blur(radius: 14)
                }
                .overlay {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.44),
                            .init(color: .black.opacity(0.22), location: 0.60),
                            .init(color: .black.opacity(0.54), location: 0.78),
                            .init(color: .black, location: 1.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 92)
                    .blur(radius: 14)
                }
                .overlay {
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.74),
                            .init(color: .black.opacity(0.15), location: 0.88),
                            .init(color: .black.opacity(0.30), location: 1.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .clear, location: 0.20),
                                .init(color: .clear, location: 0.40),
                                .init(color: .black.opacity(0.36), location: 0.60),
                                .init(color: .black.opacity(0.76), location: 0.80),
                                .init(color: .black, location: 1.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .ignoresSafeArea()
            }
        }
    }

    private func loadBackdrop() {
        guard let item = currentItem else { return }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
        backdrop.load(request: request, motionLocked: false)
    }
}
