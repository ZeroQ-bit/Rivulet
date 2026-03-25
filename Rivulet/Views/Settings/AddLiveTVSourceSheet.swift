//
//  AddLiveTVSourceSheet.swift
//  Rivulet
//
//  Full-screen view for adding a new Live TV source (Plex or M3U)
//

import SwiftUI

struct AddLiveTVSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataStore = LiveTVDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared

    @State private var selectedSourceType: LiveTVSourceType?
    @State private var isCheckingPlex = false
    @State private var plexLiveTVAvailable: Bool?
    @State private var plexError: String?

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar
                headerBar

                if let sourceType = selectedSourceType {
                    // Configuration form for selected source type
                    configurationView(for: sourceType)
                } else {
                    // Source type picker
                    sourceTypePicker
                }
            }
        }
        // Use system appearance
        .onExitCommand {
            // Navigate back within sheet before dismissing
            if selectedSourceType != nil {
                selectedSourceType = nil
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        Text(headerTitle)
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.top, 50)
            .padding(.bottom, 24)
    }

    private var headerTitle: String {
        switch selectedSourceType {
        case .plex: return "Add Plex Live TV"
        case .dispatcharr: return "Add M3U Server"
        case .genericM3U: return "Add M3U Playlist"
        case nil: return "Add Live TV Source"
        }
    }

    // MARK: - Source Type Picker

    private var sourceTypePicker: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                Text("Choose a source type to add Live TV channels")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 16)

                VStack(spacing: 12) {
                    // Plex Live TV option (only if authenticated)
                    if authManager.isAuthenticated {
                        SourceTypeCard(
                            icon: "play.rectangle.fill",
                            iconColor: .orange,
                            title: "Plex Live TV",
                            subtitle: "Use Live TV from your Plex server",
                            isLoading: isCheckingPlex
                        ) {
                            checkPlexLiveTV()
                        }
                    }

                    // M3U Server option (Dispatcharr-style with auto EPG)
                    SourceTypeCard(
                        icon: "server.rack",
                        iconColor: .blue,
                        title: "M3U Server",
                        subtitle: "Server with M3U and EPG endpoints"
                    ) {
                        selectedSourceType = .dispatcharr
                    }

                    // Generic M3U option
                    SourceTypeCard(
                        icon: "list.bullet.rectangle",
                        iconColor: .green,
                        title: "M3U Playlist",
                        subtitle: "Add any M3U/M3U8 playlist URL"
                    ) {
                        selectedSourceType = .genericM3U
                    }
                }

                // Error message for Plex
                if let error = plexError {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.yellow.opacity(0.1))
                    )
                    .padding(.top, 16)
                }

                // Plex not connected hint
                if !authManager.isAuthenticated {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.blue)
                        Text("Connect your Plex server in Settings to access Plex Live TV")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.blue.opacity(0.1))
                    )
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Configuration Views

    @ViewBuilder
    private func configurationView(for sourceType: LiveTVSourceType) -> some View {
        switch sourceType {
        case .plex:
            PlexLiveTVConfigForm(onBack: { selectedSourceType = nil }, onComplete: { dismiss() })
        case .dispatcharr:
            DispatcharrConfigForm(onBack: { selectedSourceType = nil }, onComplete: { dismiss() })
        case .genericM3U:
            M3UConfigForm(onBack: { selectedSourceType = nil }, onComplete: { dismiss() })
        }
    }

    // MARK: - Plex Live TV Check

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
                    selectedSourceType = .plex
                } else {
                    plexError = "Plex Live TV is not available on this server. Make sure you have a tuner configured."
                }
            }
        }
    }
}

// MARK: - Source Type Card

