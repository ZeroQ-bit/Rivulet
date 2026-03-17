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

    func testPlanUsesHLSForDVConversionWhenOnlyClientDecodeAudioExists() {
        let metadata = makeMetadata(
            audioCodec: "truehd",
            includePart: true,
            streams: [makeAudioStream(id: 10, codec: "truehd", channels: 8)]
        )
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            requiresProfileConversion: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary for DV conversion with only client-decoded audio")
        }
    }

    func testPlanKeepsDirectPlayForDVConversionWhenNativeAudioFallbackExists() {
        let metadata = makeMetadata(
            audioCodec: "truehd",
            includePart: true,
            streams: [
                makeAudioStream(id: 10, codec: "truehd", channels: 8),
                makeAudioStream(id: 11, codec: "ac3", channels: 6)
            ]
        )
        let context = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: "http://127.0.0.1:32400")!,
            authToken: "token",
            requiresProfileConversion: true,
            playbackPolicy: .directPlayFirst
        )

        let plan = ContentRouter.plan(for: context)

        if FFmpegDemuxer.isAvailable {
            if case .directPlay = plan.primary {
                XCTAssertEqual(plan.fallbacks.count, 1)
            } else {
                XCTFail("Expected DirectPlay primary when DV conversion has a native audio fallback")
            }
        } else if case .hls = plan.primary {
            XCTAssertTrue(plan.fallbacks.isEmpty)
        } else {
            XCTFail("Expected HLS primary when FFmpeg is unavailable")
        }
    }

    private func makeMetadata(audioCodec: String, includePart: Bool, streams: [PlexStream]? = nil) -> PlexMetadata {
        let part: [PlexPart]? = includePart
            ? [PlexPart(
                id: 1,
                key: "/library/parts/100/file.mkv",
                duration: nil,
                file: nil,
                size: nil,
                container: "mkv",
                Stream: streams
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

    private func makeAudioStream(id: Int, codec: String, channels: Int) -> PlexStream {
        PlexStream(
            id: id,
            streamType: 2,
            codec: codec,
            codecID: nil,
            language: "eng",
            languageCode: "eng",
            languageTag: nil,
            displayTitle: nil,
            title: nil,
            default: id == 10,
            forced: nil,
            selected: id == 10,
            bitDepth: nil,
            chromaLocation: nil,
            chromaSubsampling: nil,
            colorPrimaries: nil,
            colorRange: nil,
            colorSpace: nil,
            colorTrc: nil,
            DOVIBLCompatID: nil,
            DOVIBLPresent: nil,
            DOVIELPresent: nil,
            DOVILevel: nil,
            DOVIPresent: nil,
            DOVIProfile: nil,
            DOVIRPUPresent: nil,
            DOVIVersion: nil,
            frameRate: nil,
            height: nil,
            width: nil,
            level: nil,
            profile: nil,
            refFrames: nil,
            scanType: nil,
            audioChannelLayout: nil,
            channels: channels,
            bitrate: nil,
            samplingRate: 48_000,
            format: nil,
            key: nil,
            extendedDisplayTitle: nil,
            hearingImpaired: nil
        )
    }
}
