//
//  ParallaxPosterImage.swift
//  Rivulet
//
//  Poster image with Vision-based shadow depth effect
//

import SwiftUI
import UIKit

/// A poster image that applies a shadow-based depth effect when focused.
/// Uses Vision framework to detect the foreground subject and creates a cutout
/// that gets a drop shadow on focus, making the subject appear to "lift" off the poster.
struct ParallaxPosterImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    @State private var originalImage: UIImage?
    @State private var depthResult: DepthLayerResult?
    @State private var isProcessing = false

    /// Environment value to track parent button's focus state
    @Environment(\.isFocused) private var isFocused

    /// Debounce delay before processing (skip during fast scroll)
    private let processingDebounce: TimeInterval = 0.2

    var body: some View {
        Group {
            if let original = originalImage, let result = depthResult, result.isUsable {
                // Shadow-based depth effect
                ParallaxLayerStack(
                    originalImage: original,
                    foregroundImage: result.foregroundImage,
                    isFocused: isFocused,
                    width: width,
                    height: height,
                    cornerRadius: cornerRadius
                )
            } else {
                // Standard image while loading/processing or if unsuitable
                standardPosterImage
            }
        }
        .task(id: url) {
            await loadImageAndCutout()
        }
    }

    // MARK: - Standard Poster (Fallback)

    private var standardPosterImage: some View {
        CachedAsyncImage(url: url) { phase in
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
                    .fill(Color(white: 0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Image and Cutout Loading

    private func loadImageAndCutout() async {
        guard let url else { return }

        // Load original image for display (off main thread, then update state on main)
        let loadedImage: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let imageData = await ImageCacheManager.shared.imageData(for: url) else {
                return nil
            }
            return UIImage(data: imageData)
        }.value

        if let image = loadedImage {
            await MainActor.run { originalImage = image }
        }

        // Check if already marked unsuitable (actor call, non-blocking)
        if await DepthLayerCache.shared.isMarkedUnsuitable(for: url) {
            return
        }

        // Check cache for foreground cutout (actor call, non-blocking)
        if let cached = await DepthLayerCache.shared.getLayers(for: url) {
            await MainActor.run { depthResult = cached }
            return
        }

        // Debounce processing (skip during fast scroll)
        try? await Task.sleep(nanoseconds: UInt64(processingDebounce * 1_000_000_000))

        guard !Task.isCancelled else { return }

        // Need the original image for processing
        guard let image = originalImage else { return }

        // Process with Vision on background thread (never blocks main)
        let result = await DepthLayerProcessor.shared.processImage(image)

        guard !Task.isCancelled else { return }

        if let result {
            // Cache the result (actor call, non-blocking)
            await DepthLayerCache.shared.cacheLayers(result, for: url)
            await MainActor.run { depthResult = result }
            print("🎨 ParallaxPosterImage: Foreground cutout created for \(url.lastPathComponent), quality: \(result.qualityScore)")
        } else {
            // Mark as unsuitable to avoid reprocessing
            await DepthLayerCache.shared.markUnsuitable(for: url)
            print("🎨 ParallaxPosterImage: Marked unsuitable - \(url.lastPathComponent)")
        }
    }
}

#if DEBUG
struct ParallaxPosterImage_Previews: PreviewProvider {
    static var previews: some View {
        ParallaxPosterImage(
            url: URL(string: "https://example.com/poster.jpg"),
            width: 220,
            height: 330,
            cornerRadius: 12
        )
    }
}
#endif
