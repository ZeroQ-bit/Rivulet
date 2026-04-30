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
import UIKit

struct HeroSlideContent: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String

    @State private var loadedLogo: UIImage?
    @State private var attemptedLogoLoad = false

    private static let logoFrameHeightBase: CGFloat = 190
    private static let titleMaxWidth: CGFloat = 520
    private static let fallbackTitleMaxWidth: CGFloat = 900

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
        VStack(alignment: .leading, spacing: 18) {
            titleView

            if !descriptorChips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(descriptorChips, id: \.self) { chip in
                        HeroDescriptorChip(text: chip)
                    }
                }
            }

            metadataRow

            if let summaryText, !summaryText.isEmpty {
                Text(summaryText)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 680, alignment: .leading)
                    .shadow(color: .black.opacity(0.24), radius: 5, x: 0, y: 2)
            }

            if let supportingCreditText, !supportingCreditText.isEmpty {
                Text(supportingCreditText)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
                    .lineLimit(1)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        }
        .task(id: logoURL) {
            await loadLogo()
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let loadedLogo {
            heroLogoView(for: loadedLogo)
        } else if logoURL != nil && !attemptedLogoLoad {
            fallbackTitle
                .redacted(reason: .placeholder)
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        ViewThatFits(in: .vertical) {
            fallbackTitleText(fontSize: 54, tracking: 0.7, lineLimit: 2)
            fallbackTitleText(fontSize: 48, tracking: 0.5, lineLimit: 2)
            fallbackTitleText(fontSize: 42, tracking: 0.35, lineLimit: 3)
            fallbackTitleText(fontSize: 38, tracking: 0.25, lineLimit: 3)
        }
        .frame(maxWidth: Self.fallbackTitleMaxWidth, minHeight: 84, maxHeight: 144, alignment: .leading)
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

    private func heroLogoView(for logo: UIImage) -> some View {
        let metrics = logoDisplayMetrics(for: logo)

        return Image(uiImage: logo)
            .renderingMode(.original)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: metrics.width, height: metrics.height, alignment: .leading)
            .padding(.vertical, 4)
            .shadow(color: .black.opacity(0.42), radius: 10, x: 0, y: 4)
    }

    private func fallbackTitleText(
        fontSize: CGFloat,
        tracking: CGFloat,
        lineLimit: Int
    ) -> some View {
        Text(item.seriesTitleForDisplay ?? item.title ?? "")
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .kerning(tracking)
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.84)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: Self.fallbackTitleMaxWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
    }

    private func logoDisplayMetrics(for logo: UIImage) -> CGSize {
        guard logo.size.height > 0 else {
            return CGSize(width: Self.titleMaxWidth, height: 92)
        }

        let aspectRatio = max(1, min(logo.size.width / logo.size.height, 6))
        let targetHeight = min(150, max(78, Self.logoFrameHeightBase / sqrt(aspectRatio)))
        let targetWidth = min(Self.titleMaxWidth, max(180, targetHeight * aspectRatio))

        return CGSize(width: targetWidth, height: targetHeight)
    }

    @MainActor
    private func loadLogo() async {
        loadedLogo = nil
        attemptedLogoLoad = false

        guard let logoURL else { return }

        if let image = await ImageCacheManager.shared.image(for: logoURL) {
            loadedLogo = image.trimmingTransparentPixels() ?? image
        }

        attemptedLogoLoad = true
    }
}

private extension UIImage {
    func trimmingTransparentPixels(alphaThreshold: UInt8 = 12) -> UIImage? {
        guard let cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let alpha = pixels[rowOffset + (x * bytesPerPixel) + 3]
                guard alpha > alphaThreshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return self }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return self
        }

        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

private struct HeroDescriptorChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .opacity(0.12)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.08), lineWidth: 1)
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
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 18, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.82))
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
