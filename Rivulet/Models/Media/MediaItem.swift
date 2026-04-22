//
//  MediaItem.swift
//  Rivulet
//
//  List/browse shape consumed by carousels, hub rows, search results, and
//  any view that renders a media tile. All fields are populated at
//  construction by the provider — nothing is "filled in later." Optional
//  fields mean "this backend doesn't have this data."
//

import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let kind: MediaKind

    let title: String
    let sortTitle: String?
    let overview: String?
    let year: Int?
    let runtime: TimeInterval?     // seconds; nil for shows
    let parentRef: MediaItemRef?   // season -> show, episode -> season
    let grandparentRef: MediaItemRef?  // episode -> show

    let userState: MediaUserState
    let artwork: MediaArtwork
}
