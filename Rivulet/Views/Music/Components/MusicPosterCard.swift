//
//  MusicPosterCard.swift
//  Rivulet
//
//  Square album/artist card with glass focus styling
//

import SwiftUI

/// Square artwork card for albums and artists in music shelves.
/// Shows artwork, title, and subtitle with glass focus treatment.
struct MusicPosterCard: View {
    let item: PlexMetadata
    let action: () -> Void

    @FocusState private var isFocused: Bool

    /// Artwork URL built from the item's thumb
    private var artworkURL: URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Subtitle: artist name for albums, year for artists
    private var subtitle: String? {
        if item.type == "album" {
            return item.parentTitle ?? item.grandparentTitle
        } else if item.type == "artist" {
            if let year = item.year { return String(year) }
            return nil
        } else {
            return item.parentTitle ?? item.grandparentTitle
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Square artwork
                CachedAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay {
                                Image(systemName: item.type == "artist" ? "person.fill" : "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                    case .failure:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                )

                // Title
                Text(item.title ?? "Unknown")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                // Subtitle
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(GlassRowButtonStyle())
        .focused($isFocused)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
