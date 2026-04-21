//
//  MediaItemRefTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemRefTests: XCTestCase {
    func test_hashable_equal() {
        let a = MediaItemRef(providerID: "plex:abc", itemID: "12345")
        let b = MediaItemRef(providerID: "plex:abc", itemID: "12345")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_codable_roundTrip() throws {
        let ref = MediaItemRef(providerID: "tmdb", itemID: "603")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(MediaItemRef.self, from: data)
        XCTAssertEqual(decoded, ref)
    }
}
