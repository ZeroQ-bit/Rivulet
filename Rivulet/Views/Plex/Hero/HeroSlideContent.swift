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

    private var contentCountLabel: String? {
        switch item.type {
        case "show":
            if let seasons = item.childCount, seasons > 0 {
                return seasons == 1 ? "1 Season" : "\(seasons) Seasons"
            }
            if let episodes = item.leafCount, episodes > 0 {
                return episodes == 1 ? "1 Episode" : "\(episodes) Episodes"
            }
        case "season":
            if let episodes = item.leafCount, episodes > 0 {
                return episodes == 1 ? "1 Episode" : "\(episodes) Episodes"
            }
        case "episode":
            if let episodeString = item.episodeString {
                return episodeString
            }
        default:
            break
        }
        return item.durationFormatted
    }

    private var matchLabel: String? {
        let rawScore = item.audienceRating ?? item.rating
        guard let rawScore, rawScore > 0 else { return nil }
        let percent = rawScore <= 10 ? rawScore * 10 : rawScore
        guard percent > 0, percent <= 100 else { return nil }
        return "\(Int(percent.rounded()))% Match"
    }

    private var audioBrandBadge: String? {
        guard let codec = item.Media?.first?.audioCodec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("eac3") || codec.contains("ac3") || codec.contains("truehd") || codec.contains("atmos") {
            return "DOLBY"
        }
        if codec.contains("dts") {
            return "DTS"
        }
        return nil
    }

    private var qualityBadges: [String] {
        var badges: [String] = []
        if let quality = item.videoQualityDisplay {
            badges.append(quality)
        }
        if let hdr = item.hdrFormatDisplay {
            badges.append(hdr)
        }
        if let audio = item.audioFormatDisplay, audio != "Stereo" {
            badges.append(audio)
        }
        if let brand = audioBrandBadge, !badges.contains(brand) {
            badges.append(brand)
        }
        return Array(badges.prefix(4))
    }

    private var synopsis: String? {
        if let summary = item.summary, !summary.isEmpty { return summary }
        if let explicit = item.tagline, !explicit.isEmpty { return explicit }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleView
            metadataRow
            if let synopsis {
                Text(synopsis)
                    .font(.system(size: 24, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(3)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 820, alignment: .leading)
                    .shadow(color: .black.opacity(0.65), radius: 10, x: 0, y: 2)
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
                        .frame(maxWidth: 560, maxHeight: 205, alignment: .leading)
                        .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 4)
                case .empty:
                    fallbackTitle
                        .redacted(reason: .placeholder)
                case .failure:
                    fallbackTitle
                }
            }
            .frame(maxHeight: 205, alignment: .leading)
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(item.seriesTitleForDisplay ?? item.title ?? "")
            .font(.system(size: 74, weight: .black, design: .default))
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: 680, alignment: .leading)
            .shadow(color: .black.opacity(0.65), radius: 12, x: 0, y: 4)
    }

    private var metadataRow: some View {
        HStack(spacing: 13) {
            if let matchLabel {
                Text(matchLabel)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.31, green: 0.86, blue: 0.42))
            }

            if let year = item.year {
                heroPlainInfo(String(year))
            }

            if let rating = item.contentRating, !rating.isEmpty {
                contentRatingBadge(rating)
            }

            if let contentCountLabel {
                heroPlainInfo(contentCountLabel)
            } else if let type = typeLabel, matchLabel == nil, item.year == nil {
                heroPlainInfo(type)
            }

            ForEach(qualityBadges, id: \.self) { badge in
                qualityBadge(badge)
            }
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
    }

    private func heroPlainInfo(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white.opacity(0.74))
    }

    private func contentRatingBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 17, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 19)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.82, green: 0.03, blue: 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.9), lineWidth: 1.7)
            )
    }

    private func qualityBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 17, weight: .black))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.46), lineWidth: 1.4)
            )
    }
}
