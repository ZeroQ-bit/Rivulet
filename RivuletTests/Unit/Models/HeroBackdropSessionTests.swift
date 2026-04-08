import XCTest
@testable import Rivulet

final class HeroBackdropSessionTests: XCTestCase {
    func testSeedInitializerCarriesBackdropThumbnailAndLogo() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let thumbURL = URL(string: "https://example.com/thumb.jpg")
        let logoURL = URL(string: "https://example.com/logo.png")
        let request = HeroBackdropRequest(
            cacheKey: "movie:1",
            plexBackdropURL: plexURL,
            plexThumbnailURL: thumbURL,
            plexLogoURL: logoURL
        )

        let session = HeroBackdropSession(seed: request)

        XCTAssertEqual(session.displayedBackdropURL, plexURL)
        XCTAssertEqual(session.thumbnailURL, thumbURL)
        XCTAssertEqual(session.logoURL, logoURL)
    }

    func testSeedInitializerFallsBackToThumbnailWhenNoBackdrop() {
        let thumbURL = URL(string: "https://example.com/thumb.jpg")
        let request = HeroBackdropRequest(
            cacheKey: "show:1",
            plexBackdropURL: nil,
            plexThumbnailURL: thumbURL,
            plexLogoURL: nil
        )

        let session = HeroBackdropSession(seed: request)

        XCTAssertEqual(session.displayedBackdropURL, thumbURL)
        XCTAssertEqual(session.thumbnailURL, thumbURL)
        XCTAssertNil(session.logoURL)
    }

    func testStageAppliesResolutionFields() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let logoURL = URL(string: "https://example.com/logo.png")
        let thumbURL = URL(string: "https://example.com/thumb.jpg")

        var session = HeroBackdropSession()
        session.stage(
            HeroBackdropResolution(
                displayedBackdropURL: plexURL,
                pendingUpgradeURL: nil,
                logoURL: logoURL,
                thumbnailURL: thumbURL
            )
        )

        XCTAssertEqual(session.displayedBackdropURL, plexURL)
        XCTAssertEqual(session.logoURL, logoURL)
        XCTAssertEqual(session.thumbnailURL, thumbURL)
    }

    func testLoadGateInvalidatesOlderGeneration() {
        var gate = HeroBackdropLoadGate()

        let firstToken = gate.begin()
        let secondToken = gate.begin()

        XCTAssertFalse(gate.isCurrent(firstToken))
        XCTAssertTrue(gate.isCurrent(secondToken))
    }
}
