//
//  MediaKind.swift
//  Rivulet
//
//  Type discriminator for any media item across the agnostic layer.
//

import Foundation

enum MediaKind: String, Sendable, Hashable, Codable {
    case movie
    case show
    case season
    case episode
    case collection
    case person
    case unknown
}
