import XCTest
@testable import Rivulet

final class RouteAudioPolicyTests: XCTestCase {
    func testLocalRouteKeepsNativePolicy() {
        let snapshot = RouteAudioSnapshot(
            isAirPlay: false,
            maximumOutputChannels: 8,
            sampleRate: 48_000,
            supportsMultichannelContent: true,
            outputPortTypes: ["HDMI"],
            outputPortNames: ["Receiver"]
        )

        let policy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)

        XCTAssertEqual(policy.profile, .local)
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertFalse(policy.forceClientDecodeAllAudio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.isEmpty)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertFalse(policy.forceDownmixToStereo)
        XCTAssertFalse(policy.useSignedInt16Audio)
        XCTAssertEqual(policy.targetOutputSampleRate, 0)
    }

    func testStereoAirPlayRouteForcesConservativeDecodePolicy() {
        let snapshot = RouteAudioSnapshot(
            isAirPlay: true,
            maximumOutputChannels: 2,
            sampleRate: 44_100,
            supportsMultichannelContent: false,
            outputPortTypes: ["AirPlay"],
            outputPortNames: ["Kitchen"]
        )

        let policy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)

        XCTAssertEqual(policy.profile, .airPlayStereo)
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.16)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.5)
        XCTAssertEqual(policy.targetOutputSampleRate, 44_100)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertTrue(policy.useSignedInt16Audio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("aac"))
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("ac3"))
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("eac3"))
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("pcm"))
    }

    func testStereoReportedAirPlayRouteDoesNotUseSurroundReencode() {
        let snapshot = RouteAudioSnapshot(
            isAirPlay: true,
            maximumOutputChannels: 2,
            sampleRate: 44_100,
            supportsMultichannelContent: true,
            outputPortTypes: ["AirPlay"],
            outputPortNames: ["AirPlay"]
        )

        let policy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)

        XCTAssertEqual(policy.profile, .airPlayStereo)
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.16)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.5)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertEqual(
            PlaybackAudioSessionConfigurator.policyDecisionReason(for: snapshot),
            "airplay_stereo_forced_by_max_output_channels"
        )
    }

    func testMultichannelAirPlayRouteEnablesReencodeWithoutPassthrough() {
        let snapshot = RouteAudioSnapshot(
            isAirPlay: true,
            maximumOutputChannels: 8,
            sampleRate: 44_100,
            supportsMultichannelContent: true,
            outputPortTypes: ["AirPlay"],
            outputPortNames: ["Living Room"]
        )

        let policy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)

        XCTAssertEqual(policy.profile, .airPlayMultichannel)
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.35)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.15)
        XCTAssertEqual(policy.targetOutputSampleRate, 44_100)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertFalse(policy.forceClientDecodeAllAudio)
        XCTAssertTrue(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertTrue(policy.useSignedInt16Audio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("flac"))
        XCTAssertTrue(policy.forceClientDecodeCodecs.contains("opus"))
    }
}
