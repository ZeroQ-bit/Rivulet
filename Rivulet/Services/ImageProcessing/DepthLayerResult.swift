//
//  DepthLayerResult.swift
//  Rivulet
//
//  Data model for Vision-processed foreground cutout for depth effect
//

import UIKit

/// Result of Vision framework foreground segmentation for depth effect.
/// Contains a foreground cutout (subject with transparency) that gets a
/// drop shadow on focus to create a 3D "lifted" appearance.
struct DepthLayerResult {
    /// Foreground subject cutout with transparent background (PNG with alpha).
    /// Composited over the original image with a drop shadow on focus.
    let foregroundImage: UIImage

    /// Quality score from 0-1 indicating segmentation confidence.
    /// Reject results with score < 0.5
    let qualityScore: Float

    /// Whether this result is suitable for depth effect
    var isUsable: Bool {
        qualityScore >= 0.5
    }
}

/// Metadata stored alongside cached glow masks
struct DepthLayerMetadata: Codable {
    let qualityScore: Float
    let processedAt: Date
    let originalWidth: Int
    let originalHeight: Int

    /// Whether this was marked as unsuitable (no distinct foreground)
    let unsuitable: Bool
}
