//
//  CacheSettingsView.swift
//  Rivulet
//
//  Cache management and storage settings for tvOS
//

import SwiftUI

struct CacheSettingsView: View {
    @Binding var focusedSettingId: String?
    @State private var imageCacheSize: Int64 = 0
    @State private var metadataCacheSize: Int64 = 0
    @State private var isLoadingSizes = true
    @State private var isClearing = false
    @State private var showClearConfirmation = false
    @State private var showRefreshConfirmation = false

    private let cacheManager = CacheManager.shared

    init(focusedSettingId: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
    }

    var body: some View {
        VStack(spacing: 24) {
            SettingsSection(title: "Storage Usage") {
                cacheInfoRow(
                    title: "Image Cache",
                    subtitle: "Poster and backdrop images",
                    size: imageCacheSize,
                    isLoading: isLoadingSizes
                )

                cacheInfoRow(
                    title: "Metadata Cache",
                    subtitle: "Library and media information",
                    size: metadataCacheSize,
                    isLoading: isLoadingSizes
                )

                Divider()
                    .background(.white.opacity(0.1))
                    .padding(.horizontal, 20)

                totalCacheRow
            }

            SettingsSection(title: "Actions") {
                SettingsActionRow(title: "Force Refresh Libraries") {
                    showRefreshConfirmation = true
                }

                SettingsActionRow(title: "Clear All Cache", isDestructive: true) {
                    showClearConfirmation = true
                }
            }

            // Info text
            Text("Clearing the cache will remove all cached images and metadata. Content will be re-downloaded as needed.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
        }
        .task {
            await loadCacheSizes()
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearAllCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached images and metadata. Content will need to be re-downloaded.")
        }
        .confirmationDialog(
            "Force Refresh Libraries?",
            isPresented: $showRefreshConfirmation,
            titleVisibility: .visible
        ) {
            Button("Refresh") {
                Task { await forceRefreshLibraries() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear metadata cache and reload all library content from your Plex server.")
        }
    }

    // MARK: - Cache Info Row

    private func cacheInfoRow(title: String, subtitle: String, size: Int64, isLoading: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(formatBytes(size))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var totalCacheRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Total")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)

                Text("All cached data")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            if isLoadingSizes {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(formatBytes(imageCacheSize + metadataCacheSize))
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Data Loading

    private func loadCacheSizes() async {
        isLoadingSizes = true

        // Get image cache size
        imageCacheSize = await ImageCacheManager.shared.getCacheSize()

        // Get metadata cache size
        metadataCacheSize = await cacheManager.getCacheSize()

        isLoadingSizes = false
    }

    private func clearAllCache() async {
        isClearing = true

        // Clear image cache
        await ImageCacheManager.shared.clearAll()

        // Clear metadata cache
        await cacheManager.clearAllCache()

        // Reload sizes
        await loadCacheSizes()

        isClearing = false
    }

    private func forceRefreshLibraries() async {
        isClearing = true

        // Only clear metadata cache (keep images)
        await cacheManager.clearAllCache()

        // Reload sizes
        await loadCacheSizes()

        isClearing = false
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    CacheSettingsView()
}
