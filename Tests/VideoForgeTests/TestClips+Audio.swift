//
//  TestClips+Audio.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Sound read back out of a movie, and measured: a tone's level by a
//  single-bin DFT (Goertzel), so one sound can be measured under another
//  without separating them — the music in a mix is a tone at a frequency
//  the speech fixture leaves alone.
//

import AVFoundation
import Foundation

extension TestClips {

    /// A movie's (first) sound, decoded to mono float at `rate`.
    static func monoSamples(of url: URL, rate: Double = 48_000) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                                          destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    /// The level of a tone at `hz` in `samples[range]`, in dBFS of a sine's
    /// peak: a full-scale sine reads 0, one at 0.3 reads −10.5.
    static func toneLevel(_ samples: [Float], hz: Double, rate: Double = 48_000, in range: Range<Int>) -> Double {
        let range = range.clamped(to: 0..<samples.count)
        guard range.count > 16 else { return -.infinity }
        let k = 2 * cos(2 * .pi * hz / rate)
        var (s1, s2) = (0.0, 0.0)
        // A Hann window keeps a strong neighbour from leaking in.
        let n = Double(range.count)
        for (index, sample) in samples[range].enumerated() {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / (n - 1))
            let s = Double(sample) * window + k * s1 - s2
            (s2, s1) = (s1, s)
        }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        let amplitude = 2 * power.squareRoot() / (n * 0.5)
        return 20 * log10(max(amplitude, 1e-12))
    }

    /// A tone written through `AVAudioFile` at `rate`, `seconds` long, at
    /// peak `amplitude`, starting silent for `delay` seconds.
    static func writeTone(to url: URL, seconds: Double, hz: Double, amplitude: Float = 0.3,
                          rate: Double = 48_000, channels: AVAudioChannelCount = 2) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else { return }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData?[channel][index] = amplitude * Float(sin(Double(index) * 2 * .pi * hz / rate))
            }
        }
        try file.write(from: buffer)
    }
}
