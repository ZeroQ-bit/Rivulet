//
//  MediaItemEntityTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemEntityTests: XCTestCase {

    let testServerURL = "https://192.168.1.100:32400"
    let testToken = "test-token"

    // MARK: - Movie Entity

    func testMovieEntityHasCorrectSubtitle() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception",
            year: 2010
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "100")
        XCTAssertEqual(entity.title, "Inception")
        XCTAssertEqual(entity.subtitle, "2010 \u{00B7} Movie")
        XCTAssertEqual(entity.mediaType, "movie")
    }

    // MARK: - Episode Entity

    func testEpisodeEntityHasSeriesAndEpisodeInfo() {
        let metadata = PlexMetadata(
            ratingKey: "200",
            type: "episode",
            title: "Pilot",
            year: 2008,
            parentIndex: 1,
            grandparentTitle: "Breaking Bad",
            index: 1
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "200")
        XCTAssertEqual(entity.title, "Pilot")
        XCTAssertEqual(entity.subtitle, "S01E01 \u{00B7} Breaking Bad")
        XCTAssertEqual(entity.mediaType, "episode")
    }

    // MARK: - Show Entity

    func testShowEntityHasCorrectSubtitle() {
        let metadata = PlexMetadata(
            ratingKey: "300",
            type: "show",
            title: "Breaking Bad",
            year: 2008
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.subtitle, "2008 \u{00B7} TV Show")
        XCTAssertEqual(entity.mediaType, "show")
    }

    // MARK: - Thumbnail URL

    func testEntityBuildsFullThumbURL() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception",
            thumb: "/library/metadata/100/thumb/1234"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertNotNil(entity.thumbURL)
        let urlString = entity.thumbURL!.absoluteString
        XCTAssertTrue(urlString.hasPrefix(testServerURL))
        XCTAssertTrue(urlString.contains("/library/metadata/100/thumb/1234"))
        XCTAssertTrue(urlString.contains("X-Plex-Token=test-token"))
    }

    func testEntityWithNoThumbHasNilURL() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertNil(entity.thumbURL)
    }

    // MARK: - Missing Data

    func testEntityWithNoYearOmitsYear() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Unknown Movie"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.subtitle, "Movie")
    }

    func testEntityWithMissingRatingKeyUsesEmptyString() {
        let metadata = PlexMetadata(
            type: "movie",
            title: "No Key"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "")
    }
}