private struct SourceTypeCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var isLoading: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 24) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(iconColor.gradient)
                    .frame(width: 72, height: 72)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isFocused ? .white.opacity(0.2) : .white.opacity(0.08))
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .focusable()
        .focused($isFocused)
        .onTapGesture {
            if !isLoading {
                action()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Plex Live TV Config Form

private struct PlexLiveTVConfigForm: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var isAdding = false
    @State private var errorMessage: String?

    @FocusState private var addButtonFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 40) {
                // Icon and info
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(.orange.gradient)
                            .frame(width: 120, height: 120)

                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 10) {
                        if let serverName = authManager.savedServerName {
                            Text(serverName)
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        Text("Live TV channels from your Plex server will be added. You can watch live channels and see the program guide.")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 600)
                    }
                }
                .padding(.top, 40)

                // Error message
                if let error = errorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 20))
                }

                // Add button
                Button {
                    addPlexLiveTV()
                } label: {
                    HStack(spacing: 12) {
                        if isAdding {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isAdding ? "Adding..." : "Add Plex Live TV")
                            .font(.system(size: 26, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(minWidth: 280)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(addButtonFocused ? .orange : .orange.opacity(0.85))
                    )
                    .scaleEffect(addButtonFocused ? 1.05 : 1.0)
                }
                .buttonStyle(.plain)
                .focused($addButtonFocused)
                .disabled(isAdding)
                .animation(.easeOut(duration: 0.15), value: addButtonFocused)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 80)
        }
        .onExitCommand {
            onBack()
        }
    }

    private func addPlexLiveTV() {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let serverName = authManager.savedServerName else {
            errorMessage = "Plex server not connected"
            return
        }

        isAdding = true
        errorMessage = nil

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

// MARK: - M3U Server Config Form

private struct DispatcharrConfigForm: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var serverURL = ""
    @State private var displayName = "Live TV"
    @State private var apiToken = ""
    @State private var isAdding = false
    @State private var isValidating = false
    @State private var errorMessage: String?
    @State private var validationStatus: ValidationStatus = .idle

    @FocusState private var focusedButton: ButtonType?

    enum ButtonType: Hashable {
        case validate, add
    }

    enum ValidationStatus: Equatable {
        case idle
        case validating
        case valid(channelCount: Int)
        case invalid(String)
    }

    /// Extract host/IP from Plex server URL, fallback to generic local IP
    private var baseHost: String {
        if let plexURLString = authManager.selectedServerURL,
           let plexURL = URL(string: plexURLString),
           let host = plexURL.host,
           isLocalIP(host) {
            return host
        }
        return "192.168.1.100"
    }

    /// Check if an IP address is local/private
    private func isLocalIP(_ host: String) -> Bool {
        host.hasPrefix("192.168.") ||
        host.hasPrefix("10.") ||
        host.hasPrefix("172.16.") ||
        host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") ||
        host.hasPrefix("172.19.") ||
        host.hasPrefix("172.2") ||
        host.hasPrefix("172.30.") ||
        host.hasPrefix("172.31.") ||
        host == "localhost" ||
        host == "127.0.0.1"
    }

    /// Suggestions using the detected local IP from Plex server
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 32) {
                // Form description
                Text("Enter the base URL of your M3U server. The app will automatically fetch channels and EPG data.")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Form fields
                VStack(spacing: 12) {
                    // Server URL field with common IPTV aggregator suggestions
                    SettingsTextEntryRow(
                        icon: "globe",
                        iconColor: .blue,
                        title: "Server URL",
                        value: $serverURL,
                        placeholder: "http://\(baseHost):9191",
                        hint: "Base URL (expects /output/m3u and /output/epg)",
                        suggestions: serverSuggestions,
                        keyboardType: .URL
                    )

                    // Display name field
                    SettingsTextEntryRow(
                        icon: "textformat",
                        iconColor: .purple,
                        title: "Display Name",
                        value: $displayName,
                        placeholder: "Live TV"
                    )

                    // API Token field (optional)
                    SettingsTextEntryRow(
                        icon: "key",
                        iconColor: .orange,
                        title: "API Token",
                        value: $apiToken,
                        placeholder: "Optional — leave blank if not required"
                    )
                }

                // Validation status
                if validationStatus != .idle {
                    validationStatusView
                        .padding(.horizontal, 24)
                }

                // Error message
                if let error = errorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                }

                // Buttons
                HStack(spacing: 20) {
                    // Validate button
                    Button {
                        validateServer()
                    } label: {
                        HStack(spacing: 10) {
                            if isValidating {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isValidating ? "Checking..." : "Validate")
                                .font(.system(size: 24, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(focusedButton == .validate ? .white.opacity(0.25) : .white.opacity(0.15))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            focusedButton == .validate ? .white.opacity(0.3) : .white.opacity(0.1),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .scaleEffect(focusedButton == .validate ? 1.03 : 1.0)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusedButton, equals: .validate)
                    .disabled(serverURL.isEmpty || isValidating)

                    // Add button
                    Button {
                        addDispatcharr()
                    } label: {
                        HStack(spacing: 10) {
                            if isAdding {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isAdding ? "Adding..." : "Add Source")
                                .font(.system(size: 24, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(canAdd ? (focusedButton == .add ? .blue : .blue.opacity(0.85)) : .gray.opacity(0.5))
                        )
                        .scaleEffect(focusedButton == .add && canAdd ? 1.03 : 1.0)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusedButton, equals: .add)
                    .disabled(!canAdd || isAdding)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 80)
            .padding(.top, 24)
        }
        .onExitCommand {
            onBack()
        }
    }

    @ViewBuilder
    private var validationStatusView: some View {
        HStack(spacing: 12) {
            switch validationStatus {
            case .idle:
                EmptyView()
            case .validating:
                ProgressView()
                Text("Checking server...")
                    .foregroundStyle(.white.opacity(0.6))
            case .valid(let count):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected! Found \(count) channels")
                    .foregroundStyle(.green)
            case .invalid(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var canAdd: Bool {
        !serverURL.isEmpty && !displayName.isEmpty
    }

    private func validateServer() {
        // Sanitize URL before validation (fixes common typos like "hhttp://")
        let cleanedURL = sanitizeURL(serverURL)
        guard let service = DispatcharrService.create(from: cleanedURL, apiToken: apiToken.isEmpty ? nil : apiToken) else {
            validationStatus = .invalid("Invalid URL format")
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
        // Sanitize URL (fixes common typos like "hhttp://")
        let cleanedURL = sanitizeURL(serverURL)

        guard let url = URL(string: cleanedURL) else {
            errorMessage = "Invalid URL"
            return
        }

        isAdding = true
        errorMessage = nil

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

// MARK: - M3U Playlist Config Form

private struct M3UConfigForm: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var m3uURL = ""
    @State private var epgURL = ""
    @State private var displayName = "IPTV"
    @State private var isAdding = false
    @State private var errorMessage: String?

    @FocusState private var isAddButtonFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 32) {
                // Form description
                Text("Add any M3U or M3U8 playlist URL. Optionally provide an XMLTV EPG URL for program guide data.")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Form fields
                VStack(spacing: 12) {
                    // M3U URL field
                    SettingsTextEntryRow(
                        icon: "list.bullet.rectangle",
                        iconColor: .green,
                        title: "M3U Playlist URL",
                        value: $m3uURL,
                        placeholder: "http://example.com/playlist.m3u",
                        hint: "URL to your M3U or M3U8 playlist",
                        keyboardType: .URL
                    )

                    // EPG URL field (optional)
                    SettingsTextEntryRow(
                        icon: "calendar",
                        iconColor: .orange,
                        title: "EPG URL (Optional)",
                        value: $epgURL,
                        placeholder: "http://example.com/epg.xml",
                        hint: "XMLTV format for program guide",
                        keyboardType: .URL
                    )

                    // Display name field
                    SettingsTextEntryRow(
                        icon: "textformat",
                        iconColor: .purple,
                        title: "Display Name",
                        value: $displayName,
                        placeholder: "IPTV"
                    )
                }

                // Error message
                if let error = errorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                }

                // Add button
                Button {
                    addM3U()
                } label: {
                    HStack(spacing: 12) {
                        if isAdding {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isAdding ? "Adding..." : "Add Source")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(minWidth: 200)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(m3uURL.isEmpty ? .gray.opacity(0.5) : (isAddButtonFocused ? .green : .green.opacity(0.85)))
                    )
                    .scaleEffect(isAddButtonFocused && !m3uURL.isEmpty ? 1.03 : 1.0)
                }
                .buttonStyle(SettingsButtonStyle())
                .focused($isAddButtonFocused)
                .disabled(m3uURL.isEmpty || isAdding)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAddButtonFocused)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 80)
            .padding(.top, 24)
        }
        .onExitCommand {
            onBack()
        }
    }

    private func addM3U() {
        // Sanitize M3U URL (fixes common typos like "hhttp://")
        let cleanedM3U = sanitizeURL(m3uURL)

        guard let m3u = URL(string: cleanedM3U) else {
            errorMessage = "Invalid M3U URL"
            return
        }

        // Sanitize EPG URL if provided
        var epg: URL? = nil
        if !epgURL.isEmpty {
            let cleanedEPG = sanitizeURL(epgURL)
            epg = URL(string: cleanedEPG)
        }

        isAdding = true
        errorMessage = nil

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

/// Sanitize user-entered URLs to fix common typos
private func sanitizeURL(_ input: String) -> String {
    var url = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Remove common typos in protocol prefix
    // e.g., "hhttp://", "htttp://", "http:/http://", "http://http://"
    let typoPatterns = [
        "http://http://", "https://https://",
        "http://https://", "https://http://",
        "hhttp://", "htttp://", "hhtp://", "htpp://",
        "httpss://", "htps://"
    ]

    for typo in typoPatterns {
        if url.lowercased().hasPrefix(typo) {
            // Replace typo with correct protocol
            let isSecure = typo.contains("https") || url.lowercased().hasPrefix("https")
            let correctProtocol = isSecure ? "https://" : "http://"
            url = correctProtocol + String(url.dropFirst(typo.count))
            break
        }
    }

    // Add http:// if no valid scheme present
    if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
        url = "http://" + url
    }

    // Remove trailing slash for consistency
    if url.hasSuffix("/") {
        url = String(url.dropLast())
    }

    return url
}

#Preview {
    AddLiveTVSourceSheet()
}
