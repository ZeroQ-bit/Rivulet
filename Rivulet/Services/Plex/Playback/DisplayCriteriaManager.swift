//
//  DisplayCriteriaManager.swift
//  Rivulet
//
//  Manages tvOS display criteria for HDR/Dolby Vision content
//  Enables Match Frame Rate and Match Dynamic Range for MPV playback
//

import Foundation
import AVFoundation
import AVKit

#if os(tvOS)

/// Manages display criteria for HDR content playback
/// This enables tvOS "Match Content" (Frame Rate and Dynamic Range) for MPV player
///
/// Note: Apple doesn't provide a public API to create AVDisplayCriteria manually.
/// The only way to obtain display criteria is from AVAsset.preferredDisplayCriteria.
/// This manager creates a temporary AVURLAsset to fetch the criteria from the stream.
@MainActor
final class DisplayCriteriaManager {

    static let shared = DisplayCriteriaManager()

    private var hasSetCriteria = false
    private var assetForCriteria: AVURLAsset?

    private init() {}

    // MARK: - Public API

    /// Configure display criteria by fetching it from the stream URL
    /// This creates a temporary AVURLAsset to extract HDR/frame rate metadata
    /// Call this before starting MPV playback to trigger Match Content
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - headers: HTTP headers for authentication
    func configureFromURL(_ url: URL, headers: [String: String]? = nil) async {

        // Create asset with headers
        var options: [String: Any] = [:]
        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)
        self.assetForCriteria = asset  // Keep reference to prevent deallocation

