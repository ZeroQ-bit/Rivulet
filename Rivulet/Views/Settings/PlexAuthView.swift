//
//  PlexAuthView.swift
//  Rivulet
//
//  PIN-based Plex authentication UI for tvOS
//

import SwiftUI

struct PlexAuthView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Centered modal card
            VStack(spacing: 32) {
                switch authManager.state {
                case .idle:
                    loadingView(message: "Connecting to Plex...")

                case .requestingPin:
                    loadingView(message: "Requesting PIN...")

                case .waitingForPIN(let code, _):
                    pinDisplayView(code: code)

                case .selectingServer(let servers):
                    serverSelectionView(servers: servers)

                case .authenticated:
                    successView

                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding(48)
            .frame(maxWidth: 700)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        .task {
            if case .idle = authManager.state {
                await authManager.startPINAuthentication()
            }
        }
    }

    // MARK: - PIN Display

    private func pinDisplayView(code: String) -> some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Text("Visit")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)

                Text("plex.tv/link")
                    .font(.system(size: 38, weight: .bold, design: .rounded))

                Text("and enter this code:")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }

            // PIN Code Display
            HStack(spacing: 14) {
                ForEach(Array(code), id: \.self) { char in
                    Text(String(char))
                        .font(.system(size: 52, weight: .bold, design: .monospaced))
                        .frame(width: 64, height: 80)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.blue.opacity(0.2))
                        )
                }
            }

            // Loading indicator
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for authentication...")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Button("Cancel") {
                authManager.cancelAuthentication()
                dismiss()
            }
            #if os(tvOS)
            .buttonStyle(AppStoreButtonStyle())
            #else
            .buttonStyle(.bordered)
            #endif
        }
    }

    // MARK: - Server Selection

    private func serverSelectionView(servers: [PlexDevice]) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Select Your Server")
                .font(.system(size: 32, weight: .bold))

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(servers, id: \.clientIdentifier) { server in
                        ServerRowButton(server: server) {
                            Task {
                                await authManager.selectServer(server)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            Button("Cancel") {
                authManager.reset()
                dismiss()
            }
            #if os(tvOS)
            .buttonStyle(AppStoreButtonStyle())
            #else
            .buttonStyle(.bordered)
            #endif
        }
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Connected!")
                .font(.system(size: 32, weight: .bold))

            if let serverName = authManager.savedServerName {
                Text("Connected to \(serverName)")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }

            if let username = authManager.username {
                Text("Signed in as \(username)")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)

            Text("Connection Failed")
                .font(.system(size: 28, weight: .bold))

            Text(message)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Try Again") {
                Task {
                    await authManager.startPINAuthentication()
                }
            }
            #if os(tvOS)
            .buttonStyle(AppStoreButtonStyle())
            #else
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    // MARK: - Loading View

    private func loadingView(message: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)

            Text(message)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 120)
    }
}

// MARK: - Server Row Button

struct ServerRowButton: View {
    let server: PlexDevice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 20, weight: .semibold))

                    HStack(spacing: 8) {
                        if server.owned == true {
                            Label("Owned", systemImage: "person.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                        }

                        if let conn = server.connections?.first {
                            Text(conn.local ? "Local" : "Remote")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    PlexAuthView()
}
