//
//  CueRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  How loud a one-shot sound effect goes in, as pure functions: its own
//  loudness is its loudest 400 ms (BS.1770 momentary, ungated — a whoosh is
//  too short to integrate), and its target is the speech around it less
//  `underSpeech`. Speech is the point of a talking clip; an effect that
//  covers a word is a mistake nobody listening would make.
//

import Foundation

/// The sound-effect levelling rules.
enum CueRules {

    /// How far either side of a cue the speech is measured, in seconds.
    static let reach = 3.0

    /// The loudness of a cue: its loudest 400 ms block, or the whole of a
    /// shorter one, in LUFS; nil for silence.
    static func loudness(of samples: [Float], sampleRate: Double, channels: Int) -> Double? {
        var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
        meter.add(samples)
        let frames = samples.count / max(1, channels)
        if let loudest = meter.blockPowers.max(), loudest > 0 { return LoudnessMeter.lufs(loudest) }
        // Shorter than a block: the K-weighted mean square of all of it.
        guard frames > 0 else { return nil }
        var tail = LoudnessMeter(sampleRate: sampleRate, channels: channels)
        tail.add(samples + [Float](repeating: 0, count: max(0, Int(sampleRate * 0.4) - frames) * channels))
        guard let power = tail.blockPowers.first, power > 0 else { return nil }
        return LoudnessMeter.lufs(power * 0.4 * sampleRate / Double(frames))
    }

    /// What a cue at `time` is levelled against: the gated loudness of the
    /// speech within ``reach`` of it, else of all the clip's sound there,
    /// else nil.
    static func reference(at time: Double, meter: LoudnessMeter, speech: [ClosedRange<Double>]) -> Double? {
        let window = max(0, time - reach)...(time + reach)
        let near = speech.compactMap { range -> ClosedRange<Double>? in
            let low = max(range.lowerBound, window.lowerBound), high = min(range.upperBound, window.upperBound)
            return low < high ? low...high : nil
        }
        return meter.integrated(within: near) ?? meter.integrated(within: [window])
    }
}

extension CueRules {

    /// What is wrong with sound-effect settings, if anything.
    static func problem(with effects: SoundEffects) -> String? {
        if !(-20...60).contains(effects.underSpeech) { return "effects sit −20 to 60 LU under the speech" }
        if !(-40...40).contains(effects.gain) { return "the effects' gain is −40 to 40 dB" }
        return nil
    }
}
