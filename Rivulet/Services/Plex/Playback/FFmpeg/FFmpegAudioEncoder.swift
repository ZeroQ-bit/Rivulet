//
//  FFmpegAudioEncoder.swift
//  Rivulet
//
//  Re-encodes decoded PCM audio (from DTS/TrueHD) to EAC3 for surround
//  passthrough over AirPlay to HomePods. HomePods support EAC3 natively,
//  so this preserves the original 5.1/7.1 channel layout instead of
//  downmixing to stereo PCM.
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Encoded Audio Frame

/// Compressed EAC3 audio packet ready for CMSampleBuffer creation.
struct EncodedAudioFrame: Sendable {
    let data: Data          // Compressed EAC3 packet
    let sampleCount: Int    // Always 1536 for EAC3
    let sampleRate: Int     // 48000
    let channels: Int       // 6 or 8
    let pts: CMTime
}

// =============================================================================
// MARK: - FFmpeg Implementation (when libraries are available)
// =============================================================================

#if RIVULET_FFMPEG
import Libavcodec
import Libavutil
import Libswresample

/// Re-encodes interleaved F32 PCM to EAC3 using libavcodec + libswresample.
final class FFmpegAudioEncoder: @unchecked Sendable {

    static let isAvailable = true

    // MARK: - Private State

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var inputFrame: UnsafeMutablePointer<AVFrame>?
    private var isOpen = false

    private let channels: Int
    private let sampleRate: Int
    private let bitsPerSample: Int
    private let bytesPerSample: Int
    private let bytesPerInputFrame: Int  // bytes for 1536 samples * channels * bytesPerSample

    // Accumulation buffer for PCM input
    private var inputBuffer = Data()
    private var inputBufferSampleCount = 0
    private var nextPTS: CMTime = .invalid

    // Cached format description for output CMSampleBuffers
    private var cachedFormatDescription: CMAudioFormatDescription?

    // Diagnostics
    private var encodedFrameCount = 0
    private var lastEncodedPTS: CMTime = .invalid
    private var minPacketBytes = Int.max
    private var maxPacketBytes = 0
    private var totalPacketBytes = 0

    /// EAC3 frame size in samples
    private static let frameSize = 1536

    // MARK: - Init

    /// Open an EAC3 encoder for the given channel/sample-rate configuration.
    /// - Parameters:
    ///   - channels: Number of audio channels (e.g. 6 for 5.1, 8 for 7.1)
    ///   - sampleRate: Input sample rate (typically 48000)
    ///   - bitsPerSample: Input bits per sample (32 for F32 PCM from decoder)
    init(channels: Int, sampleRate: Int, bitsPerSample: Int) throws {
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.bytesPerSample = bitsPerSample / 8
        self.bytesPerInputFrame = Self.frameSize * channels * (bitsPerSample / 8)

        guard let codec = avcodec_find_encoder(AV_CODEC_ID_EAC3) else {
            print("[AudioEncoder] EAC3 encoder not found in FFmpeg build")
            throw FFmpegError.unsupportedCodec("eac3")
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FFmpegError.allocationFailed
        }

        // Configure encoder
        ctx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP  // EAC3 encoder requires planar float
        ctx.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&ctx.pointee.ch_layout, Int32(channels))

        // Bitrate: 640kbps for 5.1, 1280kbps for 7.1
        ctx.pointee.bit_rate = channels > 6 ? 1_280_000 : 640_000

        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx

