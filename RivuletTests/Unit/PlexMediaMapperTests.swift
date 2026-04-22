//
//  PlexMediaMapperTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexMediaMapperTests: XCTestCase {

    // MARK: - Library

    func test_library_maps_movies() {
        let plex = PlexLibrary(
            key: "1", type: "movie", title: "Movies", agent: "x",
            scanner: "y", language: "en", uuid: "u",
            updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil
        )
        let mapped = PlexMediaMapper.library(plex, providerID: "plex:abc")
        XCTAssertEqual(mapped.id, "1")
        XCTAssertEqual(mapped.providerID, "plex:abc")
        XCTAssertEqual(mapped.title, "Movies")
        XCTAssertEqual(mapped.kind, .movies)
    }

    func test_library_maps_shows() {
        let plex = PlexLibrary(
            key: "2", type: "show", title: "TV", agent: "x",
            scanner: "y", language: "en", uuid: "u",
            updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
        XCTAssertEqual(PlexMediaMapper.library(plex, providerID: "plex:abc").kind, .shows)
    }

    func test_library_maps_artist_to_music() {
        let plex = PlexLibrary(
            key: "3", type: "artist", title: "Music", agent: "x",
            scanner: "y", language: "en", uuid: "u",
            updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
        XCTAssertEqual(PlexMediaMapper.library(plex, providerID: "plex:abc").kind, .music)
    }

    func test_library_maps_unknown_to_mixed() {
        let plex = PlexLibrary(
            key: "9", type: "weird", title: "?", agent: "x",
            scanner: "y", language: "en", uuid: "u",
            updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
        XCTAssertEqual(PlexMediaMapper.library(plex, providerID: "plex:abc").kind, .mixed)
    }

    // MARK: - Kind

    func test_kind_maps_known_types() {
        XCTAssertEqual(PlexMediaMapper.kind("movie"), .movie)
        XCTAssertEqual(PlexMediaMapper.kind("show"), .show)
        XCTAssertEqual(PlexMediaMapper.kind("season"), .season)
        XCTAssertEqual(PlexMediaMapper.kind("episode"), .episode)
        XCTAssertEqual(PlexMediaMapper.kind("collection"), .collection)
        XCTAssertEqual(PlexMediaMapper.kind(nil), .unknown)
        XCTAssertEqual(PlexMediaMapper.kind("garbage"), .unknown)
    }

    // MARK: - User state

    func test_userState_extractsAllFields() {
        var meta = PlexMetadata()
        meta.viewCount = 1
        meta.viewOffset = 30_000
        meta.userRating = 8.0
        meta.lastViewedAt = 1_700_000_000
        let state = PlexMediaMapper.userState(meta)
        XCTAssertTrue(state.isPlayed)
        XCTAssertEqual(state.viewOffset, 30.0)
        XCTAssertTrue(state.isFavorite)
        XCTAssertEqual(state.lastViewedAt?.timeIntervalSince1970, 1_700_000_000)
    }

    func test_userState_unwatched() {
        var meta = PlexMetadata()
        meta.viewCount = 0
        meta.viewOffset = 0
        let state = PlexMediaMapper.userState(meta)
        XCTAssertFalse(state.isPlayed)
        XCTAssertEqual(state.viewOffset, 0)
        XCTAssertFalse(state.isFavorite)
        XCTAssertNil(state.lastViewedAt)
    }

    // MARK: - Item

    func test_item_basicMovie() {
        var meta = PlexMetadata()
        meta.ratingKey = "12345"
        meta.type = "movie"
        meta.title = "Inception"
        meta.year = 2010
        meta.summary = "Dream within a dream."
        meta.duration = 8_880_000
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc",
                                        serverURL: "https://example", authToken: "TOKEN")
        XCTAssertEqual(item.ref, MediaItemRef(providerID: "plex:abc", itemID: "12345"))
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.title, "Inception")
        XCTAssertEqual(item.year, 2010)
        XCTAssertEqual(item.runtime, 8880)
        XCTAssertEqual(item.overview, "Dream within a dream.")
    }

    func test_item_episode_includesParentRefs() {
        var meta = PlexMetadata()
        meta.ratingKey = "9001"
        meta.type = "episode"
        meta.title = "Pilot"
        meta.parentRatingKey = "200"
        meta.grandparentRatingKey = "100"
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc",
                                        serverURL: "https://x", authToken: "T")
        XCTAssertEqual(item.parentRef?.itemID, "200")
        XCTAssertEqual(item.grandparentRef?.itemID, "100")
    }

    func test_item_episode_carriesEpisodeAndSeasonNumbers() {
        var meta = PlexMetadata()
        meta.ratingKey = "9001"
        meta.type = "episode"
        meta.title = "Pilot"
        meta.index = 1
        meta.parentIndex = 1
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc",
                                        serverURL: "https://x", authToken: "T")
        XCTAssertEqual(item.episodeNumber, 1)
        XCTAssertEqual(item.seasonNumber, 1)
    }

    func test_item_show_carriesChildProgress() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "show"
        meta.title = "Severance"
        meta.leafCount = 18
        meta.viewedLeafCount = 9
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc",
                                        serverURL: "https://x", authToken: "T")
        XCTAssertEqual(item.childProgress?.played, 9)
        XCTAssertEqual(item.childProgress?.total, 18)
    }

    func test_item_episode_carriesGrandparentArtwork() {
        var meta = PlexMetadata()
        meta.ratingKey = "9001"
        meta.type = "episode"
        meta.title = "Pilot"
        meta.grandparentThumb = "/library/metadata/100/thumb/123"
        meta.grandparentArt = "/library/metadata/100/art/123"
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc",
                                        serverURL: "https://x", authToken: "T")
        XCTAssertNotNil(item.grandparentArtwork)
        XCTAssertNotNil(item.grandparentArtwork?.thumbnail)
        XCTAssertNotNil(item.grandparentArtwork?.backdrop)
    }
}
