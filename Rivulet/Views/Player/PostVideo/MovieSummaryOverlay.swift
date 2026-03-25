//
//  MovieSummaryOverlay.swift
//  Rivulet
//
//  Post-video overlay for movies showing completion stats and recommendations
//

import SwiftUI

struct MovieSummaryOverlay: View {
    @ObservedObject var viewModel: UniversalPlayerViewModel

    // Focus namespace for default focus control
    @Namespace private var buttonNamespace
    @FocusState private var focusedButton: PostVideoFocusTarget?

    private var durationString: String {
        let totalMinutes = Int(viewModel.duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func setDefaultFocus() {
        focusedButton = .close
    }

    /// Background image (art preferred, fallback to thumb)
    private var backgroundImage: UIImage? {
        viewModel.loadingArtImage ?? viewModel.loadingThumbImage
    }

    var body: some View {
        ZStack {
            // Blurred background image (or solid black fallback)
            if let image = backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 50)
                    .overlay(Color.black.opacity(0.5))
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer()

                // Main content
                VStack(spacing: 32) {
                    // Completion header
                    VStack(spacing: 12) {
                        Text("You watched")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.6))

                        Text(viewModel.title)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Label(durationString, systemImage: "clock")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    // Recommendations
                    if !viewModel.recommendations.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("More Like This")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.leading, 8)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 20) {
                                    ForEach(viewModel.recommendations) { item in
                                        MovieRecommendationCard(
                                            item: item,
                                            serverURL: viewModel.serverURL,
                                            authToken: viewModel.authToken
                                        )
                                    }
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                        .frame(maxWidth: 1200)
                    }

                    // Dismiss button - returns to fullscreen video
                    PostVideoButton(
                        title: "Dismiss",
                        icon: "xmark",
                        isPrimary: true,
                        isFocused: focusedButton == .close
                    ) {
                        viewModel.dismissPostVideo()
                    }
                    .prefersDefaultFocus(in: buttonNamespace)
                    .focused($focusedButton, equals: .close)
        }
        .padding(.horizontal, 80)

                Spacer()
            }
        }
        .focusScope(buttonNamespace)
        .focusSection()
        .onAppear {
            setDefaultFocus()
        }
        .onExitCommand {
            // Back button returns to fullscreen video, doesn't exit player
            viewModel.dismissPostVideo()
        }
    }
}

// MARK: - Movie Recommendation Card

struct MovieRecommendationCard: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String

    @FocusState private var isFocused: Bool

    private var thumbURL: URL? {
        guard let thumb = item.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }

    var body: some View {
        Button {
            // TODO: Navigate to item detail or play
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Poster
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(2/3, contentMode: .fill)
                    case .failure:
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    case .empty:
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .overlay {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                    }
                }
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isFocused ? .white : .clear, lineWidth: 3)
                )

                // Title
                Text(item.title ?? "Unknown")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: 150, alignment: .leading)

                // Year
                if let year = item.year {
                    Text(String(year))
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
    }
}

#Preview {
    MovieSummaryOverlay(
        viewModel: {
            let vm = UniversalPlayerViewModel(
                metadata: PlexMetadata(ratingKey: "1", type: "movie", title: "Inception"),
                serverURL: "http://localhost:32400",
                authToken: "test"
            )
            return vm
        }()
    )
}
