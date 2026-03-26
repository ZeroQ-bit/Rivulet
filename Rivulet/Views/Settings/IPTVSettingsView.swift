//
//  IPTVSettingsView.swift
//  Rivulet
//
//  Live TV source settings - manages Plex Live TV and M3U sources
//

import SwiftUI

struct IPTVSettingsView: View {
    @Binding var focusedSettingId: String?
    var onNavigateToSource: ((LiveTVDataStore.LiveTVSourceInfo) -> Void)?
    var onNavigateToAddSource: (() -> Void)?
    @StateObject private var dataStore = LiveTVDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var plexDVRAvailable: Bool = false
    @State private var isCheckingPlexDVR: Bool = false
    @State private var isAddingPlexLiveTV: Bool = false
    @State private var plexAddError: String?

    init(
        focusedSettingId: Binding<String?> = .constant(nil),
        onNavigateToSource: ((LiveTVDataStore.LiveTVSourceInfo) -> Void)? = nil,
        onNavigateToAddSource: (() -> Void)? = nil
    ) {
        self._focusedSettingId = focusedSettingId
        self.onNavigateToSource = onNavigateToSource
        self.onNavigateToAddSource = onNavigateToAddSource
    }

    var body: some View {
        Group {
            ForEach(dataStore.sources) { source in
                LiveTVSourceRow(
                    source: source,
                    action: { onNavigateToSource?(source) },
                    onFocusChange: { if $0 { focusedSettingId = descriptorKey(for: source) } }
                )
            }

            SettingsRow(
                icon: "plus",
                iconColor: .blue,
                title: "Add Live TV Source",
                subtitle: "",
                action: { onNavigateToAddSource?() },
                onFocusChange: { if $0 { focusedSettingId = "addLiveTVSource" } }
            )

            if authManager.isAuthenticated && !hasPlexLiveTVSource && plexDVRAvailable {
                PlexLiveTVHintRow(
                    isLoading: isAddingPlexLiveTV,
                    errorMessage: plexAddError,
                    action: { addPlexLiveTV() },
                    onFocusChange: { if $0 { focusedSettingId = "plexLiveTVHint" } }
                )
            }
        }
        .task {
            await checkPlexDVRAvailability()
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                Task {
                    await checkPlexDVRAvailability()
                }
            } else {
                plexDVRAvailable = false
            }
        }
    }

    // MARK: - Helpers

    private func descriptorKey(for source: LiveTVDataStore.LiveTVSourceInfo) -> String {
        switch source.sourceType {
        case .plex: return "plexLiveTVSource"
        case .dispatcharr: return "dispatcharrSource"
        case .genericM3U: return "m3uSource"
        }
    }

    // MARK: - Plex DVR Check

    private func checkPlexDVRAvailability() async {
        guard authManager.isAuthenticated,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              !hasPlexLiveTVSource else {
            plexDVRAvailable = false
            return
        }

        isCheckingPlexDVR = true

        let isAvailable = await PlexLiveTVProvider.checkAvailability(
            serverURL: serverURL,
            authToken: token
        )

        await MainActor.run {
            plexDVRAvailable = isAvailable
            isCheckingPlexDVR = false
        }
    }

    // MARK: - Auto-Add Plex Live TV

    private func addPlexLiveTV() {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let serverName = authManager.savedServerName else {
            plexAddError = "Plex server not connected"
            return
        }

        isAddingPlexLiveTV = true
        plexAddError = nil

        Task {
            let provider = PlexLiveTVProvider(
                serverURL: serverURL,
                authToken: token,
                serverName: serverName
            )

            await dataStore.addPlexSource(provider: provider)
            await dataStore.loadChannels()
            await dataStore.loadEPG(startDate: Date(), hours: 6)

            await MainActor.run {
                isAddingPlexLiveTV = false
            }
        }
    }

    private var hasPlexLiveTVSource: Bool {
        dataStore.sources.contains { $0.sourceType == .plex }
    }
}

// MARK: - Live TV Source Row

struct LiveTVSourceRow: View {
    let source: LiveTVDataStore.LiveTVSourceInfo
    let action: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    private var iconName: String {
        switch source.sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    private var iconColor: Color {
        switch source.sourceType {
        case .plex: return .orange
        case .dispatcharr: return .blue
        case .genericM3U: return .green
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 64, height: 64)

                    Image(systemName: iconName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.system(size: 32))

                    HStack(spacing: 10) {
                        Circle()
                            .fill(source.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)

                        Text(source.isConnected ? "Connected" : "Disconnected")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)

                        if source.channelCount > 0 {
                            Text("\u{2022}")
                                .foregroundStyle(.secondary)
                            Text("\(source.channelCount) channels")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
    }
}

// MARK: - Plex Live TV Hint Row

private struct PlexLiveTVHintRow: View {
    let isLoading: Bool
    let errorMessage: String?
    let action: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.orange.gradient)
                        .frame(width: 64, height: 64)

                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "tv.and.mediabox")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isLoading ? "Adding Plex Live TV..." : "Plex Live TV Available")
                        .font(.system(size: 32))

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                    } else {
                        Text(isLoading ? "Setting up channels" : "Tap to add from your server")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !isLoading {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(isLoading)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
    }
}

#Preview {
    IPTVSettingsView()
}
