//
//  ContentView.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    #if os(tvOS)
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var showSplash = true
    #endif

    var body: some View {
        #if os(tvOS)
        ZStack {
            TVSidebarView()

            if showSplash {
                splashOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: showSplash)
        .onChange(of: authManager.hasCredentials) { _, hasCredentials in
            if !hasCredentials {
                showSplash = false
            }
        }
        .onChange(of: dataStore.hubs.isEmpty) { _, isEmpty in
            if !isEmpty {
                // Debounce: hubs can briefly appear then reset during profile/reload cycles.
                // Wait a beat to confirm they're stable before dismissing.
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !dataStore.hubs.isEmpty {
                        showSplash = false
                    }
                }
            }
        }
        .task {
            // Dismiss immediately if not authenticated
            if !authManager.hasCredentials {
                showSplash = false
                return
            }
            // Safety timeout
            try? await Task.sleep(for: .seconds(8))
            if showSplash {
                showSplash = false
            }
        }
        #else
        NavigationSplitViewContent()
        #endif
    }

    #if os(tvOS)
    private var splashOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.6))

                ProgressView()
                    .tint(.white.opacity(0.5))
            }
        }
        .allowsHitTesting(true)
    }
    #endif
}

// MARK: - macOS/iOS Split View Navigation

struct NavigationSplitViewContent: View {
    @State private var selectedSection: SidebarSection? = .settings

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedSection: $selectedSection)
        } detail: {
            switch selectedSection {
            case .plexSearch:
                PlexSearchView()
            case .plexHome:
                PlexHomeView()
            case .plexLibrary(let key, let title):
                PlexLibraryView(libraryKey: key, libraryTitle: title)
            case .liveTVChannels:
                ChannelListView()
            case .liveTVGuide:
                GuideLayoutView()
            case .settings:
                SettingsView()
            case .none:
                ContentUnavailableView(
                    "Select a Section",
                    systemImage: "tv",
                    description: Text("Choose from the sidebar to get started")
                )
            }
        }
    }
}

// MARK: - Placeholder Views (to be implemented in Phase 6)

struct EPGGridView: View {
    var body: some View {
        ContentUnavailableView(
            "TV Guide",
            systemImage: "calendar",
            description: Text("Electronic Program Guide will appear here")
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ], inMemory: true)
}
