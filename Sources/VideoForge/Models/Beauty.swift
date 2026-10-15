//
//  Beauty.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Skin smoothing and face retouching for talking-head footage, on-device.
//  Smoothing is swift-video-grade's skin filter — Vision finds the faces, a
//  skin-tone key keeps eyes, brows, lips and hair sharp. The retouch is
//  swift-face-beauty's, driven by a landmark track of the largest face.
//

import FaceBeauty
import Foundation

/// How faces are smoothed and retouched.
///
/// The defaults soften skin and lift the under-eyes and teeth a little,
/// and reshape nothing: a warp that looks wrong is worse than none, and
/// nobody is looking.
public struct Beauty: Sendable, Codable, Equatable {
    /// How much of the skin's fine texture is softened away, 0–1.
    public var smoothing: Double
    /// The retouch amounts, 0–1 each, and — once tracked — the face's
    /// landmarks. Leave `keyframes` empty: they are tracked from the clip.
    public var retouch: FaceBeauty

    /// - Parameters:
    ///   - smoothing: How much fine skin texture is softened, 0–1.
    ///   - retouch: The retouch amounts.
    public init(smoothing: Double = 0.5, retouch: FaceBeauty = Beauty.gentle) {
        self.smoothing = smoothing
        self.retouch = retouch
    }

    /// The default retouch: under-eyes and teeth lifted a little, eyes
    /// brightened a little, no reshaping.
    public static let gentle = FaceBeauty(eyeEnlarge: 0, faceSlim: 0, noseSlim: 0, eyeBrighten: 0.2,
                                          underEye: 0.25, teethWhiten: 0.25)

    /// Whether any retouch amount is above zero — which needs the face
    /// tracked first.
    public var retouches: Bool {
        [retouch.eyeEnlarge, retouch.faceSlim, retouch.noseSlim, retouch.eyeBrighten, retouch.underEye,
         retouch.teethWhiten, retouch.lipTint, retouch.blush, retouch.browDefine].contains { $0 > 0 }
    }
}
