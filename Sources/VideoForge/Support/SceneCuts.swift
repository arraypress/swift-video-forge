//
//  SceneCuts.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Finding where a video changes shot, as pure functions over per-frame
//  measures: colour histograms for cuts, image fingerprints a second apart
//  for dissolves.
//
//  No Apple API detects shots (probed 2026-10-25 against the macOS 27 SDK:
//  VideoToolbox's `sceneChange` is a hint the CALLER passes to HDR metadata
//  generation; MediaIntelligence offers highlights and faces). Every
//  threshold here was MEASURED on 22 cuts with known times — hard cuts
//  between different dishes, a cut to a close-up of the same plate, four
//  re-cuts of one aerial of the same bridge, and 1 s dissolves — and on
//  footage that must find nothing: a slow pan, a fast zoom, a 2 s lighting
//  ramp, a 2-frame flash and a minute of real aerial footage. 22 of 22, no
//  false changes, cuts on the exact frame.
//

import Foundation

/// The rules for where the picture changes.
enum SceneCuts {

    // MARK: Thresholds (MEASURED — see the file header)

    /// A cut's histogram distance against the median distance of the second
    /// either side. MEASURED: the weakest real cut (two moments of the same
    /// aerial) is 6.6×, the strongest non-cut (camera motion in that aerial)
    /// 4.3×; with ``persistence`` every value from 4 to 6 found all 22.
    static let ratio = 5.0
    /// The distance below which nothing counts, however still the footage
    /// around it — a cursor blinking on a held title is not a shot. MEASURED:
    /// the weakest real cut is 0.027; 0.03 lost it.
    static let floor = 0.02
    /// What fraction of the jump must still be there between every frame of
    /// the third of a second before and every frame of the third after. A
    /// flash or a dropped frame comes back to the picture it left; a cut
    /// does not. MEASURED: real cuts keep 0.94 or more.
    static let persistence = 0.5
    /// A dissolve's fingerprint distance between the pictures a second
    /// apart. MEASURED: dissolves 0.885 and up; a lighting ramp 0.59, a fast
    /// zoom 0.57, anything else 0.55 or less (0.6–0.8 all found the same).
    static let dissolve = 0.7
    /// Fingerprints are taken this often, in seconds.
    static let printStep = 0.25

    // MARK: Measures

    /// Bins of the colour histogram: 16 hues × 4 saturations × 4 values.
    static let bins = 16 * 4 * 4

    /// The HSV histogram of a BGRA frame, normalised to sum to 1.
    ///
    /// - Parameters:
    ///   - pixels: 32-bit BGRA, `bytesPerRow` apart.
    ///   - width: Pixels across.
    ///   - height: Rows.
    ///   - bytesPerRow: The stride between rows.
    static func histogram(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> [Float] {
        var counts = [Float](repeating: 0, count: bins)
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                counts[bin(blue: p[0], green: p[1], red: p[2])] += 1
            }
        }
        let total = Float(max(1, width * height))
        return counts.map { $0 / total }
    }

    /// The histogram bin of one pixel.
    static func bin(blue: UInt8, green: UInt8, red: UInt8) -> Int {
        let r = Float(red) / 255, g = Float(green) / 255, b = Float(blue) / 255
        let high = max(r, g, b), low = min(r, g, b), spread = high - low
        var hue: Float = 0
        if spread > 0 {
            if high == r { hue = (g - b) / spread } else if high == g { hue = 2 + (b - r) / spread } else { hue = 4 + (r - g) / spread }
        }
        hue = (hue < 0 ? hue + 6 : hue) / 6
        let saturation = high > 0 ? spread / high : 0
        let h = min(15, Int(hue * 16)), s = min(3, Int(saturation * 4)), v = min(3, Int(high * 4))
        return (h * 4 + s) * 4 + v
    }

    /// How much of one histogram would have to move to make the other, 0–1.
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += abs(a[index] - b[index]) }
        return Double(sum) / 2
    }

    // MARK: Cuts

    /// The hard cuts in a run of frames.
    ///
    /// - Parameters:
    ///   - times: Each frame's time, in seconds, evenly spaced.
    ///   - histograms: Each frame's ``histogram(_:width:height:bytesPerRow:)``.
    ///   - rate: Frames a second in `times` — the window is a second either
    ///     side, the persistence check a third of one.
    /// - Returns: Cuts, at the first frame of each new shot.
    static func cuts(times: [Double], histograms: [[Float]], rate: Double) -> [SceneChange] {
        let count = min(times.count, histograms.count)
        guard count > 2 else { return [] }
        let window = max(1, Int(rate.rounded()))
        let hold = max(1, Int((rate / 3).rounded()))
        var steps = [Double](repeating: 0, count: count)
        for index in 1..<count { steps[index] = distance(histograms[index], histograms[index - 1]) }

        var found: [(index: Int, strength: Double)] = []
        for index in 1..<count {
            let step = steps[index]
            guard step >= floor else { continue }
            let around = Array(steps[max(1, index - window)..<index]) + Array(steps[(index + 1)..<min(count, index + 1 + window)])
            guard step >= ratio * (median(around) + 0.001) else { continue }
            guard persists(histograms, at: index, hold: hold, step: step) else { continue }
            if let last = found.last, index - last.index < hold {
                if step > last.strength { found[found.count - 1] = (index, step) }
                continue
            }
            found.append((index, step))
        }
        return found.map { SceneChange(time: times[$0.index], kind: .cut, strength: rounded($0.strength)) }
    }

    /// Whether the change at `index` is still there a moment later: every
    /// frame of the `hold` before differs from every frame of the `hold`
    /// after by at least ``persistence`` of the jump.
    static func persists(_ histograms: [[Float]], at index: Int, hold: Int, step: Double) -> Bool {
        let before = max(0, index - hold)..<index
        let after = index..<min(histograms.count, index + hold)
        for earlier in before {
            for later in after where distance(histograms[earlier], histograms[later]) < persistence * step {
                return false
            }
        }
        return true
    }

    // MARK: Dissolves

    /// Dissolves, from fingerprint distances taken across a second.
    ///
    /// - Parameters:
    ///   - spans: For each fingerprint time, the distance between the
    ///     pictures half a second before and half a second after it — the
    ///     smaller of two such pairs a quarter-second apart, so one odd frame
    ///     (a flash) can spoil only one of them.
    ///   - cuts: Hard cuts already found; a second either side of one is
    ///     the cut's, not a dissolve.
    /// - Returns: Dissolves, at their middles.
    static func dissolves(spans: [(time: Double, distance: Double)], cuts: [SceneChange]) -> [SceneChange] {
        var found: [SceneChange] = []
        for span in spans where span.distance >= dissolve {
            if cuts.contains(where: { abs($0.time - span.time) < 1 }) { continue }
            let stronger = spans.contains { abs($0.time - span.time) <= 1 && $0.distance > span.distance }
            if stronger { continue }
            if let last = found.last, span.time - last.time <= 1 { continue }
            found.append(SceneChange(time: span.time, kind: .dissolve, strength: rounded(span.distance)))
        }
        return found
    }

    // MARK: Shots

    /// The stretches between changes, from 0 to `duration`.
    static func scenes(_ changes: [SceneChange], duration: Double) -> [Range<Double>] {
        var starts = [0.0]
        for change in changes.sorted(by: { $0.time < $1.time }) where change.time > starts.last! && change.time < duration {
            starts.append(change.time)
        }
        return starts.indices.map { index in
            starts[index]..<(index + 1 < starts.count ? starts[index + 1] : max(duration, starts[index]))
        }
    }

    // MARK: Helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
