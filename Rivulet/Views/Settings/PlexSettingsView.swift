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

    init(focusedSettingId: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
    }

    var body: some View {
        VStack(spacing: 24) {
            if authManager.isAuthenticated {
                // Connected server card
                SettingsSection(title: "Connected Server") {
                    HStack(spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.green.gradient)
                                .frame(width: 64, height: 64)

                            Image(systemName: "checkmark")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(authManager.savedServerName ?? "Plex Server")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)

                            if let username = authManager.username {
                                Text("Signed in as \(username)")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }

                // Connection details
                if let serverURL = authManager.selectedServerURL {
                    SettingsSection(title: "Connection") {
                        SettingsInfoRow(title: "Server URL", value: serverURL)
                    }
                }

                // Sign out
                SettingsSection(title: "Account") {
                    SettingsActionRow(
                        title: "Sign Out",
                        isDestructive: true
                    ) {
                        authManager.signOut()
                    }
                }
            } else {
                // Not connected
                VStack(spacing: 32) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 80, weight: .thin))
                        .foregroundStyle(.white.opacity(0.5))

                    VStack(spacing: 12) {
                        Text("No Server Connected")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("Connect to your Plex server to browse and stream your media library.")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 550)
                    }

                    ConnectButton {
                        showAuthSheet = true
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            PlexAuthView()
        }
    }
}

#Preview {
    PlexSettingsView()
}
