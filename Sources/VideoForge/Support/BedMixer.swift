//
//  BedMixer.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The music bed's arithmetic: its gain at every moment — level, duck,
//  fades — and its samples, looped with crossfades, mixed under the clip's
//  own. Pure: the music and the clip's sound come in as samples, mixed
//  samples go out, so every rule is pinned by a test with no file.
//
//  The duck is a ramp in DECIBELS, straight lines from the bed's level to
//  `duck` under it: it starts `attack` before the speech, so the music is
//  all the way down as the first word lands, and comes back over `release`
//  after the last. Stretches closer than attack + release are treated as
//  one, so the music does not bob up between two sentences.
//

import Foundation

/// The music bed's gain and samples.
struct BedMixer: Sendable {

    /// The bed's plan, in seconds and decibels.
    struct Plan: Sendable, Equatable {
        /// The gain that sits the music at its level, in dB.
        let gain: Double
        let duck: Double
        let attack: Double
        let release: Double
        let fadeIn: Double
        let fadeOut: Double
        /// When the bed starts and stops on the clip.
        let start: Double
        let end: Double
        /// The speech it ducks under, merged.
        let speech: [ClosedRange<Double>]
    }

    let plan: Plan
    let sampleRate: Double
    let channels: Int
    /// The music, interleaved at `sampleRate` and `channels`.
    let music: [Float]
    let loops: Bool
    /// Crossfade frames at each loop's join.
    let crossfade: Int
    /// The music's gain every 10 ms, linear, for interpolation.
    private let table: [Float]
    private static let step = 0.01

    /// The longest crossfade at a loop's join, in seconds — a quarter of
    /// the music for a short one.
    static let longestCrossfade = 1.0

    init(plan: Plan, music: [Float], sampleRate: Double, channels: Int, loops: Bool) {
        self.plan = plan
        self.music = music
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.loops = loops
        let frames = music.count / max(1, channels)
        crossfade = min(Int(Self.longestCrossfade * sampleRate), frames / 4)
        let count = Int((plan.end / Self.step).rounded(.up)) + 2
        table = (0..<count).map { Float(Self.gain(at: Double($0) * Self.step, plan: plan)) }
    }

    // MARK: - The rules

    /// Speech stretches sorted and merged where the gap is too short for
    /// the music to come back up and go down again.
    static func merged(_ speech: [ClosedRange<Double>], attack: Double, release: Double) -> [ClosedRange<Double>] {
        SpeechActivity.cleaned(speech, bridge: attack + release, shortest: 0)
    }

    /// How far under its level the music is at `time`, in dB, 0–`duck`.
    static func reduction(at time: Double, plan: Plan) -> Double {
        guard plan.duck > 0 else { return 0 }
        var deepest = 0.0
        for stretch in plan.speech {
            if stretch.contains(time) { return plan.duck }
            if time < stretch.lowerBound, time >= stretch.lowerBound - plan.attack, plan.attack > 0 {
                deepest = max(deepest, plan.duck * (time - (stretch.lowerBound - plan.attack)) / plan.attack)
            } else if time > stretch.upperBound, time <= stretch.upperBound + plan.release, plan.release > 0 {
                deepest = max(deepest, plan.duck * (1 - (time - stretch.upperBound) / plan.release))
            }
            if stretch.lowerBound - plan.attack > time { break }
        }
        return deepest
    }

    /// The fades' share of the music at `time`, 0–1.
    static func fade(at time: Double, plan: Plan) -> Double {
        guard time >= plan.start, time < plan.end else { return 0 }
        var share = 1.0
        if plan.fadeIn > 0 { share = min(share, (time - plan.start) / plan.fadeIn) }
        if plan.fadeOut > 0 { share = min(share, (plan.end - time) / plan.fadeOut) }
        return max(0, min(1, share))
    }

    /// The music's linear gain at `time`: its level, less the duck, faded.
    static func gain(at time: Double, plan: Plan) -> Double {
        let share = fade(at: time, plan: plan)
        guard share > 0 else { return 0 }
        return pow(10, (plan.gain - reduction(at: time, plan: plan)) / 20) * share
    }

    /// Whether `time` is clear of every ramp and fade: inside speech past
    /// its attack (`under`), or between, past every release and before the
    /// next attack — the places where the duck can be measured.
    static func steady(at time: Double, plan: Plan) -> (under: Bool, between: Bool) {
        guard time >= plan.start + plan.fadeIn, time < plan.end - plan.fadeOut else { return (false, false) }
        if plan.speech.contains(where: { $0.contains(time) }) { return (true, false) }
        let ramping = plan.speech.contains {
            (time >= $0.lowerBound - plan.attack && time < $0.lowerBound)
                || (time > $0.upperBound && time <= $0.upperBound + plan.release)
        }
        return (false, !ramping)
    }

    // MARK: - Samples

    /// The music's gain at frame `index` of the clip, interpolated.
    func gain(atFrame index: Int) -> Float {
        let position = Double(index) / sampleRate / Self.step
        let low = Int(position)
        guard low + 1 < table.count, low >= 0 else { return 0 }
        let fraction = Float(position - Double(low))
        return table[low] + (table[low + 1] - table[low]) * fraction
    }

    /// The music's sample for bed frame `frame` (0 = where it starts) and a
    /// channel: the music itself, or — looped — each pass crossfaded, equal
    /// power, into the tail of the one before.
    func musicSample(frame: Int, channel: Int) -> Float {
        let length = music.count / channels
        guard frame >= 0, length > 0 else { return 0 }
        guard loops, length > 2 * crossfade, crossfade > 0 else {
            return frame < length ? music[frame * channels + channel] : 0
        }
        let period = length - crossfade
        let pass = frame / period, offset = frame - pass * period
        guard pass > 0, offset < crossfade else { return music[offset * channels + channel] }
        let x = Float(offset) / Float(crossfade)
        let incoming = music[offset * channels + channel] * sin(.pi / 2 * x)
        let outgoing = music[(period + offset) * channels + channel] * cos(.pi / 2 * x)
        return incoming + outgoing
    }

    /// The bed alone for `count` frames from clip frame `first`, interleaved.
    func bed(from first: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * channels)
        let startFrame = Int((plan.start * sampleRate).rounded())
        for frame in 0..<count {
            let index = first + frame
            let gain = gain(atFrame: index)
            guard gain > 0 else { continue }
            for channel in 0..<channels {
                out[frame * channels + channel] = musicSample(frame: index - startFrame, channel: channel) * gain
            }
        }
        return out
    }
}
