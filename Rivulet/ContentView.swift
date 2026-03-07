//
//  ContentView.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Combine
import os.log

private let splashLog = Logger(subsystem: "com.rivulet.app", category: "Splash")

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    #if DEBUG
    @State private var showSplash = false
    #else
    @State private var showSplash = true
    #endif

    var body: some View {
        TVSidebarView()
            .overlay {
                if showSplash {
                    splashOverlay
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
        .onChange(of: authManager.hasCredentials) { _, hasCredentials in
            splashLog.info("hasCredentials changed to \(hasCredentials)")
            if !hasCredentials {
                splashLog.info("No credentials — dismissing splash")
                showSplash = false
            }
        }
        .onChange(of: dataStore.isHomeContentReady) { _, isReady in
            splashLog.info("isHomeContentReady changed to \(isReady), showSplash=\(self.showSplash)")
            if isReady {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    splashLog.info("Debounce complete — isHomeContentReady=\(self.dataStore.isHomeContentReady), showSplash=\(self.showSplash)")
                    if dataStore.isHomeContentReady {
                        splashLog.info("Dismissing splash — home content ready")
                        showSplash = false
                    }
                }
            }
        }
        .task {
            splashLog.info("Splash task started — hasCredentials=\(self.authManager.hasCredentials)")
            if !authManager.hasCredentials {
                splashLog.info("No credentials on launch — dismissing splash immediately")
                showSplash = false
                return
            }
            // Safety timeout
            try? await Task.sleep(for: .seconds(15))
            if showSplash {
                splashLog.warning("Safety timeout reached (15s) — force dismissing splash")
                showSplash = false
            }
        }
    }

    private var splashOverlay: some View {
        ZStack {
            VStack(spacing: 24) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.6))

                ProgressView()
                    .tint(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .allowsHitTesting(true)
    }
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
