//
//  MusicTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A music bed, measured blind on the written file. The "music" is a tone
//  at 9.5 kHz, where the `say` voices put almost nothing, so its level can
//  be read under the speech by a single-bin DFT without separating the two:
//  the duck is the tone's level between sentences less its level during
//  them.
//

import AVFoundation
import SubtitleKit
import XCTest
@testable import VideoForge

final class MusicTests: XCTestCase {

    var directory: URL!
    var talking: URL!
    var truth: [ClosedRange<Double>] = []
    var tone: URL!
    static let hz = 9500.0

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        talking = directory.appendingPathComponent("talking.mov")
        truth = try await TestClips.writeSpeechMovie(to: talking)
        tone = directory.appendingPathComponent("tone.caf")
        try TestClips.writeTone(to: tone, seconds: 20, hz: Self.hz)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The tone's mean level, in dB, over 0.25 s windows in `ranges`.
    func level(_ samples: [Float], in ranges: [ClosedRange<Double>]) -> Double {
        var levels: [Double] = []
        for range in ranges {
            var start = range.lowerBound
            while start + 0.25 <= range.upperBound {
                let first = Int(start * 48_000)
                levels.append(TestClips.toneLevel(samples, hz: Self.hz, in: first..<(first + 12_000)))
                start += 0.25
            }
        }
        return levels.reduce(0, +) / Double(max(1, levels.count))
    }

    /// Inside each sentence, clear of the edges; and between them, clear
    /// of every attack and release.
    var during: [ClosedRange<Double>] { truth.map { ($0.lowerBound + 0.3)...($0.upperBound - 0.3) } }
    var between: [ClosedRange<Double>] {
        zip(truth, truth.dropFirst()).map { ($0.upperBound + 0.8)...($1.lowerBound - 0.4) }
    }

    func testTheMusicDucksByTheAskedAmountUnderSpeech() async throws {
        for duck in [10.0, 6.0] {
            let written = out("ducked-\(Int(duck)).mov")
            let done = try await VideoForge.addMusic(tone, to: talking, destination: written,
                                                     bed: MusicBed(duck: duck, fadeIn: 0))
            let sound = try await TestClips.monoSamples(of: written)
            let measured = level(sound, in: between) - level(sound, in: during)
            XCTAssertEqual(measured, duck, accuracy: 1, "a \(duck) dB duck measured \(measured)")
            // What the library reports agrees with what the file holds.
            let reported = try XCTUnwrap(done.musicBetween) - XCTUnwrap(done.musicUnderSpeech)
            XCTAssertEqual(reported, duck, accuracy: 0.05)
            XCTAssertLessThanOrEqual(done.truePeak, VideoForge.truePeakLimit)
            XCTAssertNotNil(done.loudness)
        }
    }

    func testSpeechIsFoundWhereItWasPut() async throws {
        let found = try await VideoForge.speech(in: talking)
        XCTAssertEqual(found.count, truth.count, "\(found) against \(truth)")
        for (got, want) in zip(found, truth) {
            XCTAssertEqual(got.lowerBound, want.lowerBound, accuracy: 0.1)
            XCTAssertEqual(got.upperBound, want.upperBound, accuracy: 0.1)
        }
    }

    func testTheLevelIsSetAgainstTheSpeech() async throws {
        // Two musics 20 dB apart land at the same level.
        let quiet = out("quiet.caf")
        try TestClips.writeTone(to: quiet, seconds: 20, hz: Self.hz, amplitude: 0.03)
        let loud = try await VideoForge.addMusic(tone, to: talking, destination: out("a.mov"))
        let soft = try await VideoForge.addMusic(quiet, to: talking, destination: out("b.mov"))
        XCTAssertEqual(loud.musicLoudness - soft.musicLoudness, 20, accuracy: 0.1)
        let a = try await TestClips.monoSamples(of: loud.result.destination)
        let b = try await TestClips.monoSamples(of: soft.result.destination)
        XCTAssertEqual(level(a, in: between), level(b, in: between), accuracy: 0.5)
        // And between sentences the music sits `level` under the speech.
        XCTAssertEqual(loud.musicBetween ?? 0, loud.reference - 12 - loud.musicLoudness, accuracy: 0.05)
    }

