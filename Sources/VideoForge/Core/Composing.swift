//
//  Composing.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Building an edit: one composition holding every clip end to end on one
//  picture track and one sound track, each overlay's picture (and sound,
//  when it is wanted) on tracks of its own, each voice-over on its own; the
//  compositor's instructions cut at every edge; and the sound mix that sets
//  each clip's, overlay's and voice's level. Nothing here decodes a frame.
//

import AVFoundation
import CoreGraphics
import Foundation

enum Composing {

    /// An edit, checked, with what was learned opening its files.
    struct Job: Sendable {
        let edit: EditTimeline
        let lengths: EditRules.Lengths
        /// The written frame.
        let frame: CGSize
    }

    /// A built edit.
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
        /// Each clip's stretch of the edit.
        let clipRanges: [ClosedRange<Double>]
    }

    static let scale: CMTimeScale = 600_000

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: scale) }

    /// The composition, its instructions and its mix.
    static func build(_ job: Job, keepsAudio: Bool, frameRate: Double?) async throws -> sending Built {
        let edit = job.edit
        let composition = AVMutableComposition()
        guard let mainVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoForgeError.exportFailed(reason: "the picture track could not be made")
        }
        let mainAudio = keepsAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var mixes: [AVMutableAudioMixInputParameters] = []
        let mainMix = mainAudio.map { AVMutableAudioMixInputParameters(track: $0) }
        var heard = false
        var clipsHeard = false

        // The clips, end to end.
        let ranges = EditRules.clipRanges(edit.clips, lengths: job.lengths.clips)
        var clips: [ComposePlan.Clip] = []
        var firstFormat: CMFormatDescription?
        var firstMinFrame = CMTime.invalid
        for (index, clip) in edit.clips.enumerated() {
            let asset = AVURLAsset(url: clip.file)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoForgeError.noVideoTrack(clip.file)
            }
            let range = ranges[index]
            let at = time(range.lowerBound)
            let span = CMTimeRange(start: time(clip.from), duration: time(range.upperBound - range.lowerBound))
            try mainVideo.insertTimeRange(span, of: source, at: at)
            let (transform, natural, formats, minFrame) = try await source.load(.preferredTransform, .naturalSize,
                                                                               .formatDescriptions, .minFrameDuration)
            if index == 0 { (firstFormat, firstMinFrame) = (formats.first, minFrame) }
            let shown = CGRect(origin: .zero, size: natural).applying(transform).size
            let upright = CGSize(width: abs(shown.width), height: abs(shown.height))
            clips.append(ComposePlan.Clip(range: range, transform: transform,
                                          rect: EditRules.placement(of: upright, in: job.frame, fit: clip.fit, focus: clip.focus),
                                          fit: clip.fit, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut))
            if let mainAudio {
                if let sound = try await asset.loadTracks(withMediaType: .audio).first, clip.volume > 0 {
                    try mainAudio.insertTimeRange(span, of: sound, at: at)
                    (heard, clipsHeard) = (true, true)
                } else {
                    // A silent clip still takes its time, or the sound after it slides forward.
                    mainAudio.insertEmptyTimeRange(CMTimeRange(start: at, duration: span.duration))
                }
                mainMix?.setVolume(Float(clip.volume), at: at)
            }
        }
        mainVideo.preferredTransform = .identity
        let total = ranges.last?.upperBound ?? 0

        // The overlays, each on tracks of its own.
        var overlays: [ComposePlan.Overlay] = []
        for (index, overlay) in edit.overlays.enumerated() {
            let asset = AVURLAsset(url: overlay.file)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoForgeError.noVideoTrack(overlay.file)
            }
            let length = index < job.lengths.overlays.count ? job.lengths.overlays[index] : 0
            let window = EditRules.window(of: overlay, length: length, total: total)
            guard window.upperBound > window.lowerBound + 0.001 else { continue }
            let span = CMTimeRange(start: time(overlay.from), duration: time(window.upperBound - window.lowerBound))
            try track.insertTimeRange(span, of: source, at: time(window.lowerBound))
            track.preferredTransform = .identity
            let (transform, natural) = try await source.load(.preferredTransform, .naturalSize)
            let shown = CGRect(origin: .zero, size: natural).applying(transform).size
            let rect = EditRules.overlayRect(overlay, frame: job.frame,
                                             source: CGSize(width: abs(shown.width), height: abs(shown.height)))
            overlays.append(ComposePlan.Overlay(
                track: track.trackID, transform: transform, window: window, rect: rect,
                radius: overlay.fullFrame ? 0 : OverlayLayout.radius(roundness: overlay.roundness, of: rect),
                fade: overlay.fade))
            if keepsAudio, overlay.volume > 0, let sound = try await asset.loadTracks(withMediaType: .audio).first,
               let soundTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try soundTrack.insertTimeRange(span, of: sound, at: time(window.lowerBound))
                mixes.append(faded(soundTrack, level: overlay.volume, window: window, fade: overlay.fade))
                heard = true
            }
        }

        // The voices.
        if keepsAudio {
            for (index, voice) in edit.voices.enumerated() {
                let asset = AVURLAsset(url: voice.file)
                guard let sound = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw VideoForgeError.noAudioTrack(voice.file)
                }
                let length = index < job.lengths.voices.count ? job.lengths.voices[index] : 0
                let stop = min(voice.to ?? length, length, voice.from + (total - voice.start))
                guard stop > voice.from + 0.001,
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(CMTimeRange(start: time(voice.from), duration: time(stop - voice.from)),
                                          of: sound, at: time(voice.start))
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(Float(voice.volume), at: .zero)
                mixes.append(parameters)
                heard = true
            }
        }
        // A sound track of nothing but empty edits fails the export
        // ("Operation Stopped", measured on `vid join`): none at all instead.
        if let mainAudio, !clipsHeard {
            composition.removeTrack(mainAudio)
        } else if let mainMix {
            mixes.insert(mainMix, at: 0)
        }
        let audioMix: AVAudioMix? = mixes.isEmpty || !heard ? nil : {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixes
            return mix
        }()

        // The pictures.
        let colour = firstFormat.flatMap(FormatDescriptions.colour(of:))
        let frameDuration = frameRate.map { WriterRules.frameDuration(fps: $0) }
            ?? (firstMinFrame.isNumeric && firstMinFrame > .zero ? firstMinFrame : CMTime(value: 1, timescale: 30))
        let plan = ComposePlan(
            mainTrack: mainVideo.trackID, clips: clips, overlays: overlays, drawings: edit.drawings,
            frame: job.frame, frameDuration: frameDuration.seconds,
            primaries: colour?.primaries ?? AVVideoColorPrimaries_ITU_R_709_2,
            transfer: colour?.transfer ?? AVVideoTransferFunction_ITU_R_709_2,
            matrix: colour?.matrix ?? AVVideoYCbCrMatrix_ITU_R_709_2)
        let instructions = Self.instructions(plan: plan, total: total)
        let videoComposition = AVVideoComposition(configuration: AVVideoComposition.Configuration(
            colorPrimaries: plan.primaries, colorTransferFunction: plan.transfer, colorYCbCrMatrix: plan.matrix,
            customVideoCompositorClass: ComposeCompositor.self, frameDuration: frameDuration,
            instructions: instructions, renderSize: job.frame,
            // Frames at the edit's own rate, whatever each clip's was.
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid))
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix, clipRanges: ranges)
    }

    /// The instructions: one per stretch between two edges, naming the clip
    /// and the overlays on screen in it.
    static func instructions(plan: ComposePlan, total: Double) -> [ComposeInstruction] {
        let edges = EditRules.edges(clips: plan.clips.map(\.range), overlays: plan.overlays.map(\.window), total: total)
        var made: [ComposeInstruction] = []
        for (from, to) in zip(edges, edges.dropFirst()) where to > from {
            let middle = (from + to) / 2
            let clip = plan.clips.firstIndex { $0.range.contains(middle) }
            let shown = plan.overlays.indices.filter { plan.overlays[$0].window.contains(middle) }
            // Each instruction starts where the last ended, exactly: CMTime
            // rounding of two separately converted seconds can leave a gap
            // the composition validator refuses.
            let start = made.last.map { $0.timeRange.end } ?? .zero
            let end = to >= total ? time(total) : time(to)
            made.append(ComposeInstruction(timeRange: CMTimeRange(start: start, end: end), plan: plan,
                                           clip: clip, overlays: shown))
        }
        return made
    }

    /// An overlay's sound at its level, faded with its picture.
    private static func faded(_ track: AVMutableCompositionTrack, level: Double, window: ClosedRange<Double>,
                              fade: Double) -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let value = Float(level)
        let length = min(fade, (window.upperBound - window.lowerBound) / 2)
        guard length > 0 else {
            parameters.setVolume(value, at: .zero)
            return parameters
        }
        let ramp = time(length)
        parameters.setVolume(0, at: .zero)
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: value,
                                 timeRange: CMTimeRange(start: time(window.lowerBound), duration: ramp))
        parameters.setVolumeRamp(fromStartVolume: value, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: time(window.upperBound) - ramp, duration: ramp))
        return parameters
    }
}
