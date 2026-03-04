//
//  FFmpegAudioDecoder.swift
//  Rivulet
//
//  Client-side audio decoder for codecs not natively supported by Apple TV
//  (TrueHD, DTS, DTS-HD MA). Uses libavcodec to decode compressed audio to
//  interleaved PCM, then wraps in CMSampleBuffers for AVSampleBufferAudioRenderer.
//
//  This enables true direct play for ALL content — zero Plex server involvement —
//  by decoding unsupported audio locally instead of forcing HLS transcode.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Decoded Audio Frame

/// PCM audio data decoded from a compressed packet, ready for CMSampleBuffer creation.
struct DecodedAudioFrame: Sendable {
    let data: Data              // Interleaved PCM samples
    let sampleCount: Int        // Number of audio frames (e.g., 4096)
    let sampleRate: Int         // e.g., 48000
    let channels: Int           // e.g., 8 for 7.1
    let bitsPerSample: Int      // 16, 24, or 32
    let pts: CMTime             // Presentation timestamp
}

// =============================================================================
// MARK: - FFmpeg Implementation (when libraries are available)
// =============================================================================

#if RIVULET_FFMPEG
import Libavcodec
import Libavutil
import Libswresample

/// Decodes TrueHD/DTS audio to interleaved PCM using libavcodec + libswresample.
final class FFmpegAudioDecoder: @unchecked Sendable {

    /// Audio codecs this decoder handles (everything Apple TV can't natively decode).
    static let supportedCodecs: Set<String> = [
        "truehd", "mlp",                   // Dolby TrueHD / MLP
        "dts", "dca",                       // DTS Core
        "dts-hd", "dtshd", "dts-hd ma",    // DTS-HD (MA and HRA)
    ]

    /// Whether FFmpeg audio decoding is available
    static let isAvailable = true

    // MARK: - Private State

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var isOpen = false

    // Output format info (tracks current swresample config)
    private var outputSampleRate: Int = 0
    private var outputChannels: Int = 0
    private var outputBitsPerSample: Int = 0

    // Batching state: accumulates tiny decoded frames (e.g., TrueHD's 40-sample frames)
    // into larger chunks to reduce CMSampleBuffer creation and enqueue overhead.
    private var batchData = Data()
    private var batchSampleCount = 0
    private var batchPTS: CMTime = .invalid
    private var batchSampleRate: Int = 0
    private var batchChannels: Int = 0
    private var batchBitsPerSample: Int = 0

    /// Minimum samples to accumulate before emitting a batch.
    /// TrueHD = 40 samples/frame, so 960 = 24 frames ≈ 20ms at 48kHz.
    /// This brings the packet rate from ~1200/sec down to ~50/sec, matching video.
    private let minBatchSamples = 960

    // MARK: - Init

    /// Open a decoder for the given codec parameters.
    /// - Parameters:
    ///   - codecpar: Codec parameters from the demuxer stream
    ///   - codecNameHint: Demuxer-reported codec name (e.g., "truehd"). Used to find the
    ///     correct decoder by name, since TrueHD streams report AV_CODEC_ID_AC3 at the
    ///     codecpar level (TrueHD embeds an AC3 core for compatibility).
    init(codecpar: UnsafePointer<AVCodecParameters>, codecNameHint: String? = nil) throws {
        let codecId = codecpar.pointee.codec_id

        // Prefer name-based lookup when a hint is provided.
        // This is critical for TrueHD: the demuxer knows it's TrueHD from the container
        // metadata, but codecpar.codec_id reports AC3 (the embedded compatibility core).
        let codec: UnsafePointer<AVCodec>?
        let lookupMethod: String

        if let hint = codecNameHint {
            // Map common Plex/container names to FFmpeg decoder names
            let ffmpegName: String
            switch hint.lowercased() {
            case "truehd", "mlp":
                ffmpegName = "truehd"
            case "dts", "dca", "dts-hd", "dtshd", "dts-hd ma":
                ffmpegName = "dca"
            default:
                ffmpegName = hint.lowercased()
            }

            if let byName = avcodec_find_decoder_by_name(ffmpegName) {
                codec = byName
                lookupMethod = "by-name(\(ffmpegName))"
            } else {
                // Fall back to ID-based if name lookup fails
                codec = avcodec_find_decoder(codecId)
                lookupMethod = "by-id(name \(ffmpegName) not found)"
            }
        } else {
            codec = avcodec_find_decoder(codecId)
            lookupMethod = "by-id"
        }

        guard let codec else {
            let name = String(cString: avcodec_get_name(codecId))
            print("[AudioDecoder] No decoder found for codec: \(name)")
            throw FFmpegError.unsupportedCodec(name)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FFmpegError.allocationFailed
        }

        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx

        var ret = avcodec_parameters_to_context(ctx, codecpar)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        // Log if there's a codec_id mismatch (indicates wrong stream was selected)
        if ctx.pointee.codec_id != codec.pointee.id {
            print("[AudioDecoder] ⚠️ codec_id mismatch: context=\(ctx.pointee.codec_id.rawValue) " +
                  "decoder=\(codec.pointee.id.rawValue) — ensure correct stream is selected")
        }

        ret = avcodec_open2(ctx, codec, nil)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        guard let frame = av_frame_alloc() else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.allocationFailed
        }

