//
//  MediaChapter.swift
//  Rivulet
//
//  Chapter marker on a playable item.
//

import Foundation

struct MediaChapter: Hashable, Identifiable, Sendable {
    let id: String
    let title: String?
    let start: TimeInterval
    let end: TimeInterval?
    let thumbnailURL: URL?
}
