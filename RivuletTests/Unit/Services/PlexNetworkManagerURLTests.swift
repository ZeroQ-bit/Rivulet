//
//  PlexNetworkManagerURLTests.swift
//  RivuletTests
//
//  Unit tests for PlexNetworkManager URL building methods
//

import XCTest
@testable import Rivulet

final class PlexNetworkManagerURLTests: XCTestCase {

    let networkManager = PlexNetworkManager.shared
    let testServerURL = "https://192.168.1.100:32400"
    let testAuthToken = "test-auth-token"
    let testRatingKey = "12345"

    // MARK: - Direct Play URL Tests

    func testBuildDirectPlayURLIncludesToken() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Token=\(testAuthToken)"))
    }

    func testBuildDirectPlayURLIncludesClientIdentifier() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Client-Identifier="))
    }

    func testBuildDirectPlayURLPreservesExistingQueryParams() {
        // IVA trailers have quality params like fmt=4&bitrate=5000
        let partKey = "/library/parts/67890/file.mp4?fmt=4&bitrate=5000"
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: partKey,
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
        // Should preserve the original query params AND add Plex params
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("fmt=4"))
        XCTAssertTrue(urlString.contains("bitrate=5000"))
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
    }

    func testBuildDirectPlayURLReturnsNilForNonDirectPlayableContainers() {
        // MKV is not direct-playable on Apple TV
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mkv",
            container: "mkv",
            strategy: .directPlay
        )

        XCTAssertNil(url, "MKV container should return nil for direct play")
    }

    func testBuildDirectPlayURLAcceptsMP4Container() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mp4",
            container: "mp4",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsM4VContainer() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.m4v",
            container: "m4v",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsMOVContainer() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            partKey: "/library/parts/67890/file.mov",
            container: "mov",
            strategy: .directPlay
        )

        XCTAssertNotNil(url)
    }

    func testBuildDirectPlayURLAcceptsAudioContainers() {
        let audioContainers = ["mp3", "flac", "m4a", "aac"]

        for container in audioContainers {
            let url = networkManager.buildStreamURL(
                serverURL: testServerURL,
                authToken: testAuthToken,
                ratingKey: testRatingKey,
                partKey: "/library/parts/67890/file.\(container)",
                container: container,
                strategy: .directPlay,
                isAudio: true
            )

            XCTAssertNotNil(url, "Audio container \(container) should be direct-playable")
        }
    }

    // MARK: - Direct Stream URL Tests

    func testBuildDirectStreamURLUsesTranscodeEndpoint() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/video/:/transcode/universal/start.m3u8"))
    }

    func testBuildDirectStreamURLIncludesMediaPath() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("path=/library/metadata/\(testRatingKey)"))
    }

    func testBuildDirectStreamURLUsesAudioEndpointForAudio() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .directStream,
            isAudio: true
        )

        XCTAssertNotNil(url)
        // Audio endpoint is /music/:/transcode/... (with two colons)
        XCTAssertTrue(url!.absoluteString.contains("/music/:/transcode/universal/start.m3u8"))
    }

    // MARK: - HLS Transcode URL Tests

    func testBuildHLSTranscodeURLUsesTranscodeEndpoint() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/video/:/transcode/universal/start.m3u8"))
    }

    func testBuildHLSTranscodeURLIncludesProtocolParameter() {
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("protocol=hls"))
    }

    func testBuildHLSTranscodeURLIncludesOffset() {
        let offsetMs = 60000 // 1 minute
        let url = networkManager.buildStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            strategy: .hlsTranscode,
            offsetMs: offsetMs
        )

        XCTAssertNotNil(url)
        // Offset is converted from ms to seconds
        XCTAssertTrue(url!.absoluteString.contains("offset=60"))
    }

    // MARK: - HLS Direct Play URL (Dolby Vision) Tests

    func testBuildHLSDirectPlayURLReturnsURLAndHeaders() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.url)
        XCTAssertNotNil(result?.headers)
        XCTAssertFalse(result!.headers.isEmpty)
    }

    func testBuildHLSDirectPlayURLIncludesToken() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey
        )

        XCTAssertNotNil(result)
        // Token may be in URL or in headers
        let tokenInURL = result!.url.absoluteString.contains("X-Plex-Token=\(testAuthToken)")
        let tokenInHeaders = result!.headers["X-Plex-Token"] == testAuthToken
        XCTAssertTrue(tokenInURL || tokenInHeaders, "Token should be in URL or headers")
    }

    func testBuildHLSDirectPlayURLIncludesClientProfile() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            hasHDR: true,
            useDolbyVision: true
        )

        XCTAssertNotNil(result)
        let urlString = result!.url.absoluteString
        // Should include client profile for Dolby Vision
        XCTAssertTrue(urlString.contains("X-Plex-Client-Profile-Extra=") || urlString.contains("X-Plex-Client-Profile-Name="))
    }

    func testBuildHLSDirectPlayURLSetsForceVideoTranscode() {
        let result = networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            ratingKey: testRatingKey,
            forceVideoTranscode: true
        )

        XCTAssertNotNil(result)
        // When forcing transcode, video should not be direct streamed
        let urlString = result!.url.absoluteString
        XCTAssertTrue(urlString.contains("videoCodec="))
    }

    // MARK: - Direct Play URL Tests

    func testBuildPlaybackDirectPlayURLIncludesPartKey() {
        let partKey = "/library/parts/67890/0/file.mkv"
        let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            partKey: partKey
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains(partKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? partKey))
    }

    func testBuildPlaybackDirectPlayURLIncludesAllPlexHeaders() {
        let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            partKey: "/library/parts/67890/0/file.mkv"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
        XCTAssertTrue(urlString.contains("X-Plex-Client-Identifier="))
        XCTAssertTrue(urlString.contains("X-Plex-Platform="))
        XCTAssertTrue(urlString.contains("X-Plex-Device="))
        XCTAssertTrue(urlString.contains("X-Plex-Product="))
    }

    // MARK: - Thumbnail URL Tests

    func testBuildThumbnailURLSetsCorrectDimensions() {
        let width = 300
        let height = 450
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890",
            width: width,
            height: height
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("width=\(width)"))
        XCTAssertTrue(urlString.contains("height=\(height)"))
    }

    func testBuildThumbnailURLUsesTranscodeEndpoint() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("/photo/:/transcode"))
    }

    func testBuildThumbnailURLIncludesThumbPath() {
        let thumbPath = "/library/metadata/12345/thumb/1234567890"
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: thumbPath
        )

        XCTAssertNotNil(url)
        // The thumb path should be URL-encoded as a query parameter
        XCTAssertTrue(url!.absoluteString.contains("url="))
    }

    func testBuildThumbnailURLIncludesToken() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("X-Plex-Token=\(testAuthToken)"))
    }

    func testBuildThumbnailURLUsesDefaultDimensions() {
        let url = networkManager.buildThumbnailURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            thumbPath: "/library/metadata/12345/thumb/1234567890"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        // Default dimensions are 400x600
        XCTAssertTrue(urlString.contains("width=400"))
        XCTAssertTrue(urlString.contains("height=600"))
    }

    // MARK: - Live TV Stream URL Tests

    func testBuildLiveTVStreamURLIncludesChannelKey() {
        let channelKey = "/livetv/sessions/12345/playback"
        let url = networkManager.buildLiveTVStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            channelKey: channelKey
        )

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains(channelKey))
    }

    func testBuildLiveTVStreamURLIncludesPlexHeaders() {
        let url = networkManager.buildLiveTVStreamURL(
            serverURL: testServerURL,
            authToken: testAuthToken,
            channelKey: "/livetv/sessions/12345/playback"
        )

        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.contains("X-Plex-Token="))
        XCTAssertTrue(urlString.contains("X-Plex-Client-Identifier="))
    }

    // MARK: - Plex Headers Tests

    func testPlexHeadersIncludesAllRequiredHeaders() {
        let headers = networkManager.plexHeaders(authToken: testAuthToken)

        XCTAssertEqual(headers["X-Plex-Token"], testAuthToken)
        XCTAssertNotNil(headers["X-Plex-Client-Identifier"])
        XCTAssertNotNil(headers["X-Plex-Product"])
        XCTAssertNotNil(headers["X-Plex-Platform"])
        XCTAssertNotNil(headers["X-Plex-Device"])
    }
}
