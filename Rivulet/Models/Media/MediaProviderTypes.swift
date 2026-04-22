//
//  MediaProviderTypes.swift
//  Rivulet
//
//  Shared enums for the MediaProvider protocol surface.
//

import Foundation

enum MediaProviderKind: String, Sendable, Hashable, Codable {
    case plex
    // .jellyfin added in Wave 2
}

enum ConnectionState: Sendable, Hashable {
    case connected
    case unreachable
    case unauthorized
}

enum MediaProviderError: Error, Sendable {
    case unreachable
    case unauthorized
    case notFound
    case transcodeRequired
    case notPlayable
    case backendSpecific(underlying: String)
}
