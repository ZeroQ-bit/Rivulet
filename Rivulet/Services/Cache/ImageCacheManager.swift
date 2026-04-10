//
//  ImageCacheManager.swift
//  Rivulet
//
//  Persistent image cache with weeks-long TTL and SSL support for Plex servers
//

import UIKit
import Foundation
import ImageIO

/// Cache entry metadata for tracking access times and TTL
struct ImageCacheEntry: Codable {
    let url: String
    let cachedAt: Date
    var lastAccessedAt: Date
    let fileSize: Int64
}

/// Actor-based image cache with disk persistence, LRU eviction, and SSL support
actor ImageCacheManager: NSObject {
    static let shared = ImageCacheManager()

    // MARK: - Configuration

    private let cacheDirectoryName = "PlexImageCache"
    private let metadataFileName = "image_cache_metadata.json"
    private let maxMemoryCacheCount = 100
    private let maxKeyCacheCount = 2048
    private let maxDiskCacheSize: Int64 = 5 * 1024 * 1024 * 1024  // 5GB
    private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60  // 2 weeks

    // MARK: - Caches

    private let memoryCache = NSCache<NSString, UIImage>()
    private let keyCache = NSCache<NSString, NSString>()
    private var cacheMetadata: [String: ImageCacheEntry] = [:]
    private var metadataLoaded = false

    // tvOS is always 2x scale - static for nonisolated access
    private static let screenScale: CGFloat = 2.0

    // MARK: - URL Session (with SSL handling)

    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session {
            return existing
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = newSession
        return newSession
    }

    // MARK: - Active Downloads (prevent duplicates)

    private var activeDownloads: [URL: Task<UIImage?, Never>] = [:]

    // MARK: - Cache Directory

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(cacheDirectoryName)
    }

    // MARK: - Initialization

    override private init() {
        super.init()
        memoryCache.countLimit = maxMemoryCacheCount
        keyCache.countLimit = maxKeyCacheCount
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

    /// Check memory cache only (for instant display without loading state).
    func cachedImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Cache key generation with memoization
    private func cacheKey(for url: URL) -> String {
        let urlKey = url.absoluteString as NSString
        if let cachedKey = keyCache.object(forKey: urlKey) {
            return cachedKey as String
        }
        let hashed = url.absoluteString.sha256Hash()
        keyCache.setObject(hashed as NSString, forKey: urlKey)
        return hashed
    }

    /// Get image from cache or download. Stale-while-revalidate: returns cached immediately, refreshes in background if stale.
    func image(for url: URL, forceRefresh: Bool = false) async -> UIImage? {
        let key = cacheKey(for: url)

        // 1. Check memory cache
        if !forceRefresh, let cached = memoryCache.object(forKey: key as NSString) {
            updateAccessTime(for: key)
            // Background refresh if stale
            Task.detached(priority: .low) { [weak self] in
                await self?.refreshIfStale(url: url, key: key)
            }
            return cached
        }

        // 2. Check disk cache (async to avoid blocking)
        if !forceRefresh, let diskImage = await loadFromDisk(key: key) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            updateAccessTime(for: key)
            Task.detached(priority: .low) { [weak self] in
                await self?.refreshIfStale(url: url, key: key)
            }
            return diskImage
        }

        // 3. Download
        return await download(url: url, key: key)
    }

    /// Get image at full resolution, fully decoded for display.
    /// Use for hero/background images that need full resolution (not downsampled to 400px).
    /// Guarantees decoding completes off the main thread to prevent app hangs.
    func imageFullSize(for url: URL, forceRefresh: Bool = false) async -> UIImage? {
        let key = cacheKey(for: url)

        // 1. Check memory cache
        if !forceRefresh, let cached = memoryCache.object(forKey: key as NSString) {
            updateAccessTime(for: key)
            return cached
        }

        // 2. Load from disk at full size (no downsampling)
        if !forceRefresh, let cacheDir = cacheDirectory {
            let diskImage = await Task.detached(priority: .userInitiated) { [cacheDir] in
                self.loadFromDiskFullSize(cacheDir: cacheDir, key: key)
            }.value

            if let image = diskImage {
                // Fully decode before caching to prevent main thread decode
                let decoded = await fullyDecodedImageAsync(image)
                memoryCache.setObject(decoded, forKey: key as NSString)
                updateAccessTime(for: key)
                return decoded
            }
        }

        // 3. Download (already uses async decoding)
        return await download(url: url, key: key)
    }

    /// Prefetch images in background (limited concurrency)
    /// Uses higher priority to ensure images are ready before user scrolls to them
    func prefetch(urls: [URL]) {
        Task.detached(priority: .utility) { [weak self] in
            // Limit to 30 URLs, 8 concurrent for faster prefetch
            let urlsToFetch = Array(urls.prefix(30))
            await withTaskGroup(of: Void.self) { group in
                var count = 0
                for url in urlsToFetch {
                    if count >= 8 {
                        await group.next()
                        count -= 1
                    }
                    group.addTask {
                        _ = await self?.image(for: url)
                    }
                    count += 1
                }
            }
        }
    }

    /// Clear all cached images
    func clearAll() async {
        memoryCache.removeAllObjects()
        cacheMetadata.removeAll()

        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveMetadata()
    }

    /// Get total disk cache size in bytes
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

    /// Get formatted cache size string
    func getFormattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Get raw image data for a URL (for Vision processing)
    /// Returns cached data or downloads if needed
    func imageData(for url: URL) async -> Data? {
        let key = cacheKey(for: url)

        // Check disk cache first
        if let cacheDir = cacheDirectory {
            let fileURL = cacheDir.appendingPathComponent(key)
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
        }

        // Download if not cached
        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Validate image data
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(imageSource) == .statusComplete,
                  CGImageSourceGetCount(imageSource) > 0 else {
                return nil
            }

            // Save to disk for future use
            await saveToDisk(data: data, key: key, url: url)

            return data
        } catch {
            return nil
        }
    }

    // MARK: - Private Implementation

    private func updateAccessTime(for key: String) {
        if var entry = cacheMetadata[key] {
            entry.lastAccessedAt = Date()
            cacheMetadata[key] = entry
            // Don't save immediately to avoid excessive I/O, will be saved on next write
        }
    }

    private func refreshIfStale(url: URL, key: String) async {
        await ensureMetadataLoaded()
        guard let entry = cacheMetadata[key] else { return }
        let age = Date().timeIntervalSince(entry.cachedAt)

        // Refresh if older than TTL
        if age > defaultTTL {
            _ = await download(url: url, key: key)
        }
    }

    private func download(url: URL, key: String) async -> UIImage? {
        // Coalesce duplicate requests
        if let existing = activeDownloads[url] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self = self else { return nil }

            defer {
                Task { await self.removeActiveDownload(for: url) }
            }

            do {
                let (data, response) = try await self.session.data(from: url)

                // Check for valid image response
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    return nil
                }

                // Validate image data is complete before caching
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetStatus(imageSource) == .statusComplete,
                      CGImageSourceGetCount(imageSource) > 0 else {
                    print("💾 ImageCacheManager: Received incomplete/corrupt image data from \(url.lastPathComponent)")
                    return nil
                }

                guard let image = UIImage(data: data) else { return nil }

                // Use async decoding to guarantee full decode off main thread
                let decoded = await self.fullyDecodedImageAsync(image)

                // Save to memory cache
                await self.saveToMemoryCache(image: decoded, key: key)

                // Save to disk
                await self.saveToDisk(data: data, key: key, url: url)

                return decoded
            } catch {
                print("💾 ImageCacheManager: Download failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }

        activeDownloads[url] = task
        return await task.value
    }

    private func removeActiveDownload(for url: URL) {
        activeDownloads.removeValue(forKey: url)
    }

    private func saveToMemoryCache(image: UIImage, key: String) {
        memoryCache.setObject(image, forKey: key as NSString)
    }

    // MARK: - Disk Operations

    /// Load image from disk - runs outside actor isolation for parallel access
    /// Uses downsampling for faster decode and lower memory usage
    nonisolated private func loadFromDiskSync(cacheDir: URL, key: String) -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Validate image data is complete using CGImageSource
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              CGImageSourceGetCount(imageSource) > 0 else {
            // Data is corrupt or incomplete - delete the cached file
            try? FileManager.default.removeItem(at: fileURL)
            print("💾 ImageCacheManager: Deleted corrupt cached image: \(key)")
            return nil
        }

        // Use GPU-efficient downsampling (400px max covers 220x330 poster cards at 2x scale)
        // This decodes directly at target size without allocating full-resolution buffers
        if let downsampled = downsampledImage(from: data, maxPixelSize: 400) {
            return downsampled
        }

        // Fallback to standard decoding if downsampling fails
        guard let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return decodedImage(image)
    }

    /// Load image from disk asynchronously without blocking the actor
    private func loadFromDisk(key: String) async -> UIImage? {
        guard let cacheDir = cacheDirectory else { return nil }

        // Run disk I/O completely outside actor isolation for true parallelism
        return await Task.detached(priority: .userInitiated) { [cacheDir] in
            self.loadFromDiskSync(cacheDir: cacheDir, key: key)
        }.value
    }

    /// Load full-size image from disk without 400px downsampling.
    /// Uses kCGImageSourceShouldCacheImmediately to force decode during load.
    nonisolated private func loadFromDiskFullSize(cacheDir: URL, key: String) -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              CGImageSourceGetCount(imageSource) > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        // Force immediate decode via CGImageSource (no size limit)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func saveToDisk(data: Data, key: String, url: URL) {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(key)

        do {
            try data.write(to: fileURL, options: .atomic)

            // Update metadata
            let entry = ImageCacheEntry(
                url: url.absoluteString,
                cachedAt: Date(),
                lastAccessedAt: Date(),
                fileSize: Int64(data.count)
            )
            cacheMetadata[key] = entry
            saveMetadata()

            // Check if we need to evict
            Task {
                await evictIfNeeded()
            }
        } catch {
            print("💾 ImageCacheManager: Failed to save image to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() async {
        let currentSize = getCacheSize()
        guard currentSize > maxDiskCacheSize else { return }

        // Sort by last accessed time (oldest first)
        let sortedEntries = cacheMetadata.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        var freedSpace: Int64 = 0
        let targetFreeSpace = currentSize - (maxDiskCacheSize * 8 / 10)  // Free up to 80% of max

        guard let cacheDir = cacheDirectory else { return }

        for (key, entry) in sortedEntries {
            if freedSpace >= targetFreeSpace { break }

            let fileURL = cacheDir.appendingPathComponent(key)
            do {
                try FileManager.default.removeItem(at: fileURL)
                freedSpace += entry.fileSize
                cacheMetadata.removeValue(forKey: key)
                memoryCache.removeObject(forKey: key as NSString)
            } catch {
                // File might already be gone
            }
        }

        saveMetadata()
    }

    // MARK: - Metadata Persistence

    private func ensureMetadataLoaded() async {
        if !metadataLoaded {
            loadMetadata()
        }
    }

    private func loadMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ImageCacheEntry].self, from: data) else {
            metadataLoaded = true
            return
        }

        cacheMetadata = decoded
        metadataLoaded = true
    }

    private func saveMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? JSONEncoder().encode(cacheMetadata) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Image Decoding

    nonisolated private func decodedImage(_ image: UIImage) -> UIImage {
        if #available(tvOS 15.0, iOS 15.0, *) {
            return image.preparingForDisplay() ?? image
        }
        return image
    }

    /// Fully decode image using async API - guarantees decoding completes off main thread
    /// Unlike preparingForDisplay() which may return before decoding completes,
    /// this uses the callback-based API wrapped in a continuation for guaranteed completion.
    nonisolated private func fullyDecodedImageAsync(_ image: UIImage) async -> UIImage {
        if #available(tvOS 15.0, iOS 15.0, *) {
            return await withCheckedContinuation { continuation in
                image.prepareForDisplay { decoded in
                    continuation.resume(returning: decoded ?? image)
                }
            }
        }
        return image
    }

    // MARK: - GPU-Efficient Downsampling

    /// Downsample image data to a target size using CGImageSource.
    /// This is significantly faster than decoding full resolution then scaling,
    /// as it decodes directly at the target size without allocating full-resolution buffers.
    nonisolated private func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // Don't cache the full-size version
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,  // Decode now (in background)
            kCGImageSourceCreateThumbnailWithTransform: true,  // Apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * Self.screenScale
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
    }

    /// Load and downsample image from disk for display
    /// For poster cards (220x330), we downsample to 330px max (the larger dimension)
    nonisolated private func loadFromDiskDownsampled(cacheDir: URL, key: String, maxPixelSize: CGFloat = 400) -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Try downsampled version first (much faster for large images)
        if let downsampled = downsampledImage(from: data, maxPixelSize: maxPixelSize) {
            return downsampled
        }

        // Fallback to standard decoding if downsampling fails
        guard let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return decodedImage(image)
    }
}

// MARK: - URLSessionDelegate (SSL Certificate Handling)

extension ImageCacheManager: URLSessionDelegate {
    /// Handle SSL certificate challenges for self-signed certificates (same as PlexNetworkManager)
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Trust self-signed certificates for:
        // - IP addresses (local Plex servers)
        // - plex.direct domains
        // - Port 32400 (default Plex port)
        let isIPAddress = host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
        let isPlexDirect = host.hasSuffix(".plex.direct")
        let isPlexPort = port == 32400

        if isIPAddress || isPlexDirect || isPlexPort {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
