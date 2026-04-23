//
//  HeroSlideContent.swift
//  Rivulet
//
//  Per-slide foreground for the hero carousel: logo/title, metadata line,
//  tagline. Intentionally decoupled from the button row so the button row
//  stays focus-stable while slides swap with a fade transition.
//

import Foundation
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

    private var descriptorChips: [String] {
        var chips: [String] = []
        if let typeLabel, !typeLabel.isEmpty {
            chips.append(typeLabel.uppercased())
        }
        if let firstGenre = item.Genre?.first?.tag, !firstGenre.isEmpty {
            chips.append(firstGenre.uppercased())
        }
        return chips
    }

    private var summaryText: String? {
        if let explicit = item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines),
           explicit.count >= 18 {
            return explicit
        }

        guard let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return summary
    }

    private var ratingText: String? {
        if let audienceRating = item.audienceRating, audienceRating > 0 {
            return String(format: "%.1f", audienceRating)
        }
        if let rating = item.rating, rating > 0 {
            return String(format: "%.1f", rating)
        }
        return nil
    }

    private var supportingCreditText: String? {
        let castNames = item.Role?.compactMap(\.tag) ?? []
        if !castNames.isEmpty {
            return "Starring \(castNames.prefix(3).joined(separator: ", "))"
        }

        if let studio = item.studio?.trimmingCharacters(in: .whitespacesAndNewlines),
           !studio.isEmpty {
            return studio
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            titleView

            if !descriptorChips.isEmpty {
                HStack(spacing: 10) {
                    ForEach(descriptorChips, id: \.self) { chip in
                        HeroDescriptorChip(text: chip)
                    }
                }
            }

            metadataRow

            if let summaryText, !summaryText.isEmpty {
                Text(summaryText)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 760, alignment: .leading)
                    .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
            }

            if let supportingCreditText, !supportingCreditText.isEmpty {
                Text(supportingCreditText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .frame(maxWidth: 760, alignment: .leading)
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
                        .frame(maxWidth: 620, maxHeight: 180, alignment: .leading)
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
            .font(.system(size: 76, weight: .black, design: .rounded))
            .kerning(2.8)
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            if let year = item.year {
                HeroMetadataMetric(icon: nil, text: String(year))
            }
            if let ratingText {
                HeroMetadataMetric(icon: "star.fill", text: ratingText)
            }
            if let runtime = item.durationFormatted {
                HeroMetadataMetric(icon: "clock.fill", text: runtime)
            }
            if let contentRating = item.contentRating, !contentRating.isEmpty {
                HeroContentRatingBadge(text: contentRating)
            }
        }
    }
}

private struct HeroDescriptorChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .opacity(0.18)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private struct HeroMetadataMetric: View {
    let icon: String?
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 19, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
    }
}

private struct HeroContentRatingBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.24))
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.18)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
    }
}
