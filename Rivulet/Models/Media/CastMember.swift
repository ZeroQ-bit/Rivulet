//
//  CastMember.swift
//  Rivulet
//
//  Cast member value type used by the unified MediaItem model. Independent of
//  the underlying source (Plex `Role`, TMDB credit) so detail views can render
//  a single layout regardless of where the data came from.
//

import Foundation

struct CastMember: Hashable, Sendable {
    let name: String
    let role: String?
    let profileImageURL: URL?
}
