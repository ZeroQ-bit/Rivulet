//
//  MediaItemRef.swift
//  Rivulet
//
//  Stable identity for any media item across the agnostic layer.
//  Hashable + Codable so it works as NavigationDestination value,
//  FocusMemory key, and cache key.
//

import Foundation

struct MediaItemRef: Hashable, Codable, Sendable {
    /// Provider identifier — "plex:<machineId>" / "tmdb" / future "jellyfin:<serverId>".
    let providerID: String
    /// Provider-native item identifier (Plex ratingKey / TMDB id / Jellyfin Guid).
    let itemID: String
}
