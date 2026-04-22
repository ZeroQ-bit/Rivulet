//
//  ChildProgress.swift
//  Rivulet
//
//  Watch-progress for hierarchical items (show/season). Carries the
//  played/total pair the UI uses for "12/24 watched" displays.
//

import Foundation

struct ChildProgress: Hashable, Sendable, Codable {
    let played: Int
    let total: Int
}
