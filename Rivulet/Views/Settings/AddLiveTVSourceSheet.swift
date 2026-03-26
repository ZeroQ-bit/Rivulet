//
//  AddLiveTVSourceSheet.swift
//  Rivulet
//
//  Inline settings views for adding Live TV sources
//

import SwiftUI

// MARK: - Source Type Picker (inline settings page)

struct AddLiveTVSourcePickerView: View {
    @Binding var focusedSettingId: String?
    var onNavigate: (SettingsPage) -> Void

    @StateObject private var authManager = PlexAuthManager.shared
    @State private var isCheckingPlex = false
    @State private var plexError: String?

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                SettingsRow(
                    icon: "play.rectangle.fill",
                    iconColor: .orange,
                    title: isCheckingPlex ? "Checking..." : "Plex Live TV",
                    subtitle: "",
                    action: { checkPlexLiveTV() },
                    onFocusChange: { if $0 { focusedSettingId = "addPlexLiveTV" } }
                )
            }

            SettingsRow(
                icon: "server.rack",
                iconColor: .blue,
                title: "M3U Server",
                subtitle: "",
                action: { onNavigate(.addDispatcharrSource) },
                onFocusChange: { if $0 { focusedSettingId = "addDispatcharrSource" } }
            )

            SettingsRow(
                icon: "list.bullet.rectangle",
                iconColor: .green,
                title: "M3U Playlist",
                subtitle: "",
                action: { onNavigate(.addM3USource) },
                onFocusChange: { if $0 { focusedSettingId = "addM3USource" } }
            )
        }
    }

    private func checkPlexLiveTV() {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            plexError = "Plex server not connected"
            return
        }

        isCheckingPlex = true
        plexError = nil

        Task {
            let isAvailable = await PlexLiveTVProvider.checkAvailability(
                serverURL: serverURL,
                authToken: token
            )

            await MainActor.run {
                isCheckingPlex = false
                if isAvailable {
                    onNavigate(.addPlexLiveTV)
                } else {
                    plexError = "Plex Live TV is not available on this server."
                }
            }
        }
    }
}

// MARK: - Add Plex Live TV (inline settings page)

struct AddPlexLiveTVSettingsView: View {
    @Binding var focusedSettingId: String?
    var onComplete: () -> Void

    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var isAdding = false

    var body: some View {
        Group {
            if let serverName = authManager.savedServerName {
                HStack {
                    Text("Server")
                        .font(.system(size: 32))
                    Spacer()
                    Text(serverName)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            SettingsActionRow(
                title: isAdding ? "Adding..." : "Add Plex Live TV",
                action: { addPlexLiveTV() },
                onFocusChange: { if $0 { focusedSettingId = "addPlexConfirm" } }
            )
            .disabled(isAdding)
        }
    }

    private func addPlexLiveTV() {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let serverName = authManager.savedServerName else { return }

        isAdding = true

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
                isAdding = false
                onComplete()
            }
        }
    }
}

// MARK: - Add Dispatcharr/M3U Server (inline settings page)

struct AddDispatcharrSettingsView: View {
    @Binding var focusedSettingId: String?
    var onComplete: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var serverURL = ""
    @State private var displayName = "Live TV"
    @State private var apiToken = ""
    @State private var isAdding = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var validationStatus: ValidationStatus = .idle

    enum ValidationStatus: Equatable {
        case idle, validating
        case valid(channelCount: Int)
        case invalid(String)
    }

    private var baseHost: String {
        if let plexURLString = authManager.selectedServerURL,
           let plexURL = URL(string: plexURLString),
           let host = plexURL.host,
           isLocalIP(host) {
            return host
        }
        return "192.168.1.100"
    }

    private func isLocalIP(_ host: String) -> Bool {
        host.hasPrefix("192.168.") || host.hasPrefix("10.") ||
        host.hasPrefix("172.16.") || host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") || host.hasPrefix("172.19.") ||
        host.hasPrefix("172.2") || host.hasPrefix("172.30.") ||
        host.hasPrefix("172.31.") || host == "localhost" || host == "127.0.0.1"
    }

    private var serverSuggestions: [TextEntrySuggestion] {
        [
            TextEntrySuggestion("Dispatcharr", value: "http://\(baseHost):9191"),
            TextEntrySuggestion("Threadfin", value: "http://\(baseHost):34400"),
            TextEntrySuggestion("xTeVe", value: "http://\(baseHost):34400"),
            TextEntrySuggestion("ErsatzTV", value: "http://\(baseHost):8409"),
            TextEntrySuggestion("Cabernet", value: "http://\(baseHost):6077"),
        ]
    }

