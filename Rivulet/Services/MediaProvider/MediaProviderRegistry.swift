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
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        guard
            let serverURL = auth.selectedServerURL,
            let token = auth.selectedServerToken
        else {
            providers.removeAll()
            return
        }
        // Prefer Plex's real machineIdentifier when the user has selected a
        // server in this session. Fall back to a deterministic hash of the
        // server URL when only a restored URL/token is available — this keeps
        // providerID stable across launches (Swift's String.hashValue is
        // randomized per process and would orphan FocusMemory / nav state).
        let machineID: String = {
            if let id = auth.selectedServer?.machineIdentifier { return id }
            return Self.stableHash(of: serverURL)
        }()
        let displayName = auth.selectedServer?.name
            ?? UserDefaults.standard.string(forKey: "selectedServerName")
            ?? "Plex"
        let provider = PlexProvider(
            machineIdentifier: machineID,
            displayName: displayName,
            serverURL: serverURL,
            authToken: token
        )
        register(provider)
    }

    /// Process-stable hash. Avoid `String.hashValue` (per-process randomized).
    private static func stableHash(of input: String) -> String {
        // FNV-1a 64-bit — small, deterministic, no Crypto dependency.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
