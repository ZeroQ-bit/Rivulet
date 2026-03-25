//
//  CacheSettingsView.swift
//  Rivulet
//
//  Cache management and storage settings for tvOS
//

import SwiftUI

struct CacheSettingsView: View {
    @Binding var focusedSettingId: String?
    @Binding var focusedSubtext: String?
    @State private var showClearConfirmation = false
    @State private var showRefreshConfirmation = false

    private let cacheManager = CacheManager.shared

    init(focusedSettingId: Binding<String?> = .constant(nil), focusedSubtext: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
        self._focusedSubtext = focusedSubtext
    }

    var body: some View {
        Group {
            SettingsActionRow(
                title: "Force Refresh Libraries",
                action: { showRefreshConfirmation = true },
                onFocusChange: { if $0 { focusedSettingId = "forceRefresh" } }
            )

            SettingsActionRow(
                title: "Clear All Cache",
                isDestructive: true,
                action: { showClearConfirmation = true },
                onFocusChange: { if $0 { focusedSettingId = "clearAllCache" } }
            )
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await clearAllCache()
                    await loadCacheSizes()
                }
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
                Task {
                    await forceRefreshLibraries()
                    await loadCacheSizes()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear metadata cache and reload all library content from your Plex server.")
        }
        .task {
            await loadCacheSizes()
        }
        .onDisappear {
            focusedSubtext = nil
        }
    }

    // MARK: - Actions

    private func clearAllCache() async {
        await ImageCacheManager.shared.clearAll()
        await cacheManager.clearAllCache()
    }

    private func forceRefreshLibraries() async {
        await cacheManager.clearAllCache()
    }

    private func loadCacheSizes() async {
        let metadataSize = await cacheManager.getFormattedCacheSize()
        let imageSize = await ImageCacheManager.shared.getFormattedCacheSize()
        focusedSubtext = "Metadata: \(metadataSize)  ·  Images: \(imageSize)"
    }
}

#Preview {
    CacheSettingsView()
}
