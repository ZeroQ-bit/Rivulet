//
//  MediaLibrary.swift
//  Rivulet
//
//  A library/section on a media provider.
//

import Foundation

struct MediaLibrary: Identifiable, Hashable, Sendable {
    let id: String                  // provider-native (Plex sectionID)
    let providerID: String
    let title: String
    let kind: LibraryKind

    enum LibraryKind: Sendable, Hashable, Codable {
        case movies
        case shows
        case music
        case mixed
        case photos
        case liveTV
    }
}