        self.codecContext = ctx
        self.decodedFrame = frame
        self.isOpen = true

        let decoderName = String(cString: codec.pointee.name)
        let channels = codecpar.pointee.ch_layout.nb_channels
        let sampleRate = codecpar.pointee.sample_rate
        print("[AudioDecoder] Opened \(decoderName) decoder: \(channels)ch \(sampleRate)Hz (\(lookupMethod))")
    }

    deinit { close() }

    // MARK: - Decode

    /// Decode a compressed audio packet into PCM frames.
    /// One packet may produce zero or more output frames.
    func decode(_ packet: DemuxedPacket) -> [DecodedAudioFrame] {
        guard let ctx = codecContext, let frame = decodedFrame, isOpen else { return [] }

        var avPacket = av_packet_alloc()
        guard let pkt = avPacket else { return [] }
        defer { av_packet_free(&avPacket) }

        // Fill AVPacket from DemuxedPacket data
        packet.data.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            av_new_packet(pkt, Int32(packet.data.count))
            pkt.pointee.data.update(from: baseAddress.assumingMemoryBound(to: UInt8.self),
                                     count: packet.data.count)
            pkt.pointee.pts = packet.pts
            pkt.pointee.dts = packet.dts
            pkt.pointee.duration = packet.duration
        }

        var ret = avcodec_send_packet(ctx, pkt)
        guard ret >= 0 || ret == kAudioDecoderEAGAIN else {
            print("[AudioDecoder] send_packet error: \(ret)")
            return []
        }

        var frames: [DecodedAudioFrame] = []

        while true {
            av_frame_unref(frame)
            ret = avcodec_receive_frame(ctx, frame)

            if ret == kAudioDecoderEAGAIN || ret == kAudioDecoderEOF {
                break
            }
            guard ret >= 0 else {
                print("[AudioDecoder] receive_frame error: \(ret)")
                break
            }

            if let decoded = convertToInterleaved(frame: frame, packetTimebase: packet.timebase) {
                frames.append(decoded)
            }
        }

        return frames
    }

    // MARK: - Batched Decode

    /// Decode a packet and accumulate the PCM output into batches.
    /// Returns completed batches (≥960 samples each ≈ 20ms at 48kHz).
    /// TrueHD produces ~40 samples per packet (0.83ms), so batching reduces
    /// the CMSampleBuffer creation rate from ~1200/sec to ~50/sec.
    func decodeAndBatch(_ packet: DemuxedPacket) -> [DecodedAudioFrame] {
        let frames = decode(packet)
        var output: [DecodedAudioFrame] = []

        for frame in frames {
            // Start new batch if empty
            if batchSampleCount == 0 {
                batchPTS = frame.pts
                batchSampleRate = frame.sampleRate
                batchChannels = frame.channels
                batchBitsPerSample = frame.bitsPerSample
            }

            batchData.append(frame.data)
            batchSampleCount += frame.sampleCount

            if batchSampleCount >= minBatchSamples {
                output.append(DecodedAudioFrame(
                    data: batchData,
                    sampleCount: batchSampleCount,
                    sampleRate: batchSampleRate,
                    channels: batchChannels,
                    bitsPerSample: batchBitsPerSample,
                    pts: batchPTS
                ))
                batchData = Data()
                batchSampleCount = 0
                batchPTS = .invalid
            }
        }

        return output
    }

    /// Flush any remaining accumulated samples (call on seek/stop/EOS).
    func flushBatch() -> DecodedAudioFrame? {
        guard batchSampleCount > 0 else { return nil }
        let frame = DecodedAudioFrame(
            data: batchData,
            sampleCount: batchSampleCount,
            sampleRate: batchSampleRate,
            channels: batchChannels,
            bitsPerSample: batchBitsPerSample,
            pts: batchPTS
        )
        batchData = Data()
        batchSampleCount = 0
        batchPTS = .invalid
        return frame
    }

    // MARK: - CMSampleBuffer Creation

    /// Create a CMSampleBuffer containing LPCM audio data from a decoded frame.
    func createPCMSampleBuffer(from frame: DecodedAudioFrame) throws -> CMSampleBuffer {
        let bytesPerSample = frame.bitsPerSample / 8
        let bytesPerFrame = bytesPerSample * frame.channels

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(frame.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(frame.channels),
            mBitsPerChannel: UInt32(frame.bitsPerSample),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let fd = formatDescription else {
            throw FFmpegError.formatDescriptionFailed(status: status)
        }

        var blockBuffer: CMBlockBuffer?
        let dataCount = frame.data.count

        status = frame.data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let baseAddress = rawBuf.baseAddress else { return -1 }
            var buffer: CMBlockBuffer?
            let s1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: dataCount, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: dataCount,
                flags: 0, blockBufferOut: &buffer
            )
            guard s1 == noErr, let buf = buffer else { return s1 }
            let s2 = CMBlockBufferReplaceDataBytes(
                with: baseAddress, blockBuffer: buf,
                offsetIntoDestination: 0, dataLength: dataCount
            )
            blockBuffer = buf
            return s2
        }

        guard status == noErr, let block = blockBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fd,
            sampleCount: frame.sampleCount,
            presentationTimeStamp: frame.pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }

        return buffer
    }

    // MARK: - Close

    func close() {
        guard isOpen else { return }
        isOpen = false

        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }

        if decodedFrame != nil {
            av_frame_free(&decodedFrame)
            decodedFrame = nil
        }

        if codecContext != nil {
            avcodec_free_context(&codecContext)
            codecContext = nil
        }

        print("[AudioDecoder] Closed")
    }

    // MARK: - Private: Planar → Interleaved Conversion

    /// Convert a decoded AVFrame to interleaved PCM using libswresample.
    private func convertToInterleaved(frame: UnsafeMutablePointer<AVFrame>,
                                      packetTimebase: CMTime) -> DecodedAudioFrame? {
        let sampleFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let channels = frame.pointee.ch_layout.nb_channels
        let sampleRate = frame.pointee.sample_rate
        let nbSamples = frame.pointee.nb_samples

        guard channels > 0, sampleRate > 0, nbSamples > 0 else { return nil }

        // Map FFmpeg sample format to interleaved output format
        let outputFormat: AVSampleFormat
        let bitsPerSample: Int

        switch sampleFormat {
        case AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P:
            outputFormat = AV_SAMPLE_FMT_S16
            bitsPerSample = 16
        case AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P:
            outputFormat = AV_SAMPLE_FMT_S32
            bitsPerSample = 32
        case AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP,
             AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP:
            outputFormat = AV_SAMPLE_FMT_S32
            bitsPerSample = 32
        default:
            outputFormat = AV_SAMPLE_FMT_S32
            bitsPerSample = 32
        }

        let bytesPerSample = bitsPerSample / 8
        let outputBufferSize = Int(nbSamples) * Int(channels) * bytesPerSample

        // Fast path: already interleaved in the target format
        if sampleFormat == outputFormat, let data = frame.pointee.data.0 {
            let pcmData = Data(bytes: data, count: outputBufferSize)
            return buildDecodedFrame(
                data: pcmData, sampleCount: Int(nbSamples),
                sampleRate: Int(sampleRate), channels: Int(channels),
                bitsPerSample: bitsPerSample, framePTS: frame.pointee.pts,
                packetTimebase: packetTimebase
            )
        }

        // Need conversion: set up or reconfigure swresample
        if swrContext == nil || outputSampleRate != Int(sampleRate) ||
           outputChannels != Int(channels) || outputBitsPerSample != bitsPerSample {
            setupSwresample(frame: frame, outputFormat: outputFormat)
        }

        guard let swrCtx = swrContext else {
            print("[AudioDecoder] No swresample context available")
            return nil
        }

        // Allocate output buffer
        var outputBuffer: UnsafeMutablePointer<UInt8>?
        av_samples_alloc(&outputBuffer, nil, channels, nbSamples, outputFormat, 0)
        guard let outBuf = outputBuffer else { return nil }
        defer { av_freep(&outputBuffer) }

        // Bridge AVFrame.data tuple → pointer array for swr_convert input
        let convertedSamples: Int32 = withUnsafePointer(to: frame.pointee.data) { dataPtr in
            let inputPtr = UnsafeRawPointer(dataPtr)
                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            var outPtr: UnsafeMutablePointer<UInt8>? = outBuf
            return swr_convert(
                swrCtx,
                &outPtr, nbSamples,
                UnsafeMutablePointer(mutating: inputPtr), nbSamples
            )
        }

        guard convertedSamples > 0 else {
            print("[AudioDecoder] swr_convert returned \(convertedSamples)")
            return nil
        }

        let actualSize = Int(convertedSamples) * Int(channels) * bytesPerSample
        let pcmData = Data(bytes: outBuf, count: actualSize)

        return buildDecodedFrame(
            data: pcmData, sampleCount: Int(convertedSamples),
            sampleRate: Int(sampleRate), channels: Int(channels),
            bitsPerSample: bitsPerSample, framePTS: frame.pointee.pts,
            packetTimebase: packetTimebase
        )
    }

    private func buildDecodedFrame(data: Data, sampleCount: Int, sampleRate: Int,
                                   channels: Int, bitsPerSample: Int,
                                   framePTS: Int64,
                                   packetTimebase: CMTime) -> DecodedAudioFrame {
        let pts: CMTime
        if framePTS != Int64.min && framePTS >= 0 {
            pts = CMTimeMake(value: framePTS, timescale: packetTimebase.timescale)
        } else {
            pts = .invalid
        }

        return DecodedAudioFrame(
            data: data,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            pts: pts
        )
    }

    /// Set up libswresample for format/layout conversion.
    private func setupSwresample(frame: UnsafeMutablePointer<AVFrame>,
                                 outputFormat: AVSampleFormat) {
        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }

        let channels = frame.pointee.ch_layout.nb_channels
        let sampleRate = frame.pointee.sample_rate

        swrContext = swr_alloc()
        guard swrContext != nil else {
            print("[AudioDecoder] Failed to allocate SwrContext")
            return
        }

        // Configure: same channel layout, but convert sample format (planar → interleaved)
        var inLayout = frame.pointee.ch_layout
        swr_alloc_set_opts2(
            &swrContext,
            &inLayout, outputFormat, sampleRate,       // output
            &inLayout, AVSampleFormat(rawValue: frame.pointee.format), sampleRate,  // input
            0, nil
        )

        let ret = swr_init(swrContext)
        guard ret >= 0 else {
            swr_free(&swrContext)
            swrContext = nil
            print("[AudioDecoder] swr_init failed: \(ret)")
            return
        }

        self.outputSampleRate = Int(sampleRate)
        self.outputChannels = Int(channels)
        self.outputBitsPerSample = Int(av_get_bytes_per_sample(outputFormat)) * 8

        print("[AudioDecoder] SwrContext initialized: \(channels)ch \(sampleRate)Hz \(outputBitsPerSample)-bit")
    }
}

