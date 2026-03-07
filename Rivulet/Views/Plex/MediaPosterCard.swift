//
//  MediaPosterCard.swift
//  Rivulet
//
//  Reusable poster card component for movies, shows, and episodes
//

import SwiftUI


// MARK: - Card Button Style (tvOS - minimal, no focus ring)

/// A minimal button style that removes the default tvOS focus ring.
/// Hover effect is applied directly to the poster image inside MediaPosterCard.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Watched Corner Tag

/// A triangular corner tag indicating the item has been watched
/// Uses Path instead of Canvas for simpler GPU-backed rendering
struct WatchedCornerTag: View {
    private let size: CGFloat = 48
    private let checkSize: CGFloat = 18

    /// Triangle shape for the corner tag
    private struct CornerTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: rect.width, y: 0))
                p.addLine(to: CGPoint(x: rect.width, y: rect.height))
                p.closeSubpath()
            }
        }
    }

    var body: some View {
        CornerTriangle()
            .fill(.green)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: checkSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
    }
}

// MARK: - Media Poster Card

/// Equatable conformance helps SwiftUI skip re-renders when props haven't changed
struct MediaPosterCard: View, Equatable {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String

    @Environment(\.uiScale) private var scale

    // Equatable: only re-render if the item's key data changes
    // Note: viewOffset excluded - it changes during playback and would cause excessive re-renders
    static func == (lhs: MediaPosterCard, rhs: MediaPosterCard) -> Bool {
        lhs.item.ratingKey == rhs.item.ratingKey &&
        lhs.item.thumb == rhs.item.thumb &&
        lhs.item.viewCount == rhs.item.viewCount &&
        lhs.serverURL == rhs.serverURL
    }

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var defaultPosterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    /// Music items (albums, artists) should display as square posters
    private var posterHeight: CGFloat {
        let isMusicItem = item.type == "album" || item.type == "artist" || item.type == "track"
        return isMusicItem ? posterWidth : defaultPosterHeight
    }

