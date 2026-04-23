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
            let spotlightWidth = min(1_380, geometry.size.width * 0.74)
            let spotlightHeight = min(760, geometry.size.height * 0.82)
            let spotlightXOffset: CGFloat = -32
            let spotlightYOffset: CGFloat = -36

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.04, blue: 0.06),
                        .black,
                        Color(red: 0.04, green: 0.06, blue: 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        Color(red: 0.26, green: 0.47, blue: 0.92).opacity(0.22),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 30,
                    endRadius: max(spotlightWidth, spotlightHeight)
                )

                HeroBackdropImage(
                    url: backdrop.session.displayedBackdropURL,
                    contentMode: .fit
                ) {
                    Color.clear
                }
                .frame(width: spotlightWidth, height: spotlightHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .scaleEffect(1.08)
                .blur(radius: 46)
                .opacity(0.34)
                .offset(x: spotlightXOffset, y: spotlightYOffset)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.95), location: 0.12),
                            .init(color: .black.opacity(0.55), location: 0.28),
                            .init(color: .clear, location: 0.62)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                HeroBackdropImage(
                    url: backdrop.session.displayedBackdropURL,
                    contentMode: .fit
                ) {
                    Color.clear
                }
                .frame(width: spotlightWidth, height: spotlightHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .scaleEffect(1.08)
                .blur(radius: 52)
                .opacity(0.30)
                .offset(x: spotlightXOffset, y: spotlightYOffset)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.50),
                            .init(color: .black.opacity(0.55), location: 0.74),
                            .init(color: .black.opacity(0.92), location: 0.90),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                HeroBackdropImage(
                    url: backdrop.session.displayedBackdropURL,
                    contentMode: .fit
                ) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.12), Color(white: 0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: spotlightWidth, height: spotlightHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .scaleEffect(1.03)
                .opacity(0.56)
                .offset(x: spotlightXOffset, y: spotlightYOffset)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.72), location: 0.24),
                        .init(color: .black.opacity(0.18), location: 0.50),
                        .init(color: .clear, location: 0.72)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.12), location: 0.56),
                        .init(color: .black.opacity(0.72), location: 0.82),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func loadBackdrop() {
        guard let item = currentItem else { return }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: authToken)
        backdrop.load(request: request, motionLocked: false)
    }
}
