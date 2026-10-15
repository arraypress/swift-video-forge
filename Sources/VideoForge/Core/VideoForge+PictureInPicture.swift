//
//  VideoForge+PictureInPicture.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One clip over another: a reaction cam in a corner, or a cut-away of
//  B-roll over the whole frame. The main clip's sound, subtitles and timed
//  metadata come along; the overlay's sound is muted unless mixed in.
//
//  It is a redraw, so it is written the way every redraw is: the codec the
//  export asks for, resolved against the MAIN clip (a 10-bit main clip
//  stays 10-bit, and refuses an 8-bit codec), through an export session —
//  or the writer road for a bitrate, a quality, a frame rate or ProRes
//  4444, through the one shared WriterPump.
//

import AVFoundation
import Foundation

extension VideoForge {

    /// Shows `overlay` over `main` and writes the result.
    ///
    /// ```swift
    /// // A reaction cam from 2 s, in the corner that covers no face.
    /// let done = try await VideoForge.pictureInPicture(talk, overlay: cam, to: out,
    ///     options: PictureInPicture(start: 2, roundness: 0.1))
    /// done.placement.corner        // .topLeft, say
    /// done.placement.faceCoverage  // 0
    /// ```
    ///
    /// - Parameters:
    ///   - main: The clip underneath; its frame, length and sound are the
    ///     result's.
    ///   - overlay: The clip on top.
    ///   - destination: Where to write.
    ///   - options: Where, when and how the overlay shows.
    ///   - export: How to write it.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened, and where the overlay went.
    /// - Throws: ``VideoForgeError/invalidOptions(_:)`` for settings that
    ///   cannot be honoured, or any other ``VideoForgeError``.
    @discardableResult
    public static func pictureInPicture(_ main: URL, overlay: URL, to destination: URL,
                                        options: PictureInPicture = PictureInPicture(),
                                        export: ExportSpec = ExportSpec(),
                                        overwrites: Bool = false) async throws -> PictureInPictureResult {
        let started = Date()
        if let problem = options.problem { throw VideoForgeError.invalidOptions(problem) }
        let before = try await describe(main)
        let other = try await describe(overlay)
        guard before.hasVideo else { throw VideoForgeError.noVideoTrack(main) }
        guard other.hasVideo else { throw VideoForgeError.noVideoTrack(overlay) }
        let codec = try export.codec(for: before)
        let container = try export.container(for: before, destination: destination)
        try check(destination, overwrites: overwrites)

        let placement = try await Overlaying.place(options, main: main, mainInfo: before, overlayInfo: other)
        let job = Overlaying.Job(main: main, overlay: overlay, pip: options, placement: placement, frame: before.size)

        if CodecPlan.usesWriter(export, codec: codec, redraws: true) {
            try await Transcoder.write(.overlay(job), export: export, codec: codec,
                                       container: container, to: destination)
        } else {
            let built = try await Overlaying.build(job, export: export, container: container)
            try await Self.export(built.composition, carrying: built.sidecars, to: destination,
                                  container: container, preset: CodecPlan.preset(for: codec),
                                  videoComposition: built.videoComposition, audioMix: built.audioMix)
        }
        let result = VideoProcessResult(source: main, destination: destination, before: before,
                                        after: try await describe(destination), passedThrough: false,
                                        operations: [], seconds: -started.timeIntervalSinceNow)
        return PictureInPictureResult(result: result, placement: placement)
    }
}
