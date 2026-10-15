//
//  VideoForge+Beauty.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Skin smoothing and face retouching. The retouch follows the largest
//  face through a landmark track sampled four times a second
//  (swift-face-beauty), so it is tracked before the frames are redrawn;
//  smoothing finds the faces in every frame itself.
//

import FaceBeauty
import Foundation

extension VideoForge {

    /// Smooths and retouches the faces in a clip and writes it.
    ///
    /// - Parameters:
    ///   - source: The clip.
    ///   - destination: Where to write.
    ///   - beauty: How much.
    ///   - export: How to write it.
    ///   - overwrites: Whether an existing file may be replaced.
    /// - Returns: What happened, and how many samples of the clip a face
    ///   was tracked in (0 when nothing needed tracking or none was found).
    /// - Throws: Any ``VideoForgeError``.
    @discardableResult
    public static func beautify(_ source: URL, to destination: URL, beauty: Beauty = Beauty(),
                                export: ExportSpec = ExportSpec(),
                                overwrites: Bool = false) async throws -> BeautyResult {
        guard (0...1).contains(beauty.smoothing) else {
            throw VideoForgeError.invalidOptions("smoothing is 0 to 1")
        }
        var tracked = beauty
        if beauty.retouches, beauty.retouch.keyframes.isEmpty {
            tracked.retouch.keyframes = try await faceTrack(source)
        }
        let result = try await process(source, to: destination, options: VideoProcessOptions(
            operations: [.beauty(tracked)], export: export, overwrites: overwrites))
        return BeautyResult(result: result, faceSamples: tracked.retouch.keyframes.count)
    }

    /// The largest face's landmarks through a clip.
    static func faceTrack(_ source: URL) async throws -> [FaceLandmarkFrame] {
        do { return try await FaceLandmarkTracker.track(videoURL: source) } catch {
            throw VideoForgeError.unreadable(source, reason: error.localizedDescription)
        }
    }

    /// The operations with every beauty step's landmarks tracked, when it
    /// retouches and has none yet.
    static func tracked(_ operations: [VideoOperation], source: URL, duration: Double) async throws -> [VideoOperation] {
        guard operations.contains(where: { if case .beauty(let b) = $0 { b.retouches && b.retouch.keyframes.isEmpty } else { false } }) else {
            return operations
        }
        let track = BeautyTiming.retimed(try await faceTrack(source), through: operations, sourceDuration: duration)
        return operations.map { operation in
            guard case .beauty(var beauty) = operation, beauty.retouches, beauty.retouch.keyframes.isEmpty else {
                return operation
            }
            beauty.retouch.keyframes = track
            return .beauty(beauty)
        }
    }
}