    func testThePictureIsCopiedAndThePeakKeptUnderTheLimit() async throws {
        // A clip already at full scale, and music asked loud: the mix is
        // turned down rather than clipped.
        let loud = out("loud.mov")
        try await TestClips.writeDrawnMovie(to: loud, seconds: 4, width: 320, height: 180, hz: 440) { context, _ in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        let hot = out("hot.caf")
        try TestClips.writeTone(to: hot, seconds: 5, hz: 660, amplitude: 0.99)
        let written = out("limited.mov")
        let done = try await VideoForge.addMusic(hot, to: loud, destination: written, bed: MusicBed(level: 6))
        XCTAssertLessThan(done.mixGain, 0)
        XCTAssertLessThanOrEqual(done.truePeak, VideoForge.truePeakLimit)
        XCTAssertTrue(done.result.passedThrough)
        let before = try await TestClips.decodedFrames(of: loud).map(\.bytes)
        let after = try await TestClips.decodedFrames(of: written).map(\.bytes)
        XCTAssertEqual(before, after, "the picture changed")
    }

    func testLoopingFillsTheClipAndFadesShape() async throws {
        let short = out("short.caf")
        try TestClips.writeTone(to: short, seconds: 3, hz: Self.hz)
        let once = try await VideoForge.addMusic(short, to: talking, destination: out("once.mov"),
                                                 bed: MusicBed(fadeIn: 0, fadeOut: 0))
        let looped = try await VideoForge.addMusic(short, to: talking, destination: out("looped.mov"),
                                                   bed: MusicBed(loops: true, fadeIn: 2, fadeOut: 0))
        let a = try await TestClips.monoSamples(of: once.result.destination)
        let b = try await TestClips.monoSamples(of: looped.result.destination)
        let late = (truth.last!.upperBound + 0.8)...(truth.last!.upperBound + 1.6)
        XCTAssertLessThan(level(a, in: [late]), -60, "music that ran out is silent")
        XCTAssertGreaterThan(level(b, in: [late]), level(b, in: between) - 1, "looped music is still there")
        // The fade-in: a quarter of the way up at 0.5 s of a 2 s fade.
        let early = TestClips.toneLevel(b, hz: Self.hz, in: 21_600..<26_400)       // 0.45–0.55 s
        let full = level(b, in: between)
        XCTAssertEqual(early - full, 20 * log10(0.25), accuracy: 1.5)
    }

    func testReplacingTheSoundLeavesOnlyTheMusic() async throws {
        let written = out("replaced.mov")
        let done = try await VideoForge.addMusic(tone, to: talking, destination: written,
                                                 bed: MusicBed(level: 0, fadeIn: 0, fadeOut: 0, keepsClipAudio: false))
        XCTAssertEqual(done.reference, VideoForge.quietReference)
        XCTAssertTrue(done.speech.isEmpty)
        XCTAssertEqual(done.loudness ?? 0, VideoForge.quietReference, accuracy: 0.5)
    }

    func testTheSubtitlesStay() async throws {
        let subtitled = out("subtitled.mov")
        try await VideoForge.addSubtitles([Subtitles(cues: [.init(start: 1, end: 2, text: "hi")], language: "en")],
                                          to: talking, destination: subtitled)
        let done = try await VideoForge.addMusic(tone, to: subtitled, destination: out("scored.mov"))
        XCTAssertEqual(done.result.lostTracks, [])
        let cues = try await VideoForge.subtitles(in: done.result.destination).first?.cues
        XCTAssertEqual(cues?.map(\.text), ["hi"])
    }
}

/// The bed's rules and the meters, with no clip to make.
final class MusicRuleTests: XCTestCase {

    func testTheDuckRampsInDecibels() {
        let plan = BedMixer.Plan(gain: 0, duck: 10, attack: 0.2, release: 0.5, fadeIn: 0, fadeOut: 0,
                                 start: 0, end: 10, speech: [2...4])
        XCTAssertEqual(BedMixer.reduction(at: 1.7, plan: plan), 0)
        XCTAssertEqual(BedMixer.reduction(at: 1.9, plan: plan), 5, accuracy: 1e-9)
        XCTAssertEqual(BedMixer.reduction(at: 3, plan: plan), 10)
        XCTAssertEqual(BedMixer.reduction(at: 4.25, plan: plan), 5, accuracy: 1e-9)
        XCTAssertEqual(BedMixer.reduction(at: 4.6, plan: plan), 0)
        // Sentences closer than attack + release are one.
        XCTAssertEqual(BedMixer.merged([1...2, 2.6...3, 4...5], attack: 0.2, release: 0.5), [1...3, 4...5])
    }

    func testLoopsCrossfadeWithoutAJump() {
        // A ramp of music: a loop that jumped would show a step.
        let music = (0..<1000).map { Float($0) / 1000 }
        let plan = BedMixer.Plan(gain: 0, duck: 0, attack: 0, release: 0, fadeIn: 0, fadeOut: 0, start: 0, end: 1, speech: [])
        let mixer = BedMixer(plan: plan, music: music, sampleRate: 1000, channels: 1, loops: true)
        XCTAssertEqual(mixer.crossfade, 250)
        let period = 1000 - 250
        // Into the join, the old pass's tail plays at full; out of it, the new head.
        XCTAssertEqual(mixer.musicSample(frame: period, channel: 0), music[period], accuracy: 1e-6)
        XCTAssertEqual(mixer.musicSample(frame: period + 249, channel: 0),
                       music[249] * sin(.pi / 2 * 249 / 250) + music[999] * cos(.pi / 2 * 249 / 250), accuracy: 1e-6)
        XCTAssertEqual(mixer.musicSample(frame: period + 250, channel: 0), music[250], accuracy: 1e-6)
    }

    func testMetersReadTheStandardsReferences() {
        // A stereo 997 Hz sine at −20 dBFS reads −20 LUFS.
        let rate = 48_000.0
        let sine = (0..<Int(rate * 5)).flatMap { index -> [Float] in
            let value = Float(0.1 * sin(2 * .pi * 997 * Double(index) / rate))
            return [value, value]
        }
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        meter.add(sine)
        XCTAssertEqual(meter.integrated ?? 0, -20, accuracy: 0.1)
        // A sine at a quarter of the rate, sampled at ±0.707, peaks at 1.0
        // between the samples: 0 dBTP, 3 dB over its sample peak.
        let quarter = (0..<4800).map { Float(sin(.pi / 2 * Double($0) + .pi / 4)) }
        var peak = TruePeakMeter(channels: 1)
        peak.add(quarter)
        XCTAssertEqual(peak.dBTP, 0, accuracy: 0.2)
        XCTAssertNotNil(MusicBed(duck: -1).problem)
        XCTAssertNil(MusicBed().problem)
    }
}
