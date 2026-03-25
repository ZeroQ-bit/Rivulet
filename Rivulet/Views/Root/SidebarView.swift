//
//  SidebarView.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData

/// Sidebar navigation sections (used on macOS/iOS)
enum SidebarSection: Hashable {
    // Plex sections
    case plexSearch
    case plexHome
    case plexLibrary(key: String, title: String)

    // Live TV sections
    case liveTVChannels
    case liveTVGuide

    // Settings
    case settings
}

/// Sidebar view for macOS/iOS (tvOS uses TabView instead)
struct SidebarView: View {
    @Binding var selectedSection: SidebarSection?
    @Query private var serverConfigs: [ServerConfiguration]
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared

    /// Check if Plex is authenticated
    private var hasPlexServer: Bool {
        authManager.isAuthenticated
    }

    /// Check if IPTV is configured
    private var hasIPTV: Bool {
        serverConfigs.contains {
            ($0.serverType == .dispatcharr || $0.serverType == .genericIPTV)
            && $0.iptvSource != nil
        }
    }

    /// Get Plex server name
    private var plexServerName: String {
        authManager.savedServerName ?? "Plex"
    }

    var body: some View {
        List(selection: $selectedSection) {
            // MARK: - Plex Section
            if hasPlexServer {
                Section {
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(SidebarSection.plexSearch)

                    Label("Home", systemImage: "house.fill")
                        .tag(SidebarSection.plexHome)

                    // Dynamic library sections (video and music libraries)
                    ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                        Label(library.title, systemImage: iconForLibrary(library))
                            .tag(SidebarSection.plexLibrary(key: library.key, title: library.title))
                    }

                    if dataStore.isLoadingLibraries {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label(plexServerName, systemImage: "server.rack")
                }
            }

            // MARK: - Live TV Section
            if hasIPTV {
                Section {
                    Label("Channels", systemImage: "tv")
                        .tag(SidebarSection.liveTVChannels)

                    Label("Guide", systemImage: "calendar")
                        .tag(SidebarSection.liveTVGuide)
                } header: {
                    Label("Live TV", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            // MARK: - Settings Section
            Section {
                Label("Settings", systemImage: "gear")
                    .tag(SidebarSection.settings)
            }

            // MARK: - Setup Prompt (when nothing configured)
            if !hasPlexServer && !hasIPTV {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Welcome to Rivulet")
                            .font(.headline)

                        Text("Add a Plex server or IPTV source in Settings to get started.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            if authManager.isAuthenticated {
                await dataStore.loadLibrariesIfNeeded()
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task {
                    await dataStore.loadLibrariesIfNeeded()
                }
            } else {
                dataStore.reset()
            }
        }
    }

    private func iconForLibrary(_ library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo"
        default: return "folder"
        }
    }
}

#Preview {
    @Previewable @State var selection: SidebarSection? = .plexHome

    NavigationSplitView {
        SidebarView(selectedSection: $selection)
    } detail: {
        Text("Select an item")
    }
    .modelContainer(for: ServerConfiguration.self, inMemory: true)
}
