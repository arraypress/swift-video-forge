//
//  SpeechActivity.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Finding the stretches somebody is talking, as pure functions over
//  plain values: frame levels in, time ranges out. Two signals feed it —
//  an energy rule over the speech band, and Apple's sound classifier — and
//  which decides was MEASURED (see SpeechDetection).
//

import Foundation

/// Frame levels over the speech band, fed mono samples as they come.
///
/// Each 20 ms frame's RMS, in dBFS, after a 150 Hz high-pass and a 4 kHz
/// low-pass: hum, rumble and hiss do not count as talking.
struct SpeechLevels: Sendable {
    /// One frame, in seconds.
    static let frame = 0.02
    let sampleRate: Double
    private var highPass: Biquad
    private var lowPass: Biquad
    private var running = 0.0
    private var count = 0
    private let length: Int
    /// The level of every finished frame, dBFS.
    private(set) var levels: [Double] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        length = max(1, Int((sampleRate * Self.frame).rounded()))
        highPass = Self.section(cutoff: 150, rate: sampleRate, highPass: true)
        lowPass = Self.section(cutoff: 4000, rate: sampleRate, highPass: false)
    }

    /// A Butterworth (Q 0.707) high- or low-pass section.
    static func section(cutoff: Double, rate: Double, highPass: Bool) -> Biquad {
        let w = 2 * Double.pi * min(cutoff, rate * 0.45) / rate
        let alpha = sin(w) / (2 * 0.7071067811865476)
        let c = cos(w), a0 = 1 + alpha
        let b0 = highPass ? (1 + c) / 2 : (1 - c) / 2
        let b1 = highPass ? -(1 + c) : 1 - c
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b0 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    /// Feeds mono samples.
    mutating func add(_ mono: [Float]) {
        for sample in mono {
            let y = lowPass.process(highPass.process(Double(sample)))
            running += y * y
            count += 1
            if count == length {
                levels.append(10 * log10(max(running / Double(length), 1e-14)))
                (running, count) = (0, 0)
            }
        }
    }
}

/// The rules that turn levels and classifier scores into speech.
enum SpeechActivity {

    /// How far above the quiet between words a frame must be to count as
    /// speech, in dB. MEASURED — see SpeechDetection.
    static let energyMargin = 4.5
    /// Below this a frame is never speech, however quiet the room, in dBFS.
    static let energyFloor = -55.0
    /// Gaps shorter than this inside speech are bridged: the pause between
    /// two words is still talking. MEASURED — see SpeechDetection.
    static let bridge = 0.5
    /// Shorter stretches than this are dropped — a click, a tap.
    static let shortest = 0.12
    /// The classifier's speech score that counts as speech.
    static let classifierThreshold = 0.5
    /// How far either side of a voice the classifier heard the energy rule
    /// may still find its edges, in seconds.
    static let reach = 0.05

    /// The room's quiet: the 10th-percentile frame level.
    static func noiseFloor(_ levels: [Double]) -> Double {
        let sorted = levels.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return -120 }
        return sorted[min(sorted.count - 1, sorted.count / 10)]
    }

    /// Speech by the energy rule: frames louder than the room's quiet by
    /// `margin` and louder than `floor`, bridged and cleaned.
    static func energySegments(_ levels: [Double], frame: Double = SpeechLevels.frame,
                               margin: Double = energyMargin, floor: Double = energyFloor,
                               bridge: Double = bridge, shortest: Double = shortest) -> [ClosedRange<Double>] {
        let threshold = max(floor, noiseFloor(levels) + margin)
        var raw: [ClosedRange<Double>] = []
        var open: Int?
        for (index, level) in levels.enumerated() {
            if level >= threshold {
                if open == nil { open = index }
            } else if let start = open {
                raw.append(Double(start) * frame...Double(index) * frame)
                open = nil
            }
        }
        if let start = open { raw.append(Double(start) * frame...Double(levels.count) * frame) }
        return cleaned(raw, bridge: bridge, shortest: shortest)
    }

    /// Speech by the classifier. Each window speaks for its MIDDLE — the
    /// stretch between it and its neighbours' middles — not its whole
    /// length: a 1 s window that scores a voice may hold only its last
    /// quarter-second of it, and counting all of it widened every stretch
    /// by up to a second each side (MEASURED: edges 2.1 s out).
    static func classifierSegments(_ windows: [(start: Double, end: Double, score: Double)],
                                   threshold: Double = classifierThreshold,
                                   bridge: Double = bridge) -> [ClosedRange<Double>] {
        let sorted = windows.sorted { $0.start < $1.start }
        let hop = sorted.count > 1 ? sorted[1].start - sorted[0].start : (sorted.first.map { $0.end - $0.start } ?? 0)
        let raw = sorted.filter { $0.score >= threshold }.map { window -> ClosedRange<Double> in
            let middle = (window.start + window.end) / 2
            return max(0, middle - hop / 2)...(middle + hop / 2)
        }
        return cleaned(raw, bridge: bridge, shortest: 0)
    }

    /// The energy rule's frames, kept only where the classifier hears a
    /// voice (widened by `reach` each side) — the classifier says WHETHER,
    /// the energy says exactly WHEN. Intersected BEFORE bridging: a clap
    /// a quarter-second after a sentence would otherwise be bridged into
    /// it and confirmed with it.
    static func confirmed(levels: [Double], classifier: [ClosedRange<Double>],
                          frame: Double = SpeechLevels.frame, margin: Double = energyMargin,
                          floor: Double = energyFloor, reach: Double = reach,
                          bridge: Double = bridge, shortest: Double = shortest) -> [ClosedRange<Double>] {
        let heard = classifier.map { max(0, $0.lowerBound - reach)...($0.upperBound + reach) }
        let loud = energySegments(levels, frame: frame, margin: margin, floor: floor, bridge: 0, shortest: 0)
        var kept: [ClosedRange<Double>] = []
        for stretch in loud {
            for voice in heard where voice.overlaps(stretch) {
                kept.append(max(stretch.lowerBound, voice.lowerBound)...min(stretch.upperBound, voice.upperBound))
            }
        }
        return cleaned(kept, bridge: bridge, shortest: shortest)
    }

    /// Ranges sorted, overlaps and gaps under `bridge` joined, and those
    /// shorter than `shortest` dropped.
    static func cleaned(_ ranges: [ClosedRange<Double>], bridge: Double, shortest: Double) -> [ClosedRange<Double>] {
        var joined: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = joined.last, range.lowerBound - last.upperBound <= bridge {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        return joined.filter { $0.upperBound - $0.lowerBound >= shortest }
    }
}
