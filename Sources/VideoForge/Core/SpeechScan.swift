//
//  SpeechScan.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One pass over a clip's sound that learns everything a music bed needs:
//  the speech-band level of every 20 ms (SpeechLevels), Apple's sound
//  classifier's speech score for overlapping windows, and the clip's own
//  loudness. On-device and offline — SoundAnalysis's built-in classifier
//  ships with the OS.
//

import AVFoundation
import Foundation
import SoundAnalysis
import Synchronization

/// What one pass over a clip's sound learned.
struct SpeechScan {
    let sampleRate: Double
    let channels: Int
    /// Seconds of sound.
    let duration: Double
    /// The speech-band level of every 20 ms frame.
    let levels: [Double]
    /// The classifier's windows and their speech scores.
    let windows: [(start: Double, end: Double, score: Double)]
    /// The clip's loudness meter, for the loudness of its speech.
    let loudness: LoudnessMeter

    /// The classifier's window. MEASURED against 1 s and 3 s (the
    /// model's default) — see SpeechDetection.
    static let window = 0.5
    /// How much each window shares with the next: a score every 0.125 s.
    static let overlap = 0.75

    /// Reads `url`'s sound once.
    ///
    /// - Parameters:
    ///   - url: The clip.
    ///   - classifies: Run the sound classifier too.
    /// - Throws: ``VideoForgeError/noAudioTrack(_:)``,
    ///   ``VideoForgeError/unreadable(_:reason:)``.
    static func run(_ url: URL, classifies: Bool, window: Double = window) async throws -> SpeechScan {
        let stream = try await PCMStream(url)
        let (rate, channels) = (stream.sampleRate, stream.channels)
        var levels = SpeechLevels(sampleRate: rate)
        var meter = LoudnessMeter(sampleRate: rate, channels: channels)
        let listener = classifies ? try Listener(sampleRate: rate, window: window) : nil
        var frames = 0
        while let chunk = stream.next() {
            meter.add(chunk)
            let mono = Self.mono(chunk, channels: channels)
            levels.add(mono)
            listener?.hear(mono, at: frames)
            frames += mono.count
        }
        if stream.failed { throw VideoForgeError.unreadable(url, reason: "its sound stopped decoding partway") }
        return SpeechScan(sampleRate: rate, channels: channels, duration: Double(frames) / rate,
                          levels: levels.levels, windows: listener?.finish() ?? [], loudness: meter)
    }

    /// Interleaved frames averaged to one channel.
    static func mono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let count = interleaved.count / channels
        var out = [Float](repeating: 0, count: count)
        let scale = 1 / Float(channels)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
            out[frame] = sum * scale
        }
        return out
    }

    /// The speech the chosen detection finds.
    func speech(_ detection: SpeechDetection) -> [ClosedRange<Double>] {
        let energy = SpeechActivity.energySegments(levels)
        switch detection {
        case .energy: return energy
        case .classifier: return SpeechActivity.classifierSegments(windows)
        case .both: return SpeechActivity.confirmed(levels: levels, classifier: SpeechActivity.classifierSegments(windows))
        }
    }

    // MARK: - The classifier

    /// Apple's sound classifier, fed mono buffers.
    private final class Listener {
        private let analyzer: SNAudioStreamAnalyzer
        private let observer = Observer()
        private let format: AVAudioFormat

        init(sampleRate: Double, window: Double) throws {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw VideoForgeError.invalidOptions("no sound format at \(sampleRate) Hz")
            }
            self.format = format
            analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: window, preferredTimescale: 48_000)
            request.overlapFactor = SpeechScan.overlap
            try analyzer.add(request, withObserver: observer)
        }

        func hear(_ mono: [Float], at position: Int) {
            guard !mono.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(mono.count)
            mono.withUnsafeBufferPointer { source in
                buffer.floatChannelData?[0].update(from: source.baseAddress!, count: mono.count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
        }

        func finish() -> [(start: Double, end: Double, score: Double)] {
            analyzer.completeAnalysis()
            return observer.windows.withLock { $0 }.sorted { $0.start < $1.start }
        }
    }

    /// Collects each window's speech score.
    private final class Observer: NSObject, SNResultsObserving, Sendable {
        let windows = Mutex<[(start: Double, end: Double, score: Double)]>([])

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let score = result.classification(forIdentifier: "speech")?.confidence ?? 0
            let range = result.timeRange
            windows.withLock { $0.append((range.start.seconds, range.end.seconds, score)) }
        }
    }
}
