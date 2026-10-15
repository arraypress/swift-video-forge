//
//  TestClips+Speech.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A talking clip with known speech: `say` sentences placed at known
//  times over a grey picture, so where somebody talks is ground truth, not
//  a guess. The voices are the system's own.
//

import AVFoundation
import Foundation
@testable import VideoForge

extension TestClips {

    /// The sentences, their voices, and the silence before each.
    static let sentences: [(voice: String, text: String, gap: Double)] = [
        ("Samantha", "Welcome back. Today we are looking at something a little different.", 1.2),
        ("Daniel", "The first thing you need is a good light, just to one side.", 2.5),
        ("Samantha", "And that is all there is to it.", 3.0),
    ]

    /// Writes the talking clip and returns where each sentence is, in
    /// seconds — from its first sound to its last.
    @discardableResult
    static func writeSpeechMovie(to url: URL, tail: Double = 2, rate: Double = 48_000) async throws -> [ClosedRange<Double>] {
        let folder = url.deletingLastPathComponent()
        var samples: [Float] = []
        var truth: [ClosedRange<Double>] = []
        for (index, sentence) in sentences.enumerated() {
            let spoken = folder.appendingPathComponent("sentence-\(index).caf")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", sentence.voice, "-o", spoken.path, "--data-format=LEF32@48000", sentence.text]
            try say.run()
            say.waitUntilExit()
            let file = try AVAudioFile(forReading: spoken)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            let voice = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let (first, last) = soundingExtent(voice)
            samples += [Float](repeating: 0, count: Int(sentence.gap * rate))
            truth.append(Double(samples.count) / rate...Double(samples.count + last - first) / rate)
            samples += voice[first..<last]
            try? FileManager.default.removeItem(at: spoken)
        }
        samples += [Float](repeating: 0, count: Int(tail * rate))
        let seconds = Double(samples.count) / rate

        let sound = folder.appendingPathComponent("speech.caf")
        try writeMono(samples, rate: rate, to: sound)
        let picture = folder.appendingPathComponent("speech-picture.mov")
        try await writeDrawn(to: picture, seconds: seconds, width: 320, height: 180) { context, _ in
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        let composition = AVMutableComposition()
        for (asset, type) in [(AVURLAsset(url: picture), AVMediaType.video), (AVURLAsset(url: sound), AVMediaType.audio)] {
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let track = composition.addMutableTrack(withMediaType: type,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
                                      of: source, at: .zero)
        }
        try? FileManager.default.removeItem(at: url)
        try await Composer.export(composition, to: url, container: .mov, preset: AVAssetExportPresetHighestQuality)
        try? FileManager.default.removeItem(at: picture)
        try? FileManager.default.removeItem(at: sound)
        return truth
    }

    /// Mono samples written as a CAF.
    static func writeMono(_ samples: [Float], rate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// The first and last sample of a recording's sound: 10 ms frames over
    /// −50 dBFS.
    static func soundingExtent(_ samples: [Float]) -> (Int, Int) {
        let frame = 480
        var (first, last) = (-1, 0)
        for start in stride(from: 0, to: max(0, samples.count - frame), by: frame) {
            var sum: Float = 0
            for index in start..<(start + frame) { sum += samples[index] * samples[index] }
            if 10 * log10(sum / Float(frame) + 1e-14) > -50 {
                if first < 0 { first = start }
                last = start + frame
            }
        }
        return (max(0, first), max(first, last))
    }
}
