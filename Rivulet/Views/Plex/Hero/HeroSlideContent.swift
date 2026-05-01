//
//  HeroSlideContent.swift
//  Rivulet
//
//  Per-slide foreground for the hero carousel: logo/title, metadata line,
//  tagline. Intentionally decoupled from the button row so the button row
//  stays focus-stable while slides swap with a fade transition.
//

import SwiftUI

struct HeroSlideContent: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String

    private var logoURL: URL? {
        guard let path = item.clearLogoPath else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }

    private var typeLabel: String? {
        guard let type = item.type else { return nil }
        switch type {
        case "movie": return "Movie"
        case "show": return "TV Show"
        case "season": return "TV Show"
        case "episode": return "TV Show"
        case "artist": return "Artist"
        case "album": return "Album"
        default: return type.capitalized
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let type = typeLabel { parts.append(type) }
        if let firstGenre = item.Genre?.first?.tag, !firstGenre.isEmpty {
            parts.append(firstGenre)
        }
        return parts.joined(separator: " · ")
    }

    private var tagline: String? {
        if let explicit = item.tagline, !explicit.isEmpty { return explicit }
        guard let summary = item.summary, !summary.isEmpty else { return nil }
        // Trim to the first sentence for the Apple TV+-style one-line tagline.
        if let endIdx = summary.firstIndex(where: { ".!?".contains($0) }) {
            let firstSentence = summary[..<summary.index(after: endIdx)]
            return String(firstSentence)
        }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleView
            metadataRow
            if let tagline {
                Text(tagline)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let logoURL {
            CachedAsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 520, maxHeight: 180, alignment: .leading)
                case .empty:
                    fallbackTitle
                        .redacted(reason: .placeholder)
                case .failure:
                    fallbackTitle
                }
            }
            .frame(maxHeight: 180, alignment: .leading)
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(item.seriesTitleForDisplay ?? item.title ?? "")
            .font(.system(size: 72, weight: .heavy, design: .serif))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let rating = item.contentRating, !rating.isEmpty {
                Text(rating)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                    )
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