        let ret = avcodec_open2(ctx, codec, nil)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            print("[AudioEncoder] avcodec_open2 failed: \(ret)")
            throw FFmpegError.openFailed(averror: ret)
        }

        guard let frame = av_frame_alloc() else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.allocationFailed
        }

        // Configure the reusable input frame
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&frame.pointee.ch_layout, Int32(channels))
        frame.pointee.nb_samples = Int32(Self.frameSize)

        let allocRet = av_frame_get_buffer(frame, 0)
        guard allocRet >= 0 else {
            av_frame_free(&inputFrame)
            avcodec_free_context(&mutableCtx)
            print("[AudioEncoder] av_frame_get_buffer failed: \(allocRet)")
            throw FFmpegError.allocationFailed
        }

        self.codecContext = ctx
        self.inputFrame = frame
        self.isOpen = true

        // Verify encoder's frame size matches our assumption
        let encoderFrameSize = Int(ctx.pointee.frame_size)
        if encoderFrameSize > 0 && encoderFrameSize != Self.frameSize {
            print("[AudioEncoder] WARNING: encoder frame_size=\(encoderFrameSize) != expected \(Self.frameSize)")
        }

        // Set up swresample: interleaved F32 -> planar float (encoder input format)
        try setupSwresample()

        print("[AudioEncoder] Opened EAC3 encoder: \(channels)ch \(sampleRate)Hz " +
              "bitrate=\(ctx.pointee.bit_rate/1000)kbps " +
              "frame_size=\(encoderFrameSize) initial_padding=\(ctx.pointee.initial_padding)")
    }

    deinit { close() }

    // MARK: - Encode

    /// Encode decoded PCM frames to EAC3. Accumulates input until 1536 samples
    /// are available, then encodes one EAC3 frame.
    /// - Returns: Zero or more encoded EAC3 frames.
    func encode(_ frame: DecodedAudioFrame) -> [EncodedAudioFrame] {
        guard isOpen else { return [] }

        if encodedFrameCount == 0 {
            print("[AudioEncoder] Input frame #1: pts=\(String(format: "%.3f", CMTimeGetSeconds(frame.pts)))s " +
                  "samples=\(frame.sampleCount) rate=\(frame.sampleRate)Hz ch=\(frame.channels) bits=\(frame.bitsPerSample)")
        }

        // Track PTS of first sample in the accumulation buffer
        if inputBufferSampleCount == 0 {
            nextPTS = frame.pts
        }

        inputBuffer.append(frame.data)
        inputBufferSampleCount += frame.sampleCount

        var output: [EncodedAudioFrame] = []

        // Encode complete 1536-sample frames
        while inputBufferSampleCount >= Self.frameSize {
            if let encoded = encodeOneFrame() {
                output.append(encoded)
            }
        }

        return output
    }

    /// Flush remaining buffered samples (call on seek/stop/EOS).
    /// Pads to 1536 with silence if needed, then drains the encoder.
    func flush() -> [EncodedAudioFrame] {
        guard isOpen else { return [] }
        var output: [EncodedAudioFrame] = []

        if inputBufferSampleCount > 0 {
            print("[AudioEncoder] Flush requested: bufferedSamples=\(inputBufferSampleCount) " +
                  "bufferedBytes=\(inputBuffer.count) nextPTS=\(nextPTS.isValid ? String(format: "%.3f", CMTimeGetSeconds(nextPTS)) : "invalid")")
        }

        // Pad remaining buffer to 1536 samples with silence
        if inputBufferSampleCount > 0 && inputBufferSampleCount < Self.frameSize {
            let paddingSamples = Self.frameSize - inputBufferSampleCount
            let paddingBytes = paddingSamples * channels * bytesPerSample
            inputBuffer.append(Data(count: paddingBytes))
            inputBufferSampleCount = Self.frameSize

            if let encoded = encodeOneFrame() {
                output.append(encoded)
            }
        }

        // Drain encoder's internal buffers
        guard let ctx = codecContext else { return output }

        avcodec_send_frame(ctx, nil)

        var avPacket = av_packet_alloc()
        guard let pkt = avPacket else { return output }
        defer { av_packet_free(&avPacket) }

        while true {
            let ret = avcodec_receive_packet(ctx, pkt)
            if ret == kAudioEncoderEAGAIN || ret == kAudioEncoderEOF { break }
            guard ret >= 0 else { break }

            let data = Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size))
            let pts = nextPTS.isValid ? nextPTS : .zero
            output.append(EncodedAudioFrame(
                data: data,
                sampleCount: Self.frameSize,
                sampleRate: sampleRate,
                channels: channels,
                pts: pts
            ))
            advancePTS()
        }

        return output
    }

    // MARK: - CMSampleBuffer Creation

    /// Create a compressed EAC3 CMSampleBuffer from an encoded frame.
    /// Mirrors FFmpegDemuxer.createAudioSampleBuffer() pattern.
    func createEAC3SampleBuffer(from frame: EncodedAudioFrame) throws -> CMSampleBuffer {
        let fd = try getOrCreateFormatDescription()

        // Create block buffer with compressed data
        var blockBuffer: CMBlockBuffer?
        let dataCount = frame.data.count

        var status = frame.data.withUnsafeBytes { rawBuf -> OSStatus in
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

        // One compressed packet per sample buffer (sampleCount=1)
        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(dataCount)
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fd,
            sampleCount: 1,
            presentationTimeStamp: frame.pts,
            packetDescriptions: &packetDescription,
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

        if encodedFrameCount > 0 {
            let avgPacketBytes = totalPacketBytes / max(encodedFrameCount, 1)
            print("[AudioEncoder] Summary: frames=\(encodedFrameCount) packetBytes[min=\(minPacketBytes),avg=\(avgPacketBytes),max=\(maxPacketBytes)]")
        }

        inputBuffer = Data()
        inputBufferSampleCount = 0
        nextPTS = .invalid
        encodedFrameCount = 0
        lastEncodedPTS = .invalid
        minPacketBytes = Int.max
        maxPacketBytes = 0
        totalPacketBytes = 0

        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }

        if inputFrame != nil {
            av_frame_free(&inputFrame)
            inputFrame = nil
        }

        if codecContext != nil {
            avcodec_free_context(&codecContext)
            codecContext = nil
        }

        cachedFormatDescription = nil
        print("[AudioEncoder] Closed")
    }

    // MARK: - Private: Encode One Frame

    /// Extract 1536 samples from inputBuffer, convert to planar, encode.
    private func encodeOneFrame() -> EncodedAudioFrame? {
        guard let ctx = codecContext, let frame = inputFrame, let swrCtx = swrContext else { return nil }

        let bytesNeeded = bytesPerInputFrame
        guard inputBuffer.count >= bytesNeeded else { return nil }

        // Extract exactly 1536 samples worth of interleaved PCM
        let chunk = inputBuffer.prefix(bytesNeeded)
        inputBuffer.removeFirst(bytesNeeded)
        inputBufferSampleCount -= Self.frameSize

        // Make the frame writable
        av_frame_make_writable(frame)

        // Convert interleaved F32 -> planar float via swresample.
        // Output is planar (one buffer per channel), so swr_convert needs
        // a pointer to the array of plane pointers in frame.data.
        let convertedSamples: Int32 = chunk.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return 0 }
            var inPtr: UnsafePointer<UInt8>? = baseAddress.assumingMemoryBound(to: UInt8.self)

            // frame.pointee.data is a tuple of 8 UnsafeMutablePointer<UInt8>? values
            // laid out as a contiguous array of pointers in the heap-allocated AVFrame.
            // Use withUnsafeMutablePointer to safely get the address of the data tuple.
            return withUnsafeMutablePointer(to: &frame.pointee.data) { dataPtr in
                let outPtr = UnsafeMutableRawPointer(dataPtr)
                    .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                return swr_convert(
                    swrCtx,
                    outPtr, Int32(Self.frameSize),
                    &inPtr, Int32(Self.frameSize)
                )
            }
        }

        guard convertedSamples > 0 else {
            print("[AudioEncoder] swr_convert failed: \(convertedSamples)")
            return nil
        }

        frame.pointee.nb_samples = convertedSamples
        frame.pointee.pts = Int64(nextPTS.isValid ? CMTimeGetSeconds(nextPTS) * Double(sampleRate) : 0)

        // Send frame to encoder
        var ret = avcodec_send_frame(ctx, frame)
        guard ret >= 0 else {
            print("[AudioEncoder] avcodec_send_frame error: \(ret)")
            return nil
        }

        // Receive encoded packet
        var avPacket = av_packet_alloc()
        guard let pkt = avPacket else { return nil }
        defer { av_packet_free(&avPacket) }

        ret = avcodec_receive_packet(ctx, pkt)
        if ret == kAudioEncoderEAGAIN || ret == kAudioEncoderEOF { return nil }
        guard ret >= 0 else {
            print("[AudioEncoder] avcodec_receive_packet error: \(ret)")
            return nil
        }

        let data = Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size))
        let pts = nextPTS.isValid ? nextPTS : .zero
        encodedFrameCount += 1
        totalPacketBytes += data.count
        minPacketBytes = min(minPacketBytes, data.count)
        maxPacketBytes = max(maxPacketBytes, data.count)
        let packetPTSDelta = lastEncodedPTS.isValid ? CMTimeGetSeconds(CMTimeSubtract(pts, lastEncodedPTS)) : -1
        if encodedFrameCount <= 6 || encodedFrameCount % 120 == 0 {
            print("[AudioEncoder] Encoded packet #\(encodedFrameCount): pts=\(String(format: "%.3f", CMTimeGetSeconds(pts)))s " +
                  "delta=\(packetPTSDelta >= 0 ? String(format: "%.4f", packetPTSDelta) : "n/a")s " +
                  "bytes=\(data.count) queuedInputSamples=\(inputBufferSampleCount) " +
                  "ffPts=\(pkt.pointee.pts) ffDur=\(pkt.pointee.duration)")
        }
        lastEncodedPTS = pts
        advancePTS()

        return EncodedAudioFrame(
            data: data,
            sampleCount: Self.frameSize,
            sampleRate: sampleRate,
            channels: channels,
            pts: pts
        )
    }

    /// Advance nextPTS by one EAC3 frame (1536 samples).
    private func advancePTS() {
        guard nextPTS.isValid else { return }
        let frameDuration = CMTime(value: CMTimeValue(Self.frameSize), timescale: Int32(sampleRate))
        nextPTS = CMTimeAdd(nextPTS, frameDuration)
    }

    // MARK: - Private: Swresample Setup

    /// Set up swresample to convert interleaved F32 → planar float.
    private func setupSwresample() throws {
        swrContext = swr_alloc()
        guard swrContext != nil else {
            throw FFmpegError.allocationFailed
        }

        var inLayout = AVChannelLayout()
        av_channel_layout_default(&inLayout, Int32(channels))
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(channels))

        // Input: interleaved float (from decoder)
        // Output: planar float (encoder requirement)
        swr_alloc_set_opts2(
            &swrContext,
            &outLayout, AV_SAMPLE_FMT_FLTP, Int32(sampleRate),  // output (planar)
            &inLayout, AV_SAMPLE_FMT_FLT, Int32(sampleRate),    // input (interleaved)
            0, nil
        )

        let ret = swr_init(swrContext)
        guard ret >= 0 else {
            swr_free(&swrContext)
            swrContext = nil
            print("[AudioEncoder] swr_init failed: \(ret)")
            throw FFmpegError.openFailed(averror: ret)
        }
    }

    // MARK: - Private: Format Description

    /// Get or create a cached EAC3 CMAudioFormatDescription.
    private func getOrCreateFormatDescription() throws -> CMAudioFormatDescription {
        if let cached = cachedFormatDescription { return cached }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatEnhancedAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.frameSize),  // 1536
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Include encoder extradata as magic cookie if present
        let extradata = codecContext?.pointee.extradata
        let extradataSize = Int(codecContext?.pointee.extradata_size ?? 0)

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: extradataSize,
            magicCookie: extradata,
            extensions: nil,
            formatDescriptionOut: &desc
        )

        guard status == noErr, let fd = desc else {
            throw FFmpegError.formatDescriptionFailed(status: status)
        }

        cachedFormatDescription = fd
        print("[AudioEncoder] Created EAC3 format description: \(channels)ch \(sampleRate)Hz" +
              (extradataSize > 0 ? " cookie=\(extradataSize)B" : ""))
        return fd
    }
}

// MARK: - AVERROR Constants

private let kAudioEncoderEAGAIN: Int32 = -35
private let kAudioEncoderEOF: Int32 = {
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

/// Stub audio encoder when FFmpeg libraries are not linked.
final class FFmpegAudioEncoder: @unchecked Sendable {

    static let isAvailable = false

    init(channels: Int, sampleRate: Int, bitsPerSample: Int) throws {
        throw FFmpegError.notAvailable
    }

    func encode(_ frame: DecodedAudioFrame) -> [EncodedAudioFrame] { [] }
    func flush() -> [EncodedAudioFrame] { [] }

    func createEAC3SampleBuffer(from frame: EncodedAudioFrame) throws -> CMSampleBuffer {
        throw FFmpegError.notAvailable
    }

    func close() {}
}

#endif
