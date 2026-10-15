//
//  Loudness.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  ITU-R BS.1770-4 loudness and true peak, measured as sound streams past —
//  a music bed is checked on the samples actually written, not estimated.
//
//  · Loudness: each channel K-weighted (the standard's shelf and high-pass,
//    designed at the stream's own rate), mean square over 400 ms blocks
//    every 100 ms, gated at −70 LUFS and then 10 LU under the gated mean.
//    Channels are summed with weight 1 — right for mono and stereo; the
//    surround weights are not applied.
//  · True peak: the signal upsampled 4× by a windowed-sinc interpolator
//    and the largest magnitude taken, in dBTP. Between two samples a
//    waveform can rise above both — a sine at a quarter of the sample rate
//    whose samples sit at ±0.707 peaks at 1.0, 3 dB over the sample peak.
//

import Foundation

/// The K-weighting filter for one channel, as two biquads.
struct KWeighting: Sendable {
    private var shelf: Biquad
    private var pass: Biquad

    /// The filter at a sample rate, from the standard's analogue values.
    init(sampleRate rate: Double) {
        // Stage 1: the high shelf, +4 dB above about 1.7 kHz.
        let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / rate)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0,
                           a2: (1 - k / q + k * k) / a0)
        // Stage 2: the RLB high-pass at about 38 Hz.
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / rate)
        let d0 = 1 + k1 / q1 + k1 * k1
        pass = Biquad(b0: 1 / d0, b1: -2 / d0, b2: 1 / d0, a1: 2 * (k1 * k1 - 1) / d0,
                          a2: (1 - k1 / q1 + k1 * k1) / d0)
    }

    /// One sample through both stages.
    mutating func callAsFunction(_ x: Double) -> Double {
        pass.process(shelf.process(x))
    }
}

/// One second-order section, direct form I.
struct Biquad: Sendable {
    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

/// Integrated loudness, fed interleaved samples as they come.
struct LoudnessMeter: Sendable {
    let sampleRate: Double
    let channels: Int
    private var filters: [KWeighting]
    /// K-weighted energy of each finished 100 ms step, summed over channels.
    private(set) var steps: [Double] = []
    private var running = 0.0
    private var count = 0
    private let stepLength: Int

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        filters = Array(repeating: KWeighting(sampleRate: sampleRate), count: max(1, channels))
        stepLength = max(1, Int((sampleRate / 10).rounded()))
    }

    /// Feeds interleaved frames.
    mutating func add(_ interleaved: UnsafeBufferPointer<Float>) {
        var index = 0
        while index + channels <= interleaved.count {
            for channel in 0..<channels {
                let y = filters[channel](Double(interleaved[index + channel]))
                running += y * y
            }
            index += channels
            count += 1
            if count == stepLength {
                steps.append(running)
                (running, count) = (0, 0)
            }
        }
    }

    /// Feeds interleaved frames from an array.
    mutating func add(_ interleaved: [Float]) {
        interleaved.withUnsafeBufferPointer { add($0) }
    }

    /// The mean square of every 400 ms block, one per 100 ms step.
    var blockPowers: [Double] {
        guard steps.count >= 4 else { return [] }
        return (0...(steps.count - 4)).map { start in
            steps[start..<(start + 4)].reduce(0, +) / Double(4 * stepLength)
        }
    }

    /// The integrated loudness in LUFS, or nil for silence.
    var integrated: Double? { Self.gated(blockPowers) }

    /// The loudness of a power, in LUFS.
    static func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-15)) }

    /// BS.1770's two gates over a set of block powers.
    static func gated(_ powers: [Double]) -> Double? {
        let loud = powers.filter { lufs($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let threshold = lufs(loud.reduce(0, +) / Double(loud.count)) - 10
        let kept = loud.filter { lufs($0) > threshold }
        guard !kept.isEmpty else { return nil }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }

    /// The gated loudness of only the blocks whose middle falls in one of
    /// `ranges` (seconds) — the loudness of the speech, say.
    func integrated(within ranges: [ClosedRange<Double>]) -> Double? {
        let powers = blockPowers.enumerated().compactMap { index, power -> Double? in
            let middle = Double(index) * 0.1 + 0.2
            return ranges.contains { $0.contains(middle) } ? power : nil
        }
        return Self.gated(powers)
    }
}

/// True peak, fed interleaved samples as they come.
struct TruePeakMeter: Sendable {
    let channels: Int
    /// The largest magnitude seen, linear.
    private(set) var peak: Float = 0
    /// The last `taps` samples of every channel, twice over, so a window
    /// is always one contiguous run: channel c's sample n sits at
    /// c * 2 * taps + (n % taps) and again `taps` further on.
    private var history: [Float]
    private var cursor = 0
    private static let phases = 4
    private static let taps = 12
    /// The interpolator: 4 phases of a Kaiser-windowed sinc, 48 taps in
    /// all, each phase reversed so it lines up with the history oldest-first.
    private static let kernel: [Float] = {
        let total = phases * taps
        let beta = 8.0
        func bessel(_ x: Double) -> Double {
            var (sum, term) = (1.0, 1.0)
            for k in 1..<30 { term *= (x / 2) / Double(k); sum += term * term }
            return sum
        }
        let centre = Double(total - 1) / 2
        let h = (0..<total).map { n -> Double in
            let t = (Double(n) - centre) / Double(phases)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let r = (Double(n) - centre) / centre
            return sinc * bessel(beta * (1 - r * r).squareRoot()) / bessel(beta)
        }
        // Each phase passes DC at unity.
        return (0..<phases).flatMap { phase -> [Float] in
            let taps = stride(from: phase, to: total, by: phases).map { h[$0] }
            let sum = taps.reduce(0, +)
            return taps.reversed().map { Float($0 / sum) }
        }
    }()

    init(channels: Int) {
        self.channels = max(1, channels)
        history = Array(repeating: 0, count: max(1, channels) * 2 * Self.taps)
    }

    /// Feeds interleaved frames.
    mutating func add(_ interleaved: UnsafeBufferPointer<Float>) {
        let (taps, phases, channels) = (Self.taps, Self.phases, self.channels)
        var loudest = peak
        var cursor = self.cursor
        Self.kernel.withUnsafeBufferPointer { kernel in
            history.withUnsafeMutableBufferPointer { history in
                var index = 0
                while index + channels <= interleaved.count {
                    for channel in 0..<channels {
                        let base = channel * 2 * taps
                        let sample = interleaved[index + channel]
                        history[base + cursor] = sample
                        history[base + cursor + taps] = sample
                        // Oldest first: the window starts just after the newest.
                        let window = base + cursor + 1
                        for phase in 0..<phases {
                            var y: Float = 0
                            let k = phase * taps
                            for tap in 0..<taps { y += kernel[k + tap] * history[window + tap] }
                            loudest = max(loudest, abs(y))
                        }
                    }
                    cursor = (cursor + 1) % taps
                    index += channels
                }
            }
        }
        self.cursor = cursor
        peak = loudest
    }

    /// Feeds interleaved frames from an array.
    mutating func add(_ interleaved: [Float]) {
        interleaved.withUnsafeBufferPointer { add($0) }
    }

    /// The true peak in dBTP.
    var dBTP: Double { 20 * log10(max(Double(peak), 1e-12)) }
}