    var body: some View {
        posterImage
            .frame(width: posterWidth, height: posterHeight)
            .overlay(alignment: .topTrailing) {
                unwatchedBadge
            }
            .overlay {
                progressBarOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }

    // MARK: - Poster Image

    @ViewBuilder
    private var posterImage: some View {
        standardPosterImage
    }

    private var standardPosterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
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
                        Image(systemName: iconForType)
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    // MARK: - Progress Overlay

    /// Check if this is an audio item (no played indicators for audio)
    private var isAudioItem: Bool {
        item.type == "album" || item.type == "artist" || item.type == "track"
    }

    @ViewBuilder
    private var progressBarOverlay: some View {
        // Don't show progress for audio items
        if !isAudioItem, let progress = item.watchProgress, progress > 0 && progress < 1 {
            VStack {
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Dark backing for contrast on light posters
                        Capsule()
                            .fill(.black.opacity(0.5))

                        // Glow layer
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * progress)
                            .blur(radius: 4)
                            .opacity(0.8)

                        // Sharp core
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
            }
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var unwatchedBadge: some View {
        // Don't show badges for audio items
        if isAudioItem {
            EmptyView()
        }
        // For TV shows: show unwatched episode count
        else if let leafCount = item.leafCount, leafCount > 0, item.type == "show" {
            Text("\(leafCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.blue)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                )
                .padding(10)
        }
        // For movies/episodes: show corner tag if fully watched
        else if isFullyWatched {
            WatchedCornerTag()
        }
    }

    /// Check if item is fully watched (no progress bar, has been viewed)
    private var isFullyWatched: Bool {
        // Must have been viewed at least once
        guard let viewCount = item.viewCount, viewCount > 0 else {
            return false
        }
        // Must not have partial progress (would show progress bar instead)
        if let progress = item.watchProgress, progress > 0 && progress < 1 {
            return false
        }
        // For episodes, check viewOffset vs duration
        if let viewOffset = item.viewOffset, let duration = item.duration {
            // If there's significant remaining time, not fully watched
            let remaining = duration - viewOffset
            if remaining > 60000 { // More than 1 minute remaining
                return false
            }
        }
        return true
    }

    // MARK: - Computed Properties

    private var posterURL: URL? {
        // For episodes, prefer the series poster (grandparentThumb) over episode thumbnail
        let thumb: String?
        if item.type == "episode" {
            thumb = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            thumb = item.thumb
        }

        guard let thumbPath = thumb else { return nil }
        var urlString = "\(serverURL)\(thumbPath)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(authToken)"
        }
        return URL(string: urlString)
    }

    private var iconForType: String {
        switch item.type {
        case "movie": return "film"
        case "show": return "tv"
        case "season": return "number.square"
        case "episode": return "play.rectangle"
        case "artist": return "music.mic"
        case "album": return "square.stack"
        case "track": return "music.note"
        default: return "photo"
        }
    }

}

// MARK: - Horizontal Scroll Row

struct MediaRow: View {
    let title: String
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    var contextMenuSource: MediaItemContextSource = .other
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onGoToSeason: ((PlexMetadata) -> Void)?
    var onGoToShow: ((PlexMetadata) -> Void)?

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    // Track focused item for proper initial focus
    @FocusState private var focusedItemId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: item.ratingKey)
                        .mediaItemContextMenu(
                            item: item,
                            serverURL: serverURL,
                            authToken: authToken,
                            source: contextMenuSource,
                            onRefreshNeeded: onRefreshNeeded,
                            onGoToSeason: onGoToSeason != nil ? { onGoToSeason?(item) } : nil,
                            onGoToShow: onGoToShow != nil ? { onGoToShow?(item) } : nil
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 32)  // Room for scale effect and shadow
            }
            .scrollClipDisabled()  // Allow shadow overflow
        }
        .focusSection()
        // Set first item as default focus when this row receives focus
        .defaultFocus($focusedItemId, items.first?.ratingKey)
    }
}

// MARK: - Vertical Grid

struct MediaGrid: View {
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    var contextMenuSource: MediaItemContextSource = .library
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onGoToSeason: ((PlexMetadata) -> Void)?
    var onGoToShow: ((PlexMetadata) -> Void)?

    @Environment(\.uiScale) private var scale

    // Track focused item for proper initial focus
    @FocusState private var focusedItemId: String?

    private var columns: [GridItem] {
        let minWidth = ScaledDimensions.gridMinWidth * scale
        let maxWidth = ScaledDimensions.gridMaxWidth * scale
        let spacing = ScaledDimensions.gridSpacing
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: spacing)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(items, id: \.ratingKey) { item in
                Button {
                    onItemSelected?(item)
                } label: {
                    MediaPosterCard(
                        item: item,
                        serverURL: serverURL,
                        authToken: authToken
                    )
                }
                .buttonStyle(CardButtonStyle())
                .focused($focusedItemId, equals: item.ratingKey)
                .mediaItemContextMenu(
                    item: item,
                    serverURL: serverURL,
                    authToken: authToken,
                    source: contextMenuSource,
                    onRefreshNeeded: onRefreshNeeded,
                    onGoToSeason: onGoToSeason != nil ? { onGoToSeason?(item) } : nil,
                    onGoToShow: onGoToShow != nil ? { onGoToShow?(item) } : nil
                )
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.vertical, 32)  // Room for scale effect and shadow
        .focusSection()
        // Set first item as default focus when this grid receives focus
        .defaultFocus($focusedItemId, items.first?.ratingKey)
    }
}

#Preview {
    let sampleItem = PlexMetadata(
        ratingKey: "123",
        key: "/library/metadata/123",
        type: "movie",
        title: "Sample Movie",
        year: 2024
    )

    MediaPosterCard(
        item: sampleItem,
        serverURL: "http://localhost:32400",
        authToken: "test"
    )
}
