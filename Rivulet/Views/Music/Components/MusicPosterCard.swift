//
//  MusicPosterCard.swift
//  Rivulet
//
//  Square album/artist card with standard tvOS focus treatment.
//  Artists use circular clip shape, albums use square.
//

import SwiftUI

/// Card style: square for albums, circular for artists
enum MusicPosterCardStyle {
    case square
    case circular
}

/// Artwork card for albums and artists in music grids.
/// Uses standard tvOS focus effects instead of custom glass styling.
struct MusicPosterCard: View {
    let item: PlexMetadata
    var style: MusicPosterCardStyle = .square
    let action: () -> Void

    /// Artwork URL built from the item's thumb
    private var artworkURL: URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Subtitle: artist name for albums, album count or year for artists
    private var subtitle: String? {
        if item.type == "album" {
            return item.parentTitle ?? item.grandparentTitle
        } else if item.type == "artist" {
            if let count = item.leafCount {
                return "\(count) albums"
            }
            if let year = item.year { return String(year) }
            return nil
        } else {
            return item.parentTitle ?? item.grandparentTitle
        }
    }

    /// Resolved card style — auto-detect from item type if not explicitly set
    private var resolvedStyle: MusicPosterCardStyle {
        if item.type == "artist" { return .circular }
        return style
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Artwork
                artworkView
                    .frame(width: 180, height: 180)

                // Title
                Text(item.title ?? "Unknown")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 180, alignment: resolvedStyle == .circular ? .center : .leading)

                // Subtitle
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(width: 180, alignment: resolvedStyle == .circular ? .center : .leading)
                }
            }
        }
        .buttonStyle(.card)
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkView: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                placeholderView
            @unknown default:
                placeholderView
            }
        }
        .if(resolvedStyle == .circular) { view in
            view.clipShape(Circle())
        }
        .if(resolvedStyle == .square) { view in
            view.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var placeholderView: some View {
        Group {
            if resolvedStyle == .circular {
                Circle()
                    .fill(.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            }
        }
    }
}

// MARK: - Conditional Modifier Helper

private extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
