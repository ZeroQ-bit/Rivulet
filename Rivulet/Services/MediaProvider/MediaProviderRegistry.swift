//
//  MediaProviderRegistry.swift
//  Rivulet
//
//  Single source of truth for active MediaProvider instances. Phase 2 wires
//  this to populate from CredentialRegistry / PlexAuthManager. Wave 1 single-
//  server reality: at most one Plex provider entry. Multi-server support
//  arrives in a later wave.
//

import Foundation

@Observable @MainActor
final class MediaProviderRegistry {
    static let shared = MediaProviderRegistry()

    private(set) var providers: [String: any MediaProvider] = [:]

    func provider(for id: String) -> (any MediaProvider)? {
        providers[id]
    }

    func enabledProviders() -> [any MediaProvider] {
        Array(providers.values)
    }

    /// Convenience for single-server use today; first provider in arbitrary
    /// order. Phase 2 populates with the active Plex server. A later wave
    /// adds proper "primary" / "selected" semantics for multi-server.
    var primaryProvider: (any MediaProvider)? {
        providers.values.first
    }

    func register(_ provider: any MediaProvider) {
        providers[provider.id] = provider
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
    }

    /// Reads the active Plex auth state from `PlexAuthManager.shared` and
    /// creates/updates the corresponding `PlexProvider` entry. Called at
    /// app launch and after auth-state changes (sign-in, sign-out, server
    /// switch). Wave 1 single-server: at most one provider entry.
    ///
    /// `PlexAuthManager` doesn't currently expose a stable machineIdentifier
    /// outside server-resolution; we derive one from the server URL hash so
    /// the provider id stays stable across launches as long as the URL
    /// doesn't change. A later wave that surfaces multi-server UX will
    /// thread the real machineIdentifier through.
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        guard
            let serverURL = auth.selectedServerURL,
            let token = auth.selectedServerToken
        else {
            providers.removeAll()
            return
        }
        let machineID = String(serverURL.hashValue)
        let displayName = UserDefaults.standard.string(forKey: "selectedServerName") ?? "Plex"
        let provider = PlexProvider(
            machineIdentifier: machineID,
            displayName: displayName,
            serverURL: serverURL,
            authToken: token
        )
        register(provider)
    }
}