        do {
            // Load the display criteria from the asset (tvOS 16+ API)
            let criteria = try await asset.load(.preferredDisplayCriteria)
            setDisplayCriteria(criteria)
        } catch {
            print("🖥️ DisplayCriteria: Failed to load display criteria: \(error.localizedDescription)")
            // Continue without display criteria - playback will still work, just without mode switching
        }
    }

    /// Configure display criteria using pre-built criteria from an AVAsset
    /// Use this if you already have an AVAsset (e.g., from preflight check)
    func configureFromAsset(_ asset: AVAsset) async {
        do {
            let criteria = try await asset.load(.preferredDisplayCriteria)
            setDisplayCriteria(criteria)
        } catch {
            print("🖥️ DisplayCriteria: Failed to load criteria from asset: \(error.localizedDescription)")
        }
    }

    /// Configure display criteria with known HDR type using a format description
    /// Creates a minimal format description to generate criteria
    /// - Parameters:
    ///   - frameRate: Target frame rate (e.g., 23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
    ///   - width: Video width
    ///   - height: Video height
    ///   - isDolbyVision: Whether content is Dolby Vision
    ///   - isHDR10: Whether content is HDR10/HDR10+
    ///   - isHLG: Whether content is HLG
    func configureWithFormatDescription(
        frameRate: Float,
        width: Int32,
        height: Int32,
        isDolbyVision: Bool = false,
        isHDR10: Bool = false,
        isHLG: Bool = false
    ) {
        // Create a format description with HDR metadata
        var formatDescription: CMFormatDescription?

        // Determine the codec type
        // Use DV-specific codec type (dvh1) for Dolby Vision to trigger DV display mode
        // HEVC for other HDR content, H.264 for SDR
        let codecType: CMVideoCodecType
        if isDolbyVision {
            codecType = 0x64766831 // 'dvh1' — Dolby Vision HEVC
        } else if isHDR10 || isHLG {
            codecType = kCMVideoCodecType_HEVC
        } else {
            codecType = kCMVideoCodecType_H264
        }

        // Build extensions dictionary for HDR metadata
        var extensions: [CFString: Any] = [:]

        // Set color primaries and transfer function based on HDR type
        if isDolbyVision || isHDR10 || isHLG {
            // BT.2020 color primaries for all HDR types
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020

            // YCbCr matrix
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020

            if isDolbyVision {
                // Dolby Vision uses PQ transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                // Add Dolby Vision configuration (Profile 5 is most common for streaming)
                // Note: This is a simplified representation
            } else if isHLG {
                // HLG transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            } else if isHDR10 {
                // HDR10 uses PQ (SMPTE ST 2084)
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            }
        } else {
        }

        // Create the format description
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            print("🖥️ DisplayCriteria: Failed to create format description (status: \(status))")
            return
        }

        // Create display criteria from format description
        let criteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: formatDesc)
        setDisplayCriteria(criteria)
    }

    /// Reset display criteria to default (SDR, system frame rate)
    /// Call this when playback ends
    func reset() {
        guard hasSetCriteria else { return }

        guard let displayManager = getDisplayManager() else {
            print("🖥️ DisplayCriteria: No display manager available for reset")
            return
        }

        displayManager.preferredDisplayCriteria = nil
        hasSetCriteria = false
        assetForCriteria = nil  // Release the asset
    }

    // MARK: - Convenience Methods

    /// Configure display criteria from Plex video stream metadata
    /// Uses format description from Plex metadata (instant, no network request)
    /// This is the preferred method as it adds zero latency to playback start
    /// Works for ALL content - SDR gets frame rate matching, HDR/DV gets dynamic range matching too
    /// - Parameters:
    ///   - videoStream: The video stream metadata from Plex
    ///   - forceHDR10Fallback: If true, treat DV content as HDR10 (for MPV which can't play DV)
    func configureForContent(videoStream: PlexStream?, forceHDR10Fallback: Bool = false) {
        guard let stream = videoStream, stream.isVideo else {
            print("🖥️ DisplayCriteria: No video stream metadata available")
            return
        }

        let frameRate = Float(stream.frameRate ?? 24.0)
        let width = Int32(stream.width ?? 1920)
        let height = Int32(stream.height ?? 1080)

        // For MPV playback, DV gets stripped to HDR10 fallback
        // Check if base layer is HDR10 compatible (BL Compat ID 1 or 4)
        let blCompatID = stream.DOVIBLCompatID
        let hasHDR10Base = blCompatID == 1 || blCompatID == 4

        let isDV: Bool
        let isHDR: Bool
        let isHLG = stream.colorTrc?.lowercased().contains("hlg") == true ||
                    stream.colorTrc?.lowercased().contains("arib-std-b67") == true

        if forceHDR10Fallback && stream.isDolbyVision {
            // MPV can't play DV - use HDR10 if base layer is compatible, otherwise SDR
            isDV = false
            isHDR = hasHDR10Base || stream.isHDR
            print("🖥️ DisplayCriteria: DV content with MPV - using \(isHDR ? "HDR10" : "SDR") fallback (BL CompatID: \(blCompatID ?? -1))")
        } else {
            isDV = stream.isDolbyVision
            isHDR = stream.isHDR && !isDV
        }

        // Log what we're configuring
        let dynamicRange = isDV ? "Dolby Vision" : isHLG ? "HLG" : isHDR ? "HDR10" : "SDR"
        print("🖥️ DisplayCriteria: Configuring for \(dynamicRange) @ \(frameRate)fps (\(width)x\(height))")

        configureWithFormatDescription(
            frameRate: frameRate,
            width: width,
            height: height,
            isDolbyVision: isDV,
            isHDR10: isHDR,
            isHLG: isHLG
        )
    }

    /// Configure display criteria by fetching from stream URL
    /// Note: This adds latency as it requires a network request - use configureForContent(videoStream:) instead
    func configureForContentFromURL(
        url: URL,
        headers: [String: String]?,
        videoStream: PlexStream?
    ) async {
        // Try to get criteria from URL (most accurate but slow)
        await configureFromURL(url, headers: headers)

        // If URL-based approach failed, fall back to metadata
        if !hasSetCriteria {
            configureForContent(videoStream: videoStream)
        }
    }

    // MARK: - Private Helpers

    /// Set display criteria on the display manager
    private func setDisplayCriteria(_ criteria: AVDisplayCriteria) {
        guard let displayManager = getDisplayManager() else {
            print("🖥️ DisplayCriteria: No display manager available")
            return
        }

        displayManager.preferredDisplayCriteria = criteria
        hasSetCriteria = true

        // Log the display manager state
        if displayManager.isDisplayCriteriaMatchingEnabled {
        } else {
            print("🖥️ DisplayCriteria: ⚠️ Display criteria matching is DISABLED in system settings")
            print("🖥️ DisplayCriteria: User should enable 'Match Content' in Settings > Video and Audio")
        }
    }

    /// Get the display manager from the key window
    private func getDisplayManager() -> AVDisplayManager? {
        // On tvOS, get the key window's display manager
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            print("🖥️ DisplayCriteria: Could not find window")
            return nil
        }

        // avDisplayManager may not exist on all tvOS versions (e.g. tvOS 26 simulator)
        guard window.responds(to: Selector(("avDisplayManager"))) else {
            print("🖥️ DisplayCriteria: avDisplayManager not available on this platform")
            return nil
        }

        return window.avDisplayManager
    }
}

#endif
