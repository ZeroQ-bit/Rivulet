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
}
