//
//  MediaSourceQualityBadgesTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaSourceQualityBadgesTests: XCTestCase {

    func test_4kDolbyVision_5_1Audio() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: 153,
            width: 3840, height: 2160, frameRate: 24,
            bitrate: 50_000_000,
            videoRange: .dolbyVision(profile: 7),
            isDefault: true
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "eac3",
            channels: 6, channelLayout: "5.1",
            language: "en", title: nil,
            bitrate: 640_000, samplingRate: 48_000,
            isDefault: true, isForced: false
        )
        let source = MediaSource(
            id: "1", container: "mkv", duration: 7200,
            bitrate: 50_000_000, fileSize: nil, fileName: nil,
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("4K"))
        XCTAssertTrue(badges.contains("DV"))
        XCTAssertTrue(badges.contains("5.1"))
    }

    func test_1080pHDR10_stereoAudio() {
        let video = VideoTrack(
            id: "v1", codec: "hevc", profile: "Main 10", level: nil,
            width: 1920, height: 1080, frameRate: 24,
            bitrate: nil, videoRange: .hdr10, isDefault: true
        )
        let audio = AudioTrack(
            id: "a1", index: 0, codec: "aac",
            channels: 2, channelLayout: "Stereo",
            language: "en", title: nil,
            bitrate: 192_000, samplingRate: 48_000,
            isDefault: true, isForced: false
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertTrue(badges.contains("HD"))
        XCTAssertTrue(badges.contains("HDR"))
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("DV"))
        XCTAssertFalse(badges.contains("Stereo"))
    }

    func test_sdr_noBadges() {
        let video = VideoTrack(
            id: "v1", codec: "h264", profile: nil, level: nil,
            width: 1280, height: 720, frameRate: 24,
            bitrate: nil, videoRange: .sdr, isDefault: true
        )
        let source = MediaSource(
            id: "1", container: "mp4", duration: 7200,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoTracks: [video], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        let badges = source.qualityBadges()
        XCTAssertFalse(badges.contains("4K"))
        XCTAssertFalse(badges.contains("HDR"))
        XCTAssertFalse(badges.contains("DV"))
    }

    func test_emptyTracks_returnsEmpty() {
        let source = MediaSource(
            id: "1", container: nil, duration: 0,
            bitrate: nil, fileSize: nil, fileName: nil,
            videoTracks: [], audioTracks: [], subtitleTracks: [],
            streamKind: .directPlay, streamURL: nil
        )
        XCTAssertTrue(source.qualityBadges().isEmpty)
    }
}
