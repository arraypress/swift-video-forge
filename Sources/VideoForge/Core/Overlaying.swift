//
//  Overlaying.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Building a picture-in-picture: deciding where the overlay goes (looking
//  for faces when the corner is automatic), and the composition that puts
//  it there — the main clip's tracks, the overlay's picture from its start,
//  its sound when asked for, and the custom compositor's instructions.
//
//  The overlay's track is inserted at the asked start, so the first frame
//  it appears on is the first main frame at or after that time, and its
//  own first frame is the one shown there.
//

import AVFoundation
import CoreGraphics
import Foundation

/// Picture-in-picture compositions.
enum Overlaying {

    /// What a picture-in-picture job is, decided before anything is built.
    struct Job: Sendable {
        let main: URL
        let overlay: URL
        let pip: PictureInPicture
        let placement: OverlayPlacement
        /// The main clip's frame as shown, which is the written frame.
        let frame: CGSize
    }

    /// A built picture-in-picture.
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
        let sidecars: [Remuxer.MadeTrack]
    }

    // MARK: - Where

    /// Where the overlay goes and when: the stretch it shows for, and its
    /// rectangle — a corner's, found by looking for faces when it is
    /// automatic, or the covering one for a full-frame overlay.
    static func place(_ pip: PictureInPicture, main: URL, mainInfo: VideoInfo,
                      overlayInfo: VideoInfo) async throws -> OverlayPlacement {
        if let problem = OverlayLayout.problem(with: pip) { throw VideoForgeError.invalidOptions(problem) }
        let window = try OverlayLayout.window(start: pip.start, end: pip.end, overlayDuration: overlayInfo.duration,
                                              mainDuration: mainInfo.duration)
        let frame = mainInfo.size
        if pip.fullFrame {
            return OverlayPlacement(corner: nil, rect: OverlayLayout.cover(frame: frame, overlay: overlayInfo.size),
                                    start: window.start, end: window.end,
                                    framesScanned: 0, facesSeen: 0, faceCoverage: 0)
        }
        let rect = { (corner: PictureCorner) in
            OverlayLayout.rect(for: corner, frame: frame, overlay: overlayInfo.size, size: pip.size, margin: pip.margin)
        }
        let scan = try await FaceScan.faces(in: main, from: window.start, to: window.end, frame: frame)
        let candidates = pip.corner == .auto
            ? PictureCorner.corners.map { ($0, rect($0)) }
            : [(pip.corner, rect(pip.corner))]
        let chosen = OverlayLayout.choose(among: candidates, faces: scan.faces)
        return OverlayPlacement(corner: chosen.corner, rect: chosen.rect, start: window.start, end: window.end,
                                framesScanned: scan.frames, facesSeen: scan.faces.count,
                                faceCoverage: chosen.coverage)
    }

    // MARK: - The composition

    /// The composition, its compositor instructions and its sound mix.
    ///
    /// - Parameters:
    ///   - job: The clips and where the overlay goes.
    ///   - export: How it is written — whether the sound and the sidecar
    ///     tracks are kept, and any frame rate.
    ///   - container: The container, which decides whether subtitles go.
    /// - Returns: Everything an export or a writer needs.
    static func build(_ job: Job, export: ExportSpec, container: VideoContainer) async throws -> sending Built {
        let mainAsset = AVURLAsset(url: job.main)
        let overlayAsset = AVURLAsset(url: job.overlay)
        let composition = try await Composer.build(from: mainAsset, operations: [], keepsAudio: export.keepsAudio,
                                                   keepsSidecarTracks: export.keepsSidecarTracks)
        let sidecars = container.holdsSubtitles
            ? try await VideoForge.detachSparseTracks(from: composition, of: mainAsset, url: job.main) : []

        guard let mainTrack = composition.tracks(withMediaType: .video).first,
              let mainSource = try await mainAsset.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(job.main)
        }
        guard let overlaySource = try await overlayAsset.loadTracks(withMediaType: .video).first else {
            throw VideoForgeError.noVideoTrack(job.overlay)
        }
        let placement = job.placement
        let at = CMTime(seconds: placement.start, preferredTimescale: 600_000)
        let length = CMTime(seconds: placement.end - placement.start, preferredTimescale: 600_000)
        let overlayRange = CMTimeRange(start: .zero, duration: length)
        guard let overlayTrack = composition.addMutableTrack(withMediaType: .video,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoForgeError.exportFailed(reason: "the overlay's picture could not be added")
        }
        try overlayTrack.insertTimeRange(overlayRange, of: overlaySource, at: at)

        // The overlay's sound, when it is wanted: under the main clip's, at
        // `mix`, faded with the picture.
        var audioMix: AVAudioMix?
        if job.pip.mix > 0, export.keepsAudio,
           let overlaySound = try await overlayAsset.loadTracks(withMediaType: .audio).first,
           let soundTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try soundTrack.insertTimeRange(overlayRange, of: overlaySound, at: at)
            let parameters = AVMutableAudioMixInputParameters(track: soundTrack)
            let level = Float(job.pip.mix)
            let fade = min(job.pip.fade, (placement.end - placement.start) / 2)
            if fade > 0 {
                let fadeTime = CMTime(seconds: fade, preferredTimescale: 600_000)
                parameters.setVolume(0, at: .zero)
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                         timeRange: CMTimeRange(start: at, duration: fadeTime))
                parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: at + length - fadeTime, duration: fadeTime))
            } else {
                parameters.setVolume(level, at: .zero)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        }

        let (mainTransform, minFrame, formats) = try await mainSource.load(.preferredTransform, .minFrameDuration,
                                                                          .formatDescriptions)
        let overlayTransform = try await overlaySource.load(.preferredTransform)
        // Upright in the compositor: the written track carries no turn.
        mainTrack.preferredTransform = .identity
        overlayTrack.preferredTransform = .identity

        let colour = formats.first.flatMap(FormatDescriptions.colour(of:))
        let frameDuration = export.frameRate.map { WriterRules.frameDuration(fps: $0) }
            ?? (minFrame.isNumeric && minFrame > .zero ? minFrame : CMTime(value: 1, timescale: 30))
        let plan = OverlayPlan(
            mainTrack: mainTrack.trackID, overlayTrack: overlayTrack.trackID,
            mainTransform: mainTransform, overlayTransform: overlayTransform,
            frame: job.frame,
            rect: placement.rect,
            radius: placement.corner == nil ? 0 : OverlayLayout.radius(roundness: job.pip.roundness, of: placement.rect),
            start: placement.start, end: placement.end, fade: job.pip.fade, frameDuration: frameDuration.seconds,
            primaries: colour?.primaries ?? AVVideoColorPrimaries_ITU_R_709_2,
            transfer: colour?.transfer ?? AVVideoTransferFunction_ITU_R_709_2,
            matrix: colour?.matrix ?? AVVideoYCbCrMatrix_ITU_R_709_2)

        let duration = composition.duration
        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        for (from, to, shows) in [(CMTime.zero, at, false), (at, at + length, true), (at + length, duration, false)]
        where to > from {
            instructions.append(OverlayInstruction(timeRange: CMTimeRange(start: from, end: min(to, duration)),
                                                   plan: plan, showsOverlay: shows))
        }
        let videoComposition = AVVideoComposition(configuration: AVVideoComposition.Configuration(
            colorPrimaries: plan.primaries, colorTransferFunction: plan.transfer, colorYCbCrMatrix: plan.matrix,
            customVideoCompositorClass: OverlayCompositor.self, frameDuration: frameDuration,
            instructions: instructions, renderSize: plan.frame,
            // The main clip's own frame times, unless a rate was asked for.
            sourceTrackIDForFrameTiming: export.frameRate == nil ? mainTrack.trackID : kCMPersistentTrackID_Invalid))
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                     sidecars: sidecars)
    }
}
