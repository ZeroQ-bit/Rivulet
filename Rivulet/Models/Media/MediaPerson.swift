//
//  MediaPerson.swift
//  Rivulet
//
//  Cast / crew member.
//

import Foundation

struct MediaPerson: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
}
