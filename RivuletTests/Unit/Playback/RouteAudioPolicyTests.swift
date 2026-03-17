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

    func testStereoAirPlayRouteDecodesPCMViaSampleBufferRenderer() {
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
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.2)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.1)
        XCTAssertEqual(policy.targetOutputSampleRate, 0)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.isEmpty)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertTrue(policy.useSignedInt16Audio)
    }

    func testStereoReportedAirPlayRouteDecodesPCMViaSampleBufferRenderer() {
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
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.2)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.1)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertEqual(
            PlaybackAudioSessionConfigurator.policyDecisionReason(for: snapshot),
            "airplay_stereo_forced_by_max_output_channels"
        )
    }

    func testMultichannelAirPlayRouteDecodesPCMWithSurroundReEncode() {
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
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.2)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.1)
        XCTAssertEqual(policy.targetOutputSampleRate, 0)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.isEmpty)
        XCTAssertTrue(policy.enableSurroundReEncoding)
        XCTAssertFalse(policy.forceDownmixToStereo)
        XCTAssertTrue(policy.useSignedInt16Audio)
    }

    func testAirPlayStabilityFallbackDecodesPCMViaSampleBufferRenderer() {
        let snapshot = RouteAudioSnapshot(
            isAirPlay: true,
            maximumOutputChannels: 8,
            sampleRate: 44_100,
            supportsMultichannelContent: true,
            outputPortTypes: ["AirPlay"],
            outputPortNames: ["Living Room"]
        )

        let policy = PlaybackAudioSessionConfigurator.stabilityFallbackAudioPolicy(for: snapshot)

        XCTAssertEqual(policy.profile, .airPlayStereo)
        XCTAssertEqual(policy.audioPullStartBufferDuration, 0.2)
        XCTAssertEqual(policy.audioPullResumeBufferDuration, 0.1)
        XCTAssertEqual(policy.targetOutputSampleRate, 0)
        XCTAssertFalse(policy.preferAudioEngineForPCM)
        XCTAssertTrue(policy.forceClientDecodeAllAudio)
        XCTAssertTrue(policy.forceClientDecodeCodecs.isEmpty)
        XCTAssertFalse(policy.enableSurroundReEncoding)
        XCTAssertTrue(policy.forceDownmixToStereo)
        XCTAssertTrue(policy.useSignedInt16Audio)
    }
}
