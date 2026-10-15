//
//  VideoForge+Music.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Music under a clip's own sound, ducked while somebody talks, and one-shot
//  sound effects in it — one mix, every number measured, none guessed:
//
//  1. The clip's sound is read once: where the speech is (SpeechDetection)
//     and how loud it is (BS.1770, over the speech only).
//  2. The music is measured the same way and gained to sit `level` LU
//     under the speech, so a loudly mastered song and a quiet one land in
//     the same place.
//  3. The mix is made once to find its true peak, and the whole of it
//     turned down if that peak would pass −1.5 dBTP.
//  4. It is made again and written: the picture, subtitles and timed
//     metadata COPIED, byte for byte — nothing is re-encoded but the sound.
//  5. The written file is decoded and measured; its loudness and true peak
//     are what is reported. A peak over −1 dBTP after encoding is written
//     again, quieter by the overshoot.
//

import AVFoundation
import Foundation

extension VideoForge {

    /// The true peak a mix is made to, before encoding, in dBTP.
    static let mixCeiling = -1.5
    /// The true peak the written file must not pass, in dBTP.
    public static let truePeakLimit = -1.0
    /// What a clip with no sound kept is levelled against, in LUFS.
    public static let quietReference = -16.0

    /// Lays `music` under a clip, ducked under its speech, and writes it.
    ///
    /// ```swift
    /// let done = try await VideoForge.addMusic(song, to: talk, destination: out)
    /// done.speech            // [1.2...5.1, 7.6...12.0, ...]
    /// done.loudness          // −17.8, measured on the written file
    /// done.truePeak          // −1.9
    /// ```
    ///
    /// - Parameters:
    ///   - music: The sound file (or a movie's sound) to lay under it.
    ///   - source: The clip.
    ///   - destination: Where to write.
    ///   - bed: How the music sits under it.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened, measured.
    /// - Throws: ``VideoForgeError/invalidOptions(_:)`` for settings that
    ///   cannot be honoured, ``VideoForgeError/noAudioTrack(_:)`` for music
    ///   with no sound, or any other ``VideoForgeError``.
    @discardableResult
    public static func addMusic(_ music: URL, to source: URL, destination: URL,
                                bed: MusicBed = MusicBed(), overwrites: Bool = false) async throws -> MusicResult {
        let done = try await soundtrack(source, destination: destination, music: music, bed: bed,
                                        overwrites: overwrites)
        guard let report = done.music else { throw VideoForgeError.exportFailed(reason: "the music was not mixed") }
        return report
    }

    /// Mixes one-shot sound effects into a clip at their times, and writes
    /// it — the picture copied, each effect levelled against the speech
    /// around it.
    ///
    /// ```swift
    /// let done = try await VideoForge.addSounds([SoundCue(file: whoosh, time: 3.2)],
    ///                                           to: talk, destination: out)
    /// done.sounds[0].level      // −24.1 LUFS: 6 under the speech around it
    /// ```
    ///
    /// - Parameters:
    ///   - cues: The effects and their times.
    ///   - source: The clip.
    ///   - destination: Where to write.
    ///   - effects: How they are levelled.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened, each effect measured.
    /// - Throws: ``VideoForgeError/invalidOptions(_:)`` for a cue outside the
    ///   clip, or any other ``VideoForgeError``.
    @discardableResult
    public static func addSounds(_ cues: [SoundCue], to source: URL, destination: URL,
                                 effects: SoundEffects = SoundEffects(),
                                 overwrites: Bool = false) async throws -> SoundtrackResult {
        guard !cues.isEmpty else { throw VideoForgeError.invalidOptions("no sounds were given") }
        return try await soundtrack(source, destination: destination, sounds: cues, effects: effects,
                                    overwrites: overwrites)
    }

