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
        Group {
            if authManager.isAuthenticated {
                SettingsActionRow(
                    title: "Sign Out",
                    isDestructive: true,
                    action: { authManager.signOut() },
                    onFocusChange: { if $0 { focusedSettingId = "signOut" } }
                )
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
    }
}

#Preview {
    PlexSettingsView()
}
