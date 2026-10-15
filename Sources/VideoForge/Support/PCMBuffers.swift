//
//  PCMBuffers.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Interleaved float samples as a sample buffer a writer input takes.
//

import CoreMedia
import Foundation

/// Wraps samples for a writer.
enum PCMBuffers {

    /// The format of interleaved 32-bit float sound.
    static func description(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytes = UInt32(4 * channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// `interleaved` as one sample buffer starting at frame `frame`.
    static func sampleBuffer(_ interleaved: [Float], sampleRate: Double, channels: Int,
                             at frame: Int) -> CMSampleBuffer? {
        let frames = interleaved.count / max(1, channels)
        guard frames > 0 else { return nil }
        var basic = description(sampleRate: sampleRate, channels: channels)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &basic, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let length = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: length)
        }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        let scale = CMTimeScale(sampleRate.rounded())
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: scale),
            packetDescriptions: nil, sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }
}
