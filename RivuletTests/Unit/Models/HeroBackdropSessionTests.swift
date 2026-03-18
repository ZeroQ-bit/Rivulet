import XCTest
@testable import Rivulet

final class HeroBackdropSessionTests: XCTestCase {
    func testSelectionKeepsPlexBackdropWhenUpgradeNotNeeded() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let tmdbURL = URL(string: "https://example.com/tmdb.jpg")
        let thumbURL = URL(string: "https://example.com/thumb.jpg")
        let request = HeroBackdropRequest(
            cacheKey: "movie:1",
            plexBackdropURL: plexURL,
            plexThumbnailURL: thumbURL,
            tmdbId: 1,
            tvdbId: nil,
            mediaType: .movie,
            preferredBackdropSize: "original"
        )

        let resolution = HeroBackdropSelection.compose(
            request: request,
            tmdbBackdropURL: tmdbURL,
            logoURL: nil,
            needsUpgrade: false
        )

        XCTAssertEqual(resolution.displayedBackdropURL, plexURL)
        XCTAssertNil(resolution.pendingUpgradeURL)
        XCTAssertEqual(resolution.thumbnailURL, thumbURL)
    }

    func testSelectionStagesPendingUpgradeWhenNeeded() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let tmdbURL = URL(string: "https://example.com/tmdb.jpg")
        let request = HeroBackdropRequest(
            cacheKey: "show:1",
            plexBackdropURL: plexURL,
            plexThumbnailURL: nil,
            tmdbId: 7,
            tvdbId: nil,
            mediaType: .tv,
            preferredBackdropSize: "original"
        )

        let resolution = HeroBackdropSelection.compose(
            request: request,
            tmdbBackdropURL: tmdbURL,
            logoURL: nil,
            needsUpgrade: true
        )

        XCTAssertEqual(resolution.displayedBackdropURL, plexURL)
        XCTAssertEqual(resolution.pendingUpgradeURL, tmdbURL)
        XCTAssertTrue(resolution.canUpgradeAfterSettle)
    }

    func testSessionBlocksPendingUpgradeWhileMotionLocked() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let tmdbURL = URL(string: "https://example.com/tmdb.jpg")
        let request = HeroBackdropRequest(
            cacheKey: "movie:2",
            plexBackdropURL: plexURL,
            plexThumbnailURL: nil,
            tmdbId: 8,
            tvdbId: nil,
            mediaType: .movie,
            preferredBackdropSize: "original"
        )

        var session = HeroBackdropSession(seed: request)
        session.stage(
            HeroBackdropResolution(
                displayedBackdropURL: plexURL,
                pendingUpgradeURL: tmdbURL,
                logoURL: nil,
                thumbnailURL: nil
            )
        )
        session.setMotionLocked(true)

        XCTAssertFalse(
            session.applyPendingUpgradeIfReady(
                now: Date().addingTimeInterval(1),
                minimumStableDuration: 0.15
            )
        )
        XCTAssertEqual(session.displayedBackdropURL, plexURL)
        XCTAssertEqual(session.pendingUpgradeURL, tmdbURL)
    }

    func testSessionAppliesPendingUpgradeAfterStableDelay() {
        let plexURL = URL(string: "https://example.com/plex.jpg")
        let tmdbURL = URL(string: "https://example.com/tmdb.jpg")
        let request = HeroBackdropRequest(
            cacheKey: "movie:3",
            plexBackdropURL: plexURL,
            plexThumbnailURL: nil,
            tmdbId: 9,
            tvdbId: nil,
            mediaType: .movie,
            preferredBackdropSize: "original"
        )

        var session = HeroBackdropSession(seed: request)
        session.stage(
            HeroBackdropResolution(
                displayedBackdropURL: plexURL,
                pendingUpgradeURL: tmdbURL,
                logoURL: nil,
                thumbnailURL: nil
            )
        )

        let unlockTime = Date()
        session.setMotionLocked(false, now: unlockTime)

        XCTAssertTrue(
            session.applyPendingUpgradeIfReady(
                now: unlockTime.addingTimeInterval(0.2),
                minimumStableDuration: 0.15
            )
        )
        XCTAssertEqual(session.displayedBackdropURL, tmdbURL)
        XCTAssertNil(session.pendingUpgradeURL)
    }

    func testLoadGateInvalidatesOlderGeneration() {
        var gate = HeroBackdropLoadGate()

        let firstToken = gate.begin()
        let secondToken = gate.begin()

        XCTAssertFalse(gate.isCurrent(firstToken))
        XCTAssertTrue(gate.isCurrent(secondToken))
    }
}