// MARK: - AVERROR Constants

/// AVERROR(EAGAIN) on Darwin: -(EAGAIN) = -35
private let kAudioDecoderEAGAIN: Int32 = -35

/// AVERROR_EOF: FFERRTAG('E','O','F',' ')
private let kAudioDecoderEOF: Int32 = {
    let tag = Int32(bitPattern:
        (UInt32(Character("E").asciiValue!) |
        (UInt32(Character("O").asciiValue!) << 8) |
        (UInt32(Character("F").asciiValue!) << 16) |
        (UInt32(Character(" ").asciiValue!) << 24)))
    return -tag
}()

#else

// =============================================================================
// MARK: - Stub Implementation (FFmpeg not available)
// =============================================================================

/// Stub audio decoder when FFmpeg libraries are not linked.
final class FFmpegAudioDecoder: @unchecked Sendable {

    static let supportedCodecs: Set<String> = []
    static let isAvailable = false

    init(codecpar: UnsafeRawPointer, codecNameHint: String? = nil) throws {
        throw FFmpegError.notAvailable
    }

    func decode(_ packet: DemuxedPacket) -> [DecodedAudioFrame] { [] }
    func decodeAndBatch(_ packet: DemuxedPacket) -> [DecodedAudioFrame] { [] }
    func flushBatch() -> DecodedAudioFrame? { nil }

    func createPCMSampleBuffer(from frame: DecodedAudioFrame) throws -> CMSampleBuffer {
        throw FFmpegError.notAvailable
    }

    func close() {}
}

#endif
