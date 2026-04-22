//
//  MediaItemTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemTests: XCTestCase {
    func test_id_returnsRef() {
        let ref = MediaItemRef(providerID: "plex:abc", itemID: "1")
        let item = MediaItem(
            ref: ref,
            kind: .movie,
            title: "Inception",
            sortTitle: nil,
            overview: nil,
            year: 2010,
            runtime: 8880,
            parentRef: nil,
            grandparentRef: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil)
        )
        XCTAssertEqual(item.id, ref)
    }
}
