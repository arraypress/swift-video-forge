//
//  MixedSound.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A clip's sound with a music bed under it and sound effects in it, made
//  a buffer at a time — once to measure its peak, once more to write it.
//  The one mixer behind `addMusic`, `addSounds` and `soundtrack`. The
//  clip's sound is streamed from the file both times rather than held, so
//  an hour-long clip costs a few buffers of memory; only the music and the
//  effects are held whole.
//

import AVFoundation
import Foundation

/// A sound track made by mixing, ready to be written.
struct MixedSound: Sendable {
    /// The clip whose sound goes on top; nil for silence under the music.
    let clip: URL?
    /// The mix's rate and channels: the clip's own.
    let sampleRate: Double
    let channels: Int
    /// The music and its gain, when there is music.
    let mixer: BedMixer?
    /// The sound effects, each at its frame and gain.
    let cues: [CueLayer]
    /// How many frames to make: the clip's length.
    let frames: Int
    /// The gain on the whole mix, linear.
    let mixGain: Float
    /// The clip's sound format, for the encoder: its layout when it has
    /// more than two channels, its rate of bits, the video codec beside it.
    let layout: Data?
    let bitRate: Double
    let codec: VideoCodec

    /// Frames made per buffer.
    static let chunk = 4096

    /// The same sound with another gain on the whole mix.
    func with(mixGain: Float) -> MixedSound {
        MixedSound(clip: clip, sampleRate: sampleRate, channels: channels, mixer: mixer, cues: cues, frames: frames,
                   mixGain: mixGain, layout: layout, bitRate: bitRate, codec: codec)
    }

    /// The mix of `clip` (interleaved, or nil for silence), the bed and the
    /// effects for `count` frames from `first`, scaled by `mixGain`.
    func mix(_ clip: [Float]?, from first: Int, count: Int) -> [Float] {
        var out = mixer?.bed(from: first, count: count) ?? [Float](repeating: 0, count: count * channels)
        if let clip { for index in 0..<min(out.count, clip.count) { out[index] += clip[index] } }
        for cue in cues { cue.add(into: &out, from: first, channels: channels) }
        if mixGain != 1 { for index in out.indices { out[index] *= mixGain } }
        return out
    }

    /// Every buffer, in order, to `body` — for measuring.
    func run(_ body: ([Float]) throws -> Void) async throws {
        let source = try await Run(self)
        while let buffer = try source.next() { try body(buffer.samples) }
    }

    /// A writer input for the mix, added to `writer`, and the feed that
    /// fills it: AAC, or float PCM beside ProRes, as the presets write.
    func feed(into writer: AVAssetWriter, url: URL) async throws -> WriterFeed {
        let (rate, channels) = (sampleRate, self.channels)
        var settings = AudioRules.encoded(sampleRate: rate, channels: channels, layout: layout,
                                          bitRate: bitRate, codec: codec)
        if !writer.canApply(outputSettings: settings, forMediaType: .audio) { settings[AVEncoderBitRateKey] = nil }
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw VideoForgeError.writeFailed(url, reason: "the writer will not take \(channels)-channel sound at \(Int(rate)) Hz")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw VideoForgeError.writeFailed(url, reason: "the writer refused the mixed sound") }
        writer.add(input)
        let source = try await Run(self)
        return WriterFeed(input: input) {
            guard let buffer = try source.next() else { return false }
            guard let sample = PCMBuffers.sampleBuffer(buffer.samples, sampleRate: rate, channels: channels,
                                                       at: buffer.frame) else {
                throw VideoForgeError.writeFailed(url, reason: "a buffer of the mixed sound could not be made")
            }
            input.append(sample)
            return true
        }
    }

    /// One pass over the mix.
    final class Run {
        private let sound: MixedSound
        private let stream: PCMStream?
        private var pending: [Float] = []
        private var position = 0

        init(_ sound: MixedSound) async throws {
            self.sound = sound
            if let clip = sound.clip {
                stream = try await PCMStream(clip, rate: sound.sampleRate, channels: sound.channels)
            } else {
                stream = nil
            }
        }

        /// The next buffer and the frame it starts at; nil at the end.
        func next() throws -> (frame: Int, samples: [Float])? {
            guard position < sound.frames else { return nil }
            let count = min(MixedSound.chunk, sound.frames - position)
            let wanted = count * sound.channels
            var clip: [Float]?
            if let stream {
                while pending.count < wanted, let more = stream.next() { pending += more }
                if stream.failed { throw VideoForgeError.unreadable(sound.clip!, reason: "its sound stopped decoding partway") }
                let take = min(wanted, pending.count)
                clip = Array(pending.prefix(take))
                pending.removeFirst(take)
            }
            let frame = position
            position += count
            return (frame, sound.mix(clip, from: frame, count: count))
        }
    }
}

/// One sound effect in a mix: its samples, interleaved at the mix's rate
/// and channels, where it starts, and its gain.
struct CueLayer: Sendable {
    let samples: [Float]
    let start: Int
    let gain: Float

    /// Adds its share of `count = out.count / channels` frames from `first`.
    func add(into out: inout [Float], from first: Int, channels: Int) {
        let count = out.count / max(1, channels)
        let length = samples.count / max(1, channels)
        let low = max(first, start), high = min(first + count, start + length)
        guard low < high else { return }
        for frame in low..<high {
            for channel in 0..<channels {
                out[(frame - first) * channels + channel] += samples[(frame - start) * channels + channel] * gain
            }
        }
    }
}