    /// Music, sound effects, or both, mixed with a clip's sound in ONE pass
    /// and written — the picture, subtitles and metadata copied.
    ///
    /// - Parameters:
    ///   - source: The clip.
    ///   - destination: Where to write.
    ///   - music: The music, or nil for none.
    ///   - bed: How the music sits.
    ///   - sounds: The effects.
    ///   - effects: How they are levelled.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened, measured.
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func soundtrack(_ source: URL, destination: URL, music: URL? = nil, bed: MusicBed = MusicBed(),
                                  sounds: [SoundCue] = [], effects: SoundEffects = SoundEffects(),
                                  overwrites: Bool = false) async throws -> SoundtrackResult {
        let started = Date()
        guard music != nil || !sounds.isEmpty else { throw VideoForgeError.invalidOptions("no music or sounds were given") }
        if music != nil, let problem = bed.problem { throw VideoForgeError.invalidOptions(problem) }
        if let problem = effects.problem { throw VideoForgeError.invalidOptions(problem) }
        for file in [music].compactMap({ $0 }) + sounds.map(\.file)
        where !FileManager.default.fileExists(atPath: file.path) {
            throw VideoForgeError.fileNotFound(file)
        }
        let before = try await describe(source)
        guard before.hasVideo else { throw VideoForgeError.noVideoTrack(source) }
        if music != nil, bed.start >= before.duration {
            throw VideoForgeError.invalidOptions(String(format: "the music starts at %.2f s, after the %.2f s clip ends",
                                                        bed.start, before.duration))
        }
        if let late = sounds.first(where: { !($0.time >= 0 && $0.time < before.duration) }) {
            throw VideoForgeError.invalidOptions(String(format: "%@ is at %.2f s, outside the %.2f s clip",
                                                        late.file.lastPathComponent, late.time, before.duration))
        }
        // The picture is copied, so the container is the only choice: the
        // destination's, or the source's.
        let container = try ExportSpec().container(for: before, destination: destination)
        try check(destination, overwrites: overwrites)

        // 1. The clip's sound: speech and loudness. Effects always go over
        // it; music may replace it.
        let keepsClip = (music == nil || bed.keepsClipAudio) && before.hasAudio
        let detection = music == nil ? effects.detection : bed.detection
        let scan = keepsClip ? try await SpeechScan.run(source, classifies: detection != .energy) : nil
        let rate = scan?.sampleRate ?? 48_000, channels = scan?.channels ?? 2
        let speech = scan?.speech(detection) ?? []
        let reference = scan.flatMap { $0.loudness.integrated(within: speech) ?? $0.loudness.integrated }
            ?? quietReference
        let frames = Int((before.duration * rate).rounded())

        // 2. The music, measured.
        var mixer: BedMixer?
        var musicLoudness = 0.0
        if let music {
            let tune = try await PCMStream(music, rate: rate, channels: channels).rest()
            var meter = LoudnessMeter(sampleRate: rate, channels: channels)
            meter.add(tune)
            guard let loudness = meter.integrated else {
                throw VideoForgeError.invalidOptions("\(music.lastPathComponent) is silent")
            }
            musicLoudness = loudness
            let musicSeconds = Double(tune.count / channels) / rate
            let plan = BedMixer.Plan(
                gain: reference + bed.level - loudness, duck: keepsClip ? bed.duck : 0,
                attack: bed.attack, release: bed.release, fadeIn: bed.fadeIn, fadeOut: bed.fadeOut,
                start: bed.start, end: bed.loops ? before.duration : min(before.duration, bed.start + musicSeconds),
                speech: BedMixer.merged(speech, attack: bed.attack, release: bed.release))
            mixer = BedMixer(plan: plan, music: tune, sampleRate: rate, channels: channels, loops: bed.loops)
        }

        // 2b. Each effect, measured and levelled against the speech around it.
        var cues: [CueLayer] = []
        var placed: [(cue: SoundCue, seconds: Double, reference: Double, loudness: Double, gain: Double)] = []
        for cue in sounds {
            let start = Int((cue.time * rate).rounded())
            var samples = try await PCMStream(cue.file, rate: rate, channels: channels).rest()
            samples = Array(samples.prefix(max(0, frames - start) * channels))
            guard let loudness = CueRules.loudness(of: samples, sampleRate: rate, channels: channels) else {
                throw VideoForgeError.invalidOptions("\(cue.file.lastPathComponent) is silent")
            }
            let around = scan.flatMap { CueRules.reference(at: cue.time, meter: $0.loudness, speech: speech) }
                ?? quietReference
            let gain = around - effects.underSpeech + effects.gain + cue.gain - loudness
            cues.append(CueLayer(samples: samples, start: start, gain: Float(pow(10, gain / 20))))
            placed.append((cue, Double(samples.count / channels) / rate, around, loudness, gain))
        }

        // 3. The peak of the mix as it would be, and the gain that keeps it
        // under the ceiling.
        let clipTrack = keepsClip ? try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first : nil
        let clipDescription = try await clipTrack?.load(.formatDescriptions).first
        var layout: Data?
        if let clipDescription, channels > 2 {
            var size = 0
            layout = CMAudioFormatDescriptionGetChannelLayout(clipDescription, sizeOut: &size)
                .map { Data(bytes: $0, count: size) }
        }
        let bitRate = Double(try await clipTrack?.load(.estimatedDataRate) ?? 0)
        var sound = MixedSound(clip: keepsClip ? source : nil, sampleRate: rate, channels: channels, mixer: mixer,
                               cues: cues, frames: frames, mixGain: 1, layout: layout, bitRate: bitRate,
                               codec: before.video.flatMap { CodecPlan.codec(named: $0.codec) } ?? .h264)
        var peak = TruePeakMeter(channels: channels)
        try await sound.run { peak.add($0) }
        var mixGain = min(0, mixCeiling - peak.dBTP)

        // 4 and 5. Written, then measured; written again, quieter, if the
        // encoder pushed the peak over the limit.
        let copied = try await Remuxer.plan(AVURLAsset(url: source), dropping: [.audio])
        var written: (loudness: Double?, peak: Double) = (nil, 0)
        for attempt in 0..<3 {
            sound = sound.with(mixGain: Float(pow(10, mixGain / 20)))
            if attempt > 0 { try? FileManager.default.removeItem(at: destination) }
            _ = try await Remuxer.remux(source, copying: copied.tracks, associations: copied.associations,
                                        adding: [], sound: sound, to: destination, fileType: container.fileType)
            written = try await measure(destination)
            guard written.peak > truePeakLimit else { break }
            mixGain -= written.peak - truePeakLimit + 0.2
        }

        let result = VideoProcessResult(source: source, destination: destination, before: before,
                                        after: try await describe(destination), passedThrough: true,
                                        operations: [], seconds: -started.timeIntervalSinceNow)
        var report: MusicResult?
        if let mixer {
            let steady = Self.steadyGains(mixer.plan)
            report = MusicResult(result: result, speech: speech, reference: reference, musicLoudness: musicLoudness,
                                 musicGain: mixer.plan.gain, musicUnderSpeech: steady.under, musicBetween: steady.between,
                                 mixGain: mixGain, loudness: written.loudness, truePeak: written.peak)
        }
        let effectsReport = placed.map {
            PlacedSound(file: $0.cue.file, time: $0.cue.time, seconds: $0.seconds, reference: $0.reference,
                        level: $0.loudness + $0.gain + mixGain, gain: $0.gain)
        }
        return SoundtrackResult(result: result, speech: speech, music: report, sounds: effectsReport,
                                mixGain: mixGain, loudness: written.loudness, truePeak: written.peak)
    }

    /// A written file's sound, decoded and measured.
    static func measure(_ url: URL) async throws -> (loudness: Double?, peak: Double) {
        let stream = try await PCMStream(url)
        var meter = LoudnessMeter(sampleRate: stream.sampleRate, channels: stream.channels)
        var peak = TruePeakMeter(channels: stream.channels)
        while let chunk = stream.next() {
            meter.add(chunk)
            peak.add(chunk)
        }
        return (meter.integrated, peak.dBTP)
    }

    /// The music's mean gain in dB under speech and between, every 10 ms
    /// clear of the ramps and fades.
    static func steadyGains(_ plan: BedMixer.Plan) -> (under: Double?, between: Double?) {
        var under: [Double] = [], between: [Double] = []
        var time = plan.start
        while time < plan.end {
            let place = BedMixer.steady(at: time, plan: plan)
            let gain = 20 * log10(max(BedMixer.gain(at: time, plan: plan), 1e-12))
            if place.under { under.append(gain) } else if place.between { between.append(gain) }
            time += 0.01
        }
        let mean = { (values: [Double]) in values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return (mean(under), mean(between))
    }
}
