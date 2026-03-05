//
//  ContentRouterPlaybackPlanTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ContentRouterPlaybackPlanTests: XCTestCase {

    func testPlanPrefersDirectPlayForVODWithFallbackToHLS() {
        let metadata = makeMetadata(audioCodec: "dts", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .directPlay = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
                if case .hls = plan.fallbacks[0] {
                    // expected
                } else {
                    XCTFail("Expected HLS fallback when primary is direct play")
                }
            } else {
                XCTFail("Expected DirectPlay primary route when FFmpeg is available")
            }
        } else if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when FFmpeg is unavailable")
        }
    }

    func testPlanUsesHLSWhenNoDirectPlaySourceExists() {
        let metadata = makeMetadata(audioCodec: "aac", includePart: false)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)
        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when no direct-play part key is available")
        }
    }

    func testPlanUsesHLSForLiveTV() {
        let metadata = makeMetadata(audioCodec: "aac", includePart: true)
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            isLiveTV: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)
        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary for live TV")
        }
    }

    private func makeMetadata(audioCodec: String, includePart: Bool) -> PlexMetadata {
        let part: [PlexPart]? = includePart
            ? [PlexPart(
                id: 1,
                key: "/library/parts/100/file.mkv",
                duration: nil,
                file: nil,
                size: nil,
                container: "mkv",
                Stream: nil
            )]
            : nil

        let media = PlexMedia(
            id: 1,
            duration: nil,
            bitrate: nil,
            width: nil,
            height: nil,
            aspectRatio: nil,
            audioChannels: nil,
            audioCodec: audioCodec,
            videoCodec: "hevc",
            videoResolution: "4k",
            container: "mkv",
            videoFrameRate: nil,
            Part: part
        )

        return PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Test",
            Media: [media]
        )
    }
}
