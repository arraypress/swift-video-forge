//
//  SoundsTests.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One-shot sound effects, measured blind on the written file with
//  generated tones: the clip's sound is a steady 1 kHz tone, each effect a
//  burst at another frequency, so a single-bin DFT reads each one's level
//  under the other without separating them.
//

import AVFoundation
import XCTest
@testable import VideoForge

final class SoundsTests: XCTestCase {

    var directory: URL!
    var clip: URL!
    var burst: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestClips.temporaryDirectory()
        clip = directory.appendingPathComponent("tone.mov")
        try await TestClips.writeDrawnMovie(to: clip, seconds: 6, width: 320, height: 180, hz: 1000) { context, _ in
            context.setFillColor(CGColor(gray: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        burst = directory.appendingPathComponent("burst.caf")
        try TestClips.writeTone(to: burst, seconds: 0.6, hz: 1250, amplitude: 0.5)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The burst's level less the clip tone's, in dB, from 0.1 s into it.
    func under(_ samples: [Float], at time: Double) -> Double {
        let first = Int((time + 0.1) * 48_000), range = first..<(first + 19_200)
        return TestClips.toneLevel(samples, hz: 1250, in: range) - TestClips.toneLevel(samples, hz: 1000, in: range)
    }

    func testEachEffectSitsUnderTheSoundAroundItByTheAskedAmount() async throws {
        let written = out("effects.mov")
        let done = try await VideoForge.addSounds([SoundCue(file: burst, time: 1.5),
                                                   SoundCue(file: burst, time: 4, gain: 3)],
                                                  to: clip, destination: written)
        let sound = try await TestClips.monoSamples(of: written)
        let first = under(sound, at: 1.5), second = under(sound, at: 4)
        print("MEASURED sounds: \(first) dB and \(second) dB under the clip")
        XCTAssertEqual(first, -6, accuracy: 1, "the default sits 6 under")
        XCTAssertEqual(second, -3, accuracy: 1, "a +3 dB cue sits 3 under")
        // Reported: each cue's level against its reference, the mix's gain included.
        XCTAssertEqual(done.sounds[0].level - done.sounds[0].reference, -6 + done.mixGain, accuracy: 0.05)
        XCTAssertEqual(done.sounds[1].level - done.sounds[1].reference, -3 + done.mixGain, accuracy: 0.05)
        XCTAssertEqual(done.sounds[0].seconds, 0.6, accuracy: 0.01)
        XCTAssertLessThanOrEqual(done.truePeak, VideoForge.truePeakLimit)
        // Before and after the cues, the clip's tone alone.
        XCTAssertLessThan(TestClips.toneLevel(sound, hz: 1250, in: 24_000..<48_000), -50)
        XCTAssertTrue(done.result.passedThrough)
    }

    func testLoudEffectsAreKeptUnderTheCeiling() async throws {
        let done = try await VideoForge.addSounds([SoundCue(file: burst, time: 1, gain: 20)], to: clip,
                                                  destination: out("hot.mov"), effects: SoundEffects(underSpeech: -6))
        XCTAssertLessThan(done.mixGain, 0)
        XCTAssertLessThanOrEqual(done.truePeak, VideoForge.truePeakLimit)
    }

    func testMusicAndEffectsAreOneMix() async throws {
        let bed = out("bed.caf")
        try TestClips.writeTone(to: bed, seconds: 8, hz: 9500)
        let done = try await VideoForge.soundtrack(clip, destination: out("both.mov"), music: bed,
                                                   bed: MusicBed(fadeIn: 0), sounds: [SoundCue(file: burst, time: 2)])
        XCTAssertNotNil(done.music)
        XCTAssertEqual(done.sounds.count, 1)
        let sound = try await TestClips.monoSamples(of: done.result.destination)
        XCTAssertEqual(under(sound, at: 2), -6, accuracy: 1)
        XCTAssertGreaterThan(TestClips.toneLevel(sound, hz: 9500, in: 160_000..<200_000), -60, "the music is there")
    }

    func testCuesOutsideTheClipAreRefused() async throws {
        do {
            try await VideoForge.addSounds([SoundCue(file: burst, time: 9)], to: clip, destination: out("late.mov"))
            XCTFail("a cue after the end was accepted")
        } catch VideoForgeError.invalidOptions {}
        XCTAssertNotNil(SoundEffects(underSpeech: 90).problem)
    }

    func testAShortCueIsMeasuredWholeAndALongOneByItsLoudest400ms() {
        let rate = 48_000.0
        // 0.1 s and 2 s of the same tone read the same loudness.
        let tone = { (seconds: Double) in (0..<Int(rate * seconds)).map { Float(0.25 * sin(2 * .pi * 997 * Double($0) / rate)) } }
        let short = CueRules.loudness(of: tone(0.1), sampleRate: rate, channels: 1) ?? 0
        let long = CueRules.loudness(of: tone(2), sampleRate: rate, channels: 1) ?? 0
        XCTAssertEqual(short, long, accuracy: 0.3)
        XCTAssertNil(CueRules.loudness(of: [Float](repeating: 0, count: 4800), sampleRate: rate, channels: 1))
    }
}
