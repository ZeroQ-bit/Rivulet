//
//  DepthLayerProcessor.swift
//  Rivulet
//
//  Vision framework processing to create foreground cutout for depth effect
//

import UIKit
import Vision
import CoreImage

/// Processes images using Vision framework to create a foreground subject cutout.
/// The cutout is composited over the original image with a drop shadow on focus
/// to create a 3D "lifted" depth effect.
actor DepthLayerProcessor {
    static let shared = DepthLayerProcessor()

    // MARK: - Configuration

    /// Maximum concurrent processing tasks
    private let maxConcurrentTasks = 2

    /// Minimum mask coverage to be considered valid (5%)
    private let minMaskCoverage: Float = 0.05

    /// Maximum mask coverage to be considered valid (90%)
    private let maxMaskCoverage: Float = 0.90

    // MARK: - State

    private var activeTasks = 0

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Process an image to extract a foreground subject cutout for depth effect.
    /// Returns nil if processing fails or the image is unsuitable for the effect.
    /// All heavy work runs on background threads - never blocks main thread.
    func processImage(_ image: UIImage) async -> DepthLayerResult? {
        // Wait for available slot if at capacity (yields, doesn't spin)
        while activeTasks >= maxConcurrentTasks {
            try? await Task.sleep(for: .milliseconds(50))
            // Check for cancellation while waiting
            if Task.isCancelled { return nil }
        }

        activeTasks += 1
        defer { activeTasks -= 1 }

        // Run Vision processing on detached background task (utility priority = low)
        return await Task.detached(priority: .utility) { [image] in
            await self.performProcessing(image)
        }.value
    }

    // MARK: - Private Implementation

    private nonisolated func performProcessing(_ image: UIImage) async -> DepthLayerResult? {
        guard let cgImage = image.cgImage else {
            print("🎨 DepthLayerProcessor: Failed to get CGImage")
            return nil
        }

        // Create Vision request for foreground instance mask
        let request = VNGenerateForegroundInstanceMaskRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            print("🎨 DepthLayerProcessor: Vision request failed: \(error.localizedDescription)")
            return nil
        }

        guard let result = request.results?.first else {
            return nil
        }

        // Get the mask as a pixel buffer
        guard let maskBuffer = try? result.generateScaledMaskForImage(
            forInstances: result.allInstances,
            from: handler
        ) else {
            print("🎨 DepthLayerProcessor: Failed to generate mask")
            return nil
        }

        // Calculate mask coverage to assess quality
        let coverage = calculateMaskCoverage(maskBuffer)

        // Reject masks that cover too much or too little
        guard coverage >= minMaskCoverage && coverage <= maxMaskCoverage else {
            return nil
        }

        // Calculate quality score (best around 30-50% coverage)
        let qualityScore = calculateQualityScore(coverage: coverage)

        // Create foreground cutout
        guard let foreground = createForegroundCutout(
            cgImage: cgImage,
            maskBuffer: maskBuffer
        ) else {
            print("🎨 DepthLayerProcessor: Failed to create foreground cutout")
            return nil
        }

        return DepthLayerResult(
            foregroundImage: foreground,
            qualityScore: qualityScore
        )
    }

    private nonisolated func calculateMaskCoverage(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var maskedPixels: Int = 0
        let totalPixels = width * height

        // Sample every 4th pixel for performance
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = y * bytesPerRow + x
                if buffer[offset] > 128 {  // Threshold for mask
                    maskedPixels += 1
                }
            }
        }

        // Adjust for sampling (we sampled 1/4 of pixels)
        return Float(maskedPixels * 4) / Float(totalPixels)
    }

    private nonisolated func calculateQualityScore(coverage: Float) -> Float {
        // Best quality around 30-50% coverage
        // Score decreases as coverage approaches min/max thresholds
        let optimalCoverage: Float = 0.40
        let deviation = abs(coverage - optimalCoverage)

        // Scale score from 0.5 to 1.0 based on how close to optimal
        let maxDeviation: Float = 0.40
        let normalizedDeviation = min(deviation / maxDeviation, 1.0)

        return 1.0 - (normalizedDeviation * 0.5)
    }

    /// Create a foreground cutout of the subject with transparent background.
    private nonisolated func createForegroundCutout(
        cgImage: CGImage,
        maskBuffer: CVPixelBuffer
    ) -> UIImage? {
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Convert original image and mask to CIImage
        let originalCIImage = CIImage(cgImage: cgImage)
        let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)

        // Scale mask to match original image size
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let scaleX = imageWidth / maskCIImage.extent.width
        let scaleY = imageHeight / maskCIImage.extent.height
        let scaledMask = maskCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Use mask as alpha channel for the original image
        guard let foregroundBlend = CIFilter(name: "CIBlendWithMask") else { return nil }
        foregroundBlend.setValue(originalCIImage, forKey: kCIInputImageKey)
        foregroundBlend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        foregroundBlend.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let foregroundCIImage = foregroundBlend.outputImage,
              let foregroundCGImage = ciContext.createCGImage(foregroundCIImage, from: originalCIImage.extent) else {
            return nil
        }

        return UIImage(cgImage: foregroundCGImage)
    }
}
