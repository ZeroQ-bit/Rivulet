//
//  ContinueWatchingCard.swift
//  Rivulet
//
//  Wide landscape card for Continue Watching items, matching Apple TV style
//

import SwiftUI


// MARK: - Continue Watching Card

struct ContinueWatchingCard: View, Equatable {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    var isFocused: Bool = false

    @Environment(\.uiScale) private var scale

    static func == (lhs: ContinueWatchingCard, rhs: ContinueWatchingCard) -> Bool {
        lhs.item.ratingKey == rhs.item.ratingKey &&
        lhs.item.art == rhs.item.art &&
        lhs.item.viewCount == rhs.item.viewCount &&
        lhs.isFocused == rhs.isFocused &&
        lhs.serverURL == rhs.serverURL
    }

    private var cardWidth: CGFloat { ScaledDimensions.continueWatchingWidth * scale }
    private var cardHeight: CGFloat { ScaledDimensions.continueWatchingHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background artwork
            artworkImage
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

            // Bottom gradient for text readability
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.7), location: 0.7),
                    .init(color: .black.opacity(0.85), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                ContinueWatchingTitleLogo(item: item)
                bottomInfoBar
            }
            .padding(20)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 0.22 : 0.06), lineWidth: isFocused ? 1.5 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(isFocused ? 0.34 : 0.18), radius: isFocused ? 20 : 10, x: 0, y: isFocused ? 16 : 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
    }

    // MARK: - Artwork Image

    private var artworkImage: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.3))
                    }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: item.type == "movie" ? "film" : "play.rectangle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    // MARK: - Bottom Info Bar

    private var infoOpacity: Double { isFocused ? 1.0 : 0.6 }

    private var bottomInfoBar: some View {
        HStack(spacing: 10) {
            // Play icon
            Image(systemName: "play.fill")
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(infoOpacity))

            // Progress bar
            if let progress = item.watchProgress, progress > 0 && progress < 1 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(width: 44 * scale, height: 4)
            }

            // Episode info or duration
            Text(infoText)
                .font(.system(size: 20 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(infoOpacity))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(isFocused ? 0.40 : 0.28))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(isFocused ? 0.18 : 0.12)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(isFocused ? 0.18 : 0.08), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    // MARK: - Computed Properties

    /// Info text matching Apple TV format: "S1, E2 • 35m" or "1h 7m"
    private var infoText: String {
        var parts: [String] = []

        if item.type == "episode" {
            let season = item.parentIndex ?? 0
            let episode = item.index ?? 0
            parts.append("S\(season), E\(episode)")
        }

        if let remaining = item.remainingTimeFormatted {
            parts.append(remaining)
        } else if let duration = item.durationFormatted {
            parts.append(duration)
        }

        return parts.joined(separator: " \u{2022} ")
    }

    /// Artwork URL: prefer backdrop art, fall back to episode thumb
    private var artworkURL: URL? {
        let artPath: String?
        if item.type == "episode" {
            artPath = item.grandparentArt ?? item.art ?? item.thumb
        } else {
            artPath = item.art ?? item.thumb
        }

        guard let path = artPath else { return nil }
        var urlString = "\(serverURL)\(path)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(authToken)"
        }
        return URL(string: urlString)
    }
}

// MARK: - Title Logo (Plex clearLogo fetch)

/// Fetches and displays the Plex `clearLogo`, falling back to styled text.
/// For episodes, resolves the show's clearLogo by fetching the grandparent
/// show's metadata (Continue Watching hub items don't carry an Image array).
private struct ContinueWatchingTitleLogo: View {
    let item: PlexMetadata

    @State private var loadedLogo: UIImage?
    @State private var hasFetched = false
    @State private var revealOpacity: Double = 0
    @Environment(\.uiScale) private var scale

    private var displayTitle: String {
        if item.type == "episode" {
            return item.grandparentTitle ?? item.title ?? "Unknown"
        }
        return item.title ?? "Unknown"
    }

    /// Target area in points² — all logos get roughly the same visual weight
    private var targetArea: CGFloat { 18000 * scale * scale }

    /// Max bounds to prevent overflow
    private var maxWidth: CGFloat { ScaledDimensions.continueWatchingWidth * scale * 0.75 }
    private var maxHeight: CGFloat { ScaledDimensions.continueWatchingHeight * scale * 0.45 }

    /// Compute logo size from target area + aspect ratio, clamped to card bounds
    private func logoSize(for image: UIImage) -> CGSize {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 2.0
        let rawW = sqrt(targetArea * ratio)
        let rawH = sqrt(targetArea / ratio)
        let w = min(rawW, maxWidth)
        let h = min(rawH, maxHeight)
        return CGSize(width: w, height: h)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            textFallback
                .opacity(loadedLogo == nil ? 1 : 0)

            if let loadedLogo {
                Image(uiImage: loadedLogo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: logoSize(for: loadedLogo).width,
                        maxHeight: logoSize(for: loadedLogo).height
                    )
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    .opacity(revealOpacity)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .task {
            guard !hasFetched else { return }
            hasFetched = true
            await fetchLogo()
        }
    }

    private var textFallback: some View {
        Text(displayTitle)
            .font(.system(size: 28 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    @MainActor
    private func fetchLogo() async {
        guard let logoURL = await resolveClearLogoURL() else { return }

        let image = await ImageCacheManager.shared.image(for: logoURL)
        guard let image else { return }

        loadedLogo = image
        withAnimation(.easeInOut(duration: 0.22)) {
            revealOpacity = 1
        }
    }

    /// Resolve the clearLogo URL for this item's show (or the item itself for
    /// movies). For episodes/shows, fetches grandparent/show metadata since
    /// hub items don't carry the `Image` array.
    @MainActor
    private func resolveClearLogoURL() async -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return nil
        }

        // Determine which rating key owns the clearLogo we want.
        let sourceRatingKey: String?
        if item.type == "episode" {
            sourceRatingKey = item.grandparentRatingKey
        } else {
            sourceRatingKey = item.ratingKey
        }

        guard let ratingKey = sourceRatingKey else { return nil }

        // Prefer the cached full-metadata copy if present.
        let sourceMetadata: PlexMetadata
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) {
            sourceMetadata = cached
        } else {
            do {
                let fetched = try await PlexNetworkManager.shared.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                PlexDataStore.shared.cacheFullMetadata(fetched, for: ratingKey)
                sourceMetadata = fetched
            } catch {
                return nil
            }
        }

        guard let path = sourceMetadata.clearLogoPath else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }
}
