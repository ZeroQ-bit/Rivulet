import XCTest
@testable import Rivulet

final class PlexMetadataHeroBrandingTests: XCTestCase {
    func testSeasonUsesParentShowTitleForBranding() {
        let season = PlexMetadata(
            type: "season",
            title: "Season 1",
            parentTitle: "Landman",
            index: 1
        )

        XCTAssertEqual(season.seriesTitleForDisplay, "Landman")
        XCTAssertEqual(season.seasonDisplayTitle, "Season 1")
    }

    func testSeasonHeroBackdropRequestUsesParentShowTmdbIdentity() {
        let season = PlexMetadata(
            ratingKey: "season-1",
            guid: "plex://season/1",
            type: "season",
            title: "Season 1",
            thumb: "/library/metadata/1/thumb/1",
            art: "/library/metadata/1/art/1",
            parentGuid: "tmdb://12345",
            parentTitle: "Landman"
        )

        let request = season.heroBackdropRequest(
            serverURL: "https://example.com",
            authToken: "token"
        )

        XCTAssertEqual(request.mediaType, TMDBMediaType.tv)
        XCTAssertEqual(request.tmdbId, 12345)
        XCTAssertNil(request.tvdbId)
    }

    func testSeasonHeroBackdropRequestFallsBackToParentShowTvdbIdentity() {
        let season = PlexMetadata(
            ratingKey: "season-2",
            guid: "plex://season/2",
            type: "season",
            title: "Season 2",
            parentGuid: "tvdb://54321"
        )

        let request = season.heroBackdropRequest(
            serverURL: "https://example.com",
            authToken: "token"
        )

        XCTAssertEqual(request.mediaType, TMDBMediaType.tv)
        XCTAssertNil(request.tmdbId)
        XCTAssertEqual(request.tvdbId, 54321)
    }
}
