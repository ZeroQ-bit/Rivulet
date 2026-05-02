//
//  SubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay view for rendering subtitles.
//

import SwiftUI
import CoreGraphics

/// Overlay view that displays current subtitle cues
struct SubtitleOverlayView: View {
    @ObservedObject var subtitleManager: SubtitleManager
    @ObservedObject private var appearance = SubtitleAppearanceSettings.shared

    /// Vertical offset from bottom (for player controls)
    var bottomOffset: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Bitmap subtitle cues (PGS, DVB-SUB) — positioned absolutely
                ForEach(subtitleManager.currentBitmapCues) { cue in
                    ForEach(Array(cue.rects.enumerated()), id: \.offset) { _, rect in
                        BitmapSubtitleRectView(
                            rect: rect,
                            viewSize: geometry.size,
                            referenceWidth: cue.referenceWidth,
                            referenceHeight: cue.referenceHeight
                        )
                    }
                }

                // Text subtitle cues — anchored to bottom
                VStack {
                    Spacer()

                    if !subtitleManager.currentCues.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(subtitleManager.currentCues) { cue in
                                SubtitleTextView(text: cue.text, appearance: appearance)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, appearance.verticalPosition.bottomPadding(in: geometry.size.height, controlsOffset: bottomOffset))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)  // Don't interfere with player controls
    }
}

/// Individual subtitle text with styling
private struct SubtitleTextView: View {
    let text: String
    @ObservedObject var appearance: SubtitleAppearanceSettings

    var body: some View {
        Text(text)
            .font(.system(size: subtitleFontSize, weight: .semibold))
            .foregroundColor(appearance.textColor.color)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 2)
            .shadow(color: .black.opacity(0.75), radius: 6, x: 0, y: 0)
            .shadow(color: .black.opacity(0.65), radius: 10, x: 0, y: 4)
    }

    private var subtitleFontSize: CGFloat {
        appearance.textSize.fontSize
    }
}

/// Renders a single bitmap subtitle rect as a CGImage, positioned in video coordinates
private struct BitmapSubtitleRectView: View {
    let rect: BitmapSubtitleRect
    let viewSize: CGSize
    /// Codec-reported reference resolution that the rect coordinates are authored
    /// against. 0 means the codec didn't report it; fall back to the HD spec
    /// (1920×1080), which matches Blu-ray PGS authoring.
    let referenceWidth: Int
    let referenceHeight: Int

    var body: some View {
        if let image = createImage() {
            let refW: CGFloat = referenceWidth > 0 ? CGFloat(referenceWidth) : 1920
            let refH: CGFloat = referenceHeight > 0 ? CGFloat(referenceHeight) : 1080
            let scaleX = viewSize.width / refW
            let scaleY = viewSize.height / refH
            let scaledWidth = CGFloat(rect.width) * scaleX
            let scaledHeight = CGFloat(rect.height) * scaleY
            let scaledX = CGFloat(rect.x) * scaleX
            let scaledY = CGFloat(rect.y) * scaleY

            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: scaledWidth, height: scaledHeight)
                .position(x: scaledX + scaledWidth / 2, y: scaledY + scaledHeight / 2)
        }
    }

    private func createImage() -> CGImage? {
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let expectedSize = height * bytesPerRow
        guard rect.imageData.count >= expectedSize else { return nil }

        return rect.imageData.withUnsafeBytes { rawBuf -> CGImage? in
            guard rawBuf.baseAddress != nil else { return nil }

            guard let provider = CGDataProvider(data: rect.imageData as CFData) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray

        SubtitleOverlayView(
            subtitleManager: {
                let manager = SubtitleManager()
                // Note: In real usage, cues come from parsed subtitle file
                return manager
            }()
        )
    }
}
