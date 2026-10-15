//
//  AudioRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  How the writer road re-encodes sound when it has to — after a speed
//  change, or a join — as settings dictionaries built from plain values.
//
//  MEASURED from the presets this road stands in for: `HighestQuality` and
//  the HEVC presets write AAC at the source's sample rate and channel
//  count; the ProRes presets write 32-bit float PCM. Sound that is not
//  re-timed is copied untouched on both roads.
//
//  MEASURED: left to choose, the writer's AAC encoder spent 25 kb/s on a
//  stereo tone the export session wrote at 113 kb/s. So the source's own
//  rate is asked for, kept between 32 and 160 kb/s a channel.
//

import AVFoundation
import CoreMedia
import Foundation

/// The writer road's audio settings.
enum AudioRules {

    /// What sound is decoded to: interleaved 32-bit float PCM.
    static var decoded: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }

    /// What decoded sound is written as, matching the source's rate and
    /// channels: float PCM beside ProRes, AAC otherwise.
    ///
    /// - Parameters:
    ///   - sampleRate: The source's sample rate; 0 when unknown.
    ///   - channels: The source's channel count; 0 when unknown.
    ///   - layout: The source's channel layout, as data, when there is one —
    ///     AAC needs it for more than two channels.
    ///   - bitRate: The source's estimated rate; 0 when unknown.
    ///   - codec: The video codec beside it.
    /// - Returns: `AVAssetWriterInput` output settings.
    static func encoded(sampleRate: Double, channels: Int, layout: Data?, bitRate: Double = 0,
                        codec: VideoCodec) -> [String: Any] {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        let count = max(1, channels)
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: count]
        if codec.isIntraFrame {
            settings.merge(decoded) { $1 }
        } else {
            // AAC-LC tops out at 48 kHz on Apple's encoder.
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVSampleRateKey] = min(rate, 48_000)
            settings[AVEncoderBitRateKey] = aacBitRate(source: bitRate, channels: count)
        }
        if count > 2, let layout { settings[AVChannelLayoutKey] = layout }
        return settings
    }

    /// The AAC rate asked for: the source's, or 64 kb/s a channel when it
    /// is unknown, kept between 32 and 160 kb/s a channel.
    static func aacBitRate(source: Double, channels: Int) -> Int {
        let count = Double(max(1, channels))
        let wanted = source > 0 ? source : 64_000 * count
        return Int(min(160_000 * count, max(32_000 * count, wanted)))
    }

    /// ``encoded(sampleRate:channels:layout:bitRate:codec:)`` for a source
    /// format description.
    static func encoded(like description: CMFormatDescription?, bitRate: Double,
                        codec: VideoCodec) -> [String: Any] {
        guard let description,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return encoded(sampleRate: 0, channels: 2, layout: nil, bitRate: bitRate, codec: codec)
        }
        var size = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size)
            .map { Data(bytes: $0, count: size) }
        return encoded(sampleRate: basic.mSampleRate, channels: Int(basic.mChannelsPerFrame),
                       layout: layout, bitRate: bitRate, codec: codec)
    }
}
