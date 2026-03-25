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
        ZStack {
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

            // Centered title logo
            ContinueWatchingTitleLogo(item: item)

            // Bottom info bar
            VStack {
                Spacer()
                bottomInfoBar
                    .padding(20)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .hoverEffect(.highlight)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
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

            Spacer()
        }
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

// MARK: - Title Logo (async TMDB fetch)

/// Fetches and displays the TMDB title logo, falling back to styled text.
/// For episodes, resolves the show's TMDB ID via grandparentGuid, fetching
/// show metadata if needed (Continue Watching items often lack parent metadata).
private struct ContinueWatchingTitleLogo: View {
    let item: PlexMetadata

    @State private var logoResult: TMDBLogoResult?
    @State private var hasFetched = false
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
    private var logoSize: CGSize {
        let ratio = logoResult?.aspectRatio ?? 2.0
        let rawW = sqrt(targetArea * ratio)
        let rawH = sqrt(targetArea / ratio)
        let w = min(rawW, maxWidth)
        let h = min(rawH, maxHeight)
        return CGSize(width: w, height: h)
    }

    var body: some View {
        Group {
            if let url = logoResult?.url {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: logoSize.width, maxHeight: logoSize.height)
                            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    default:
                        textFallback
                    }
                }
            } else {
                textFallback
            }
        }
        .task {
            guard !hasFetched else { return }
            hasFetched = true
            await fetchLogo()
        }
    }

    private var textFallback: some View {
        Text(displayTitle)
            .font(.system(size: 30 * scale, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    private func fetchLogo() async {
        let tmdbId = await resolveTmdbId()
        guard let tmdbId else { return }

        let mediaType: TMDBMediaType = (item.type == "episode" || item.type == "show") ? .tv : .movie
        let result = await TMDBClient.shared.fetchLogo(tmdbId: tmdbId, type: mediaType)
        await MainActor.run {
            logoResult = result
        }
    }

    /// Resolve the TMDB ID, fetching full metadata when hub items lack Guid array
    private func resolveTmdbId() async -> Int? {
        // Try inline IDs first (rarely available on hub items)
        if item.type == "episode" {
            if let id = item.showTmdbId { return id }
        } else {
            if let id = item.tmdbId { return id }
        }

        // Hub items typically lack Guid array — fetch full metadata from Plex
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return nil
        }

        // For episodes, fetch the show's metadata; for movies/shows, fetch the item itself
        let ratingKey: String?
        let mediaType: TMDBMediaType
        if item.type == "episode" {
            ratingKey = item.grandparentRatingKey
            mediaType = .tv
        } else {
            ratingKey = item.ratingKey
            mediaType = item.tmdbMediaType
        }

        guard let ratingKey else { return nil }

        do {
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            if let tmdbId = metadata.tmdbId { return tmdbId }
            if let tvdbId = metadata.tvdbId {
                return await TMDBClient.shared.findTmdbId(tvdbId: tvdbId, type: mediaType)
            }
        } catch {}
        return nil
    }
}