    var body: some View {
        Group {
            SettingsTextEntryRow(
                icon: "globe",
                iconColor: .blue,
                title: "Server URL",
                value: $serverURL,
                placeholder: "http://\(baseHost):9191",
                hint: "Base URL (expects /output/m3u and /output/epg)",
                suggestions: serverSuggestions,
                keyboardType: .URL,
                onFocusChange: { if $0 { focusedSettingId = "serverURL" } }
            )

            SettingsTextEntryRow(
                icon: "textformat",
                iconColor: .purple,
                title: "Display Name",
                value: $displayName,
                placeholder: "Live TV",
                onFocusChange: { if $0 { focusedSettingId = "displayNameField" } }
            )

            SettingsTextEntryRow(
                icon: "key",
                iconColor: .orange,
                title: "API Token",
                value: $apiToken,
                placeholder: "Optional",
                onFocusChange: { if $0 { focusedSettingId = "apiTokenField" } }
            )

            SettingsActionRow(
                title: validationLabel,
                action: { validateServer() },
                onFocusChange: { if $0 { focusedSettingId = "validateServer" } }
            )
            .disabled(serverURL.isEmpty || isValidating)

            SettingsActionRow(
                title: isAdding ? "Adding..." : "Add Source",
                action: { addDispatcharr() },
                onFocusChange: { if $0 { focusedSettingId = "addSourceConfirm" } }
            )
            .disabled(serverURL.isEmpty || displayName.isEmpty || isAdding)
        }
    }

    private var validationLabel: String {
        switch validationStatus {
        case .idle: return "Validate"
        case .validating: return "Checking..."
        case .valid(let count): return "Valid — \(count) channels"
        case .invalid(let msg): return "Failed: \(msg)"
        }
    }

    private func validateServer() {
        let cleanedURL = sanitizeURL(serverURL)
        guard let service = DispatcharrService.create(from: cleanedURL, apiToken: apiToken.isEmpty ? nil : apiToken) else {
            validationStatus = .invalid("Invalid URL")
            return
        }

        validationStatus = .validating
        isValidating = true

        Task {
            do {
                let channels = try await service.fetchChannels()
                await MainActor.run {
                    validationStatus = .valid(channelCount: channels.count)
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationStatus = .invalid(error.localizedDescription)
                    isValidating = false
                }
            }
        }
    }

    private func addDispatcharr() {
        let cleanedURL = sanitizeURL(serverURL)
        guard let url = URL(string: cleanedURL) else {
            errorMessage = "Invalid URL"
            return
        }

        isAdding = true

        Task {
            await dataStore.addDispatcharrSource(
                baseURL: url,
                name: displayName.isEmpty ? "Live TV" : displayName,
                apiToken: apiToken.isEmpty ? nil : apiToken
            )
            await dataStore.loadChannels()
            await dataStore.loadEPG(startDate: Date(), hours: 6)

            await MainActor.run {
                isAdding = false
                onComplete()
            }
        }
    }
}

// MARK: - Add M3U Playlist (inline settings page)

struct AddM3USettingsView: View {
    @Binding var focusedSettingId: String?
    var onComplete: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var m3uURL = ""
    @State private var epgURL = ""
    @State private var displayName = "IPTV"
    @State private var isAdding = false

    var body: some View {
        Group {
            SettingsTextEntryRow(
                icon: "list.bullet.rectangle",
                iconColor: .green,
                title: "M3U Playlist URL",
                value: $m3uURL,
                placeholder: "http://example.com/playlist.m3u",
                hint: "URL to your M3U or M3U8 playlist",
                keyboardType: .URL,
                onFocusChange: { if $0 { focusedSettingId = "m3uURLField" } }
            )

            SettingsTextEntryRow(
                icon: "calendar",
                iconColor: .orange,
                title: "EPG URL (Optional)",
                value: $epgURL,
                placeholder: "http://example.com/epg.xml",
                hint: "XMLTV format for program guide",
                keyboardType: .URL,
                onFocusChange: { if $0 { focusedSettingId = "epgURLField" } }
            )

            SettingsTextEntryRow(
                icon: "textformat",
                iconColor: .purple,
                title: "Display Name",
                value: $displayName,
                placeholder: "IPTV",
                onFocusChange: { if $0 { focusedSettingId = "displayNameField" } }
            )

            SettingsActionRow(
                title: isAdding ? "Adding..." : "Add Source",
                action: { addM3U() },
                onFocusChange: { if $0 { focusedSettingId = "addSourceConfirm" } }
            )
            .disabled(m3uURL.isEmpty || isAdding)
        }
    }

    private func addM3U() {
        let cleanedM3U = sanitizeURL(m3uURL)
        guard let m3u = URL(string: cleanedM3U) else { return }

        var epg: URL? = nil
        if !epgURL.isEmpty {
            epg = URL(string: sanitizeURL(epgURL))
        }

        isAdding = true

        Task {
            await dataStore.addM3USource(
                m3uURL: m3u,
                epgURL: epg,
                name: displayName.isEmpty ? "IPTV" : displayName
            )
            await dataStore.loadChannels()
            await dataStore.loadEPG(startDate: Date(), hours: 6)

            await MainActor.run {
                isAdding = false
                onComplete()
            }
        }
    }
}

// MARK: - URL Sanitization

func sanitizeURL(_ input: String) -> String {
    var url = input.trimmingCharacters(in: .whitespacesAndNewlines)

    let typoPatterns = [
        "http://http://", "https://https://",
        "http://https://", "https://http://",
        "hhttp://", "htttp://", "hhtp://", "htpp://",
        "httpss://", "htps://"
    ]

    for typo in typoPatterns {
        if url.lowercased().hasPrefix(typo) {
            let isSecure = typo.contains("https") || url.lowercased().hasPrefix("https")
            let correctProtocol = isSecure ? "https://" : "http://"
            url = correctProtocol + String(url.dropFirst(typo.count))
            break
        }
    }

    if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
        url = "http://" + url
    }

    if url.hasSuffix("/") {
        url = String(url.dropLast())
    }

    return url
}
