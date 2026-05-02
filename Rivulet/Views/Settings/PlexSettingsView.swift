//
//  PlexSettingsView.swift
//  Rivulet
//
//  Plex server connection settings
//

import SwiftUI

struct PlexSettingsView: View {
    @Binding var focusedSettingId: String?
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var showAuthSheet = false
    @State private var switchingServerId: String?

    init(focusedSettingId: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
    }

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                authenticatedContent
            } else {
                SettingsActionRow(
                    title: "Connect to Plex",
                    action: { showAuthSheet = true },
                    onFocusChange: { if $0 { focusedSettingId = "connectPlex" } }
                )
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            PlexAuthView()
        }
        .task(id: authManager.authToken) {
            guard authManager.isAuthenticated,
                  authManager.availableServers.isEmpty else { return }
            await authManager.refreshAvailableServers()
        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        SettingsInfoRow(title: "Signed In", value: authManager.username ?? "Plex")
        SettingsInfoRow(title: "Current Server", value: currentServerName)

        if authManager.isLoadingServers && authManager.availableServers.isEmpty {
            ProgressView("Loading servers...")
        } else if authManager.availableServers.isEmpty {
            Text("No Plex servers found for this account.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            ForEach(authManager.availableServers, id: \.clientIdentifier) { server in
                PlexServerSettingsRow(
                    server: server,
                    isSelected: authManager.isActiveServer(server),
                    isLoading: switchingServerId == server.clientIdentifier,
                    onSelect: { selectServer(server) },
                    onFocusChange: { if $0 { focusedSettingId = "plexServer_\(server.clientIdentifier)" } }
                )
            }
        }

        if let error = authManager.connectionError, !error.isEmpty {
            Text(error)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }

        SettingsActionRow(
            title: authManager.isLoadingServers ? "Refreshing Servers..." : "Refresh Servers",
            action: { refreshServers() },
            onFocusChange: { if $0 { focusedSettingId = "refreshServers" } }
        )

        SettingsActionRow(
            title: "Sign Out",
            isDestructive: true,
            action: { authManager.signOut() },
            onFocusChange: { if $0 { focusedSettingId = "signOut" } }
        )
    }

    private var currentServerName: String {
        authManager.selectedServer?.name ?? authManager.savedServerName ?? "Unknown"
    }

    private func refreshServers() {
        Task {
            await authManager.refreshAvailableServers()
        }
    }

    private func selectServer(_ server: PlexDevice) {
        guard switchingServerId == nil else { return }

        Task {
            switchingServerId = server.clientIdentifier
            _ = await authManager.switchServer(server)
            switchingServerId = nil
        }
    }
}

private struct PlexServerSettingsRow: View {
    let server: PlexDevice
    let isSelected: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    var onFocusChange: ((Bool) -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 20) {
                PlexServerAvatar(server: server, size: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.system(size: 32))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)

                    Text(summaryText)
                        .font(.system(size: 22))
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                trailingAccessory
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isLoading {
            ProgressView()
        } else if isSelected {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                Text("Current")
                    .font(.system(size: 28, weight: .semibold))
            }
            .foregroundStyle(isFocused ? .black.opacity(0.65) : .green)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(isFocused ? .black.opacity(0.6) : .secondary)
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        parts.append(server.owned == true ? "Owned" : "Shared")

        if let presence = server.presence {
            parts.append(presence ? "Online" : "Offline")
        }

        let connections = server.connections ?? []
        if connections.contains(where: { $0.local && !$0.relay }) {
            parts.append("Local")
        }
        if connections.contains(where: { !$0.local && !$0.relay }) {
            parts.append("Remote")
        }
        if connections.contains(where: \.relay) {
            parts.append("Relay")
        }
        if server.httpsRequired == true {
            parts.append("Secure")
        }

        if parts.count == 1, !server.productVersion.isEmpty {
            parts.append(server.productVersion)
        }

        return parts.joined(separator: " · ")
    }
}

private struct PlexServerAvatar: View {
    let server: PlexDevice
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(serverColor.gradient)

                Text(serverInitials)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 2)
            )

            Image(systemName: statusIcon)
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size * 0.34, height: size * 0.34)
                .background(statusColor.gradient)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.black.opacity(0.35), lineWidth: 2)
                )
                .offset(x: size * 0.04, y: size * 0.04)
        }
        .frame(width: size, height: size)
    }

    private var serverInitials: String {
        let words = server.name
            .split(separator: " ")
            .filter { !$0.isEmpty }

        let initials = words
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()

        return initials.isEmpty ? "P" : initials
    }

    private var statusIcon: String {
        if server.presence == false {
            return "xmark"
        }
        if server.connections?.contains(where: { $0.local && !$0.relay }) == true {
            return "house.fill"
        }
        if server.connections?.contains(where: { !$0.local && !$0.relay }) == true {
            return "globe"
        }
        if server.connections?.contains(where: \.relay) == true {
            return "arrow.triangle.2.circlepath"
        }
        return "server.rack"
    }

    private var statusColor: Color {
        if server.presence == false {
            return .gray
        }
        if server.connections?.contains(where: { $0.local && !$0.relay }) == true {
            return .green
        }
        if server.connections?.contains(where: { !$0.local && !$0.relay }) == true {
            return .blue
        }
        if server.connections?.contains(where: \.relay) == true {
            return .orange
        }
        return .secondary
    }

    private var serverColor: Color {
        let colors: [Color] = [.orange, .blue, .purple, .teal, .indigo, .pink, .green]
        let hash = server.clientIdentifier.unicodeScalars.reduce(0) { partial, scalar in
            abs((partial &* 31) &+ Int(scalar.value))
        }
        return colors[hash % colors.count]
    }
}

#Preview {
    PlexSettingsView()
}
