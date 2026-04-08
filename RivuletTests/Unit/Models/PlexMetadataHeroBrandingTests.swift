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

    func testHeroBackdropRequestBuildsPlexArtworkURLs() {
        let movie = PlexMetadata(
            ratingKey: "movie-1",
            type: "movie",
            title: "Dune",
            thumb: "/library/metadata/1/thumb/1",
            art: "/library/metadata/1/art/1"
        )

        let request = movie.heroBackdropRequest(
            serverURL: "https://example.com",
            authToken: "token"
        )

        XCTAssertEqual(
            request.plexBackdropURL?.absoluteString,
            "https://example.com/library/metadata/1/art/1?X-Plex-Token=token"
        )
        XCTAssertEqual(
            request.plexThumbnailURL?.absoluteString,
            "https://example.com/library/metadata/1/thumb/1?X-Plex-Token=token"
        )
        XCTAssertNil(request.plexLogoURL)
    }

    func testClearLogoPathReturnsFirstClearLogoEntry() throws {
        let json = """
        {
            "ratingKey": "42",
            "type": "movie",
            "Image": [
                {"alt": "poster", "type": "coverPoster", "url": "/library/metadata/42/thumb/1"},
                {"alt": "background", "type": "background", "url": "/library/metadata/42/art/1"},
                {"alt": "logo", "type": "clearLogo", "url": "/library/metadata/42/clearLogo/1"}
            ]
        }
        """

        let metadata = try JSONDecoder().decode(
            PlexMetadata.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metadata.clearLogoPath, "/library/metadata/42/clearLogo/1")
    }

    func testHeroBackdropRequestUsesClearLogoFromImageArray() {
        let movie = PlexMetadata(
            ratingKey: "movie-2",
            type: "movie",
            title: "Blade Runner 2049",
            thumb: "/library/metadata/2/thumb/1",
            art: "/library/metadata/2/art/1"
        )
        var withLogo = movie
        withLogo.Image = [
            PlexImage(alt: "logo", type: "clearLogo", url: "/library/metadata/2/clearLogo/1")
        ]

        let request = withLogo.heroBackdropRequest(
            serverURL: "https://example.com",
            authToken: "token"
        )

        XCTAssertEqual(
            request.plexLogoURL?.absoluteString,
            "https://example.com/library/metadata/2/clearLogo/1?X-Plex-Token=token"
        )
    }

    func testHeroBackdropRequestRespectsLogoPathOverrideForEpisodes() {
        let episode = PlexMetadata(
            ratingKey: "episode-1",
            type: "episode",
            title: "Pilot",
            thumb: "/library/metadata/10/thumb/1",
            grandparentThumb: "/library/metadata/9/thumb/1",
            grandparentArt: "/library/metadata/9/art/1"
        )

        let request = episode.heroBackdropRequest(
            serverURL: "https://example.com",
            authToken: "token",
            logoPathOverride: "/library/metadata/9/clearLogo/1"
        )

        XCTAssertEqual(
            request.plexBackdropURL?.absoluteString,
            "https://example.com/library/metadata/9/art/1?X-Plex-Token=token"
        )
        XCTAssertEqual(
            request.plexLogoURL?.absoluteString,
            "https://example.com/library/metadata/9/clearLogo/1?X-Plex-Token=token"
        )
    }
}
