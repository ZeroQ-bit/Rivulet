//
//  DepthLayerCache.swift
//  Rivulet
//
//  Actor-based cache for Vision-processed foreground cutouts with disk persistence
//

import UIKit
import Foundation

/// Actor-based cache for foreground cutout images used in poster depth effect.
/// Memory cache: NSCache, 50 items max
/// Disk cache: 500MB max, LRU eviction
actor DepthLayerCache {
    static let shared = DepthLayerCache()

    // MARK: - Configuration

    private let cacheDirectoryName = "DepthLayerCache"
    private let maxMemoryCacheCount = 50
    private let maxDiskCacheSize: Int64 = 500 * 1024 * 1024  // 500MB

    /// Cache version - increment when processing algorithm changes to invalidate old layers
    /// v5: Foreground cutout only (no background), shadow-based depth effect
    private let cacheVersion = 5

    // MARK: - Caches

    private let memoryCache = NSCache<NSString, CachedLayerEntry>()
    private var diskMetadata: [String: DepthLayerMetadata] = [:]
    private var metadataLoaded = false

    // MARK: - Cache Directory

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(cacheDirectoryName)
    }

    // MARK: - Initialization

    private init() {
        memoryCache.countLimit = maxMemoryCacheCount
        Task {
            await createCacheDirectoryIfNeeded()
            await loadMetadata()
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Check if depth layers are cached (memory or disk)
    func hasCachedLayers(for url: URL) -> Bool {
        let key = cacheKey(for: url)

        // Check memory first
        if memoryCache.object(forKey: key as NSString) != nil {
            return true
        }

        // Check disk metadata
        return diskMetadata[key] != nil
    }

    /// Check if URL was previously processed and marked unsuitable
    func isMarkedUnsuitable(for url: URL) -> Bool {
        let key = cacheKey(for: url)
        return diskMetadata[key]?.unsuitable == true
    }

    /// Get cached depth layers from memory or disk
    func getLayers(for url: URL) async -> DepthLayerResult? {
        let key = cacheKey(for: url)

        // Check memory cache
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached.result
        }

        // Load from disk
        guard let result = await loadFromDisk(key: key) else {
            return nil
        }

        // Store in memory cache
        memoryCache.setObject(CachedLayerEntry(result: result), forKey: key as NSString)
        return result
    }

    /// Cache processed depth layers
    func cacheLayers(_ result: DepthLayerResult, for url: URL) async {
        let key = cacheKey(for: url)

        // Store in memory
        memoryCache.setObject(CachedLayerEntry(result: result), forKey: key as NSString)

        // Store on disk
        await saveToDisk(result: result, key: key)

        // Evict if needed
        await evictIfNeeded()
    }

    /// Mark a URL as unsuitable for depth effect (no distinct foreground)
    func markUnsuitable(for url: URL) async {
        let key = cacheKey(for: url)
        let metadata = DepthLayerMetadata(
            qualityScore: 0,
            processedAt: Date(),
            originalWidth: 0,
            originalHeight: 0,
            unsuitable: true
        )
        diskMetadata[key] = metadata
        saveMetadata()
    }

    /// Clear all cached depth layers
    func clearAll() async {
        memoryCache.removeAllObjects()
        diskMetadata.removeAll()

        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveMetadata()
        print("🎨 DepthLayerCache: Cleared all cached depth layers")
    }

    /// Get total disk cache size
    func getCacheSize() -> Int64 {
        guard let dir = cacheDirectory else { return 0 }
        var size: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }

    // MARK: - Private Implementation

    private func cacheKey(for url: URL) -> String {
        // Include version in key so algorithm changes invalidate old cache
        "\(url.absoluteString)_v\(cacheVersion)".sha256Hash()
    }

    private func loadFromDisk(key: String) async -> DepthLayerResult? {
        guard let cacheDir = cacheDirectory else { return nil }
        guard let metadata = diskMetadata[key], !metadata.unsuitable else { return nil }

        return await Task.detached(priority: .userInitiated) { [cacheDir] in
            let foregroundURL = cacheDir.appendingPathComponent("\(key)_fg.png")

            guard let foregroundData = try? Data(contentsOf: foregroundURL),
                  let foregroundImage = UIImage(data: foregroundData) else {
                return nil
            }

            return DepthLayerResult(
                foregroundImage: foregroundImage,
                qualityScore: metadata.qualityScore
            )
        }.value
    }

    private func saveToDisk(result: DepthLayerResult, key: String) async {
        guard let cacheDir = cacheDirectory else { return }

        await Task.detached(priority: .utility) { [cacheDir] in
            let foregroundURL = cacheDir.appendingPathComponent("\(key)_fg.png")

            // Save foreground as PNG (preserves transparency)
            if let foregroundData = result.foregroundImage.pngData() {
                try? foregroundData.write(to: foregroundURL, options: .atomic)
            }
        }.value

        // Update metadata
        let metadata = DepthLayerMetadata(
            qualityScore: result.qualityScore,
            processedAt: Date(),
            originalWidth: Int(result.foregroundImage.size.width),
            originalHeight: Int(result.foregroundImage.size.height),
            unsuitable: false
        )
        diskMetadata[key] = metadata
        saveMetadata()
    }

    private func evictIfNeeded() async {
        let currentSize = getCacheSize()
        guard currentSize > maxDiskCacheSize else { return }

        print("🎨 DepthLayerCache: Cache size \(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file)) exceeds limit, evicting...")

        // Sort by processing time (oldest first)
        let sortedEntries = diskMetadata
            .filter { !$0.value.unsuitable }
            .sorted { $0.value.processedAt < $1.value.processedAt }

        var freedSpace: Int64 = 0
        let targetFreeSpace = currentSize - (maxDiskCacheSize * 8 / 10)  // Free up to 80%

        guard let cacheDir = cacheDirectory else { return }

        for (key, _) in sortedEntries {
            if freedSpace >= targetFreeSpace { break }

            let foregroundURL = cacheDir.appendingPathComponent("\(key)_fg.png")

            var entrySize: Int64 = 0
            if let fgSize = try? foregroundURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                entrySize += Int64(fgSize)
            }

            try? FileManager.default.removeItem(at: foregroundURL)
            freedSpace += entrySize
            diskMetadata.removeValue(forKey: key)
            memoryCache.removeObject(forKey: key as NSString)
        }

        saveMetadata()
        print("🎨 DepthLayerCache: Evicted \(ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file))")
    }

    // MARK: - Metadata Persistence

    private func loadMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let metadataURL = cacheDir.appendingPathComponent("metadata.json")

        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([String: DepthLayerMetadata].self, from: data) else {
            metadataLoaded = true
            return
        }

        diskMetadata = decoded
        metadataLoaded = true
        print("🎨 DepthLayerCache: Loaded metadata for \(diskMetadata.count) cached depth layers")
    }

    private func saveMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let metadataURL = cacheDir.appendingPathComponent("metadata.json")

        guard let data = try? JSONEncoder().encode(diskMetadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}

// MARK: - Memory Cache Entry Wrapper

/// Wrapper class for NSCache (requires class type)
private final class CachedLayerEntry {
    let result: DepthLayerResult

    init(result: DepthLayerResult) {
        self.result = result
    }
}
