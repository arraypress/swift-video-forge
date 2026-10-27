//
//  EditTimeline.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A whole edit described at once: clips end to end, video over them,
//  anything drawn over that (titles, captions), voice-over, a music bed and
//  sound effects. `compose` renders it with ONE encode of the picture —
//  the chain of separate commands it replaces re-encoded three times.
//
//  Times are seconds on the edit's own timeline, which starts at 0 with the
//  first clip. Draw order is clips, then overlays in order, then drawings
//  in order: the last one listed is on top.
//

import CoreGraphics
import Foundation

/// A whole edit, rendered by ``VideoForge/compose(_:to:export:overwrites:)``.
///
/// ```swift
/// var edit = EditTimeline(clips: [
///     EditClip(hook, from: 1.2, to: 3.4),
///     EditClip(demo, from: 10, to: 18, fit: .blur),
/// ])
/// edit.size = CGSize(width: 1080, height: 1920)
/// edit.overlays = [EditOverlay(broll, start: 4, end: 7, fullFrame: true, fade: 0.3)]
/// edit.voices = [EditSound(voiceOver, start: 0.5)]
/// edit.music = EditMusic(song, bed: MusicBed(level: -14))
/// ```
public struct EditTimeline: Sendable {
    /// The written frame. Nil takes the first clip's frame, as shown.
    public var size: CGSize?
    /// Frames a second. Nil takes the first clip's.
    public var frameRate: Double?
    /// The clips, end to end: the edit's length is theirs.
    public var clips: [EditClip]
    /// Video shown over the clips: a reaction cam, B-roll, a transparent
    /// animation.
    public var overlays: [EditOverlay]
    /// Anything drawn over the picture — titles, captions, stickers — by a
    /// closure, so the drawing can come from any library.
    public var drawings: [EditDrawing]
    /// Sound laid onto the clips' own: a voice-over. Music ducks under it.
    public var voices: [EditSound]
    /// A music bed under everything, ducked while anybody talks.
    public var music: EditMusic?
    /// One-shot sound effects, levelled against the speech around them.
    public var sounds: [SoundCue]
    /// How the sound effects are levelled.
    public var effects: SoundEffects

    public init(clips: [EditClip], size: CGSize? = nil, frameRate: Double? = nil, overlays: [EditOverlay] = [],
                drawings: [EditDrawing] = [], voices: [EditSound] = [], music: EditMusic? = nil,
                sounds: [SoundCue] = [], effects: SoundEffects = SoundEffects()) {
        self.clips = clips
        self.size = size
        self.frameRate = frameRate
        self.overlays = overlays
        self.drawings = drawings
        self.voices = voices
        self.music = music
        self.sounds = sounds
        self.effects = effects
    }
}

/// How a clip fills a frame of another shape.
public enum EditFit: String, Sendable, Codable, CaseIterable, Hashable {
    /// Cover the frame, cropping what overhangs — around ``EditClip/focus``.
    case fill
    /// Show all of it, black around it.
    case fit
    /// Show all of it over a blurred, filled copy of itself — the usual way
    /// to put landscape footage in a vertical frame.
    case blur
}

/// One clip on the edit's main track.
public struct EditClip: Sendable, Equatable {
    public var file: URL
    /// Where in the file it starts, in seconds.
    public var from: Double
    /// Where it ends; nil for the file's end.
    public var to: Double?
    public var fit: EditFit
    /// The point kept in view when ``EditFit/fill`` crops, as shares of the
    /// clip's frame from the top left: (0.5, 0.5) is the centre.
    public var focus: CGPoint
    /// Its own sound's level, 0–2; 0 mutes it.
    public var volume: Double
    /// Seconds to fade up from black at its start, and down at its end.
    public var fadeIn: Double
    public var fadeOut: Double

    public init(_ file: URL, from: Double = 0, to: Double? = nil, fit: EditFit = .fill,
                focus: CGPoint = CGPoint(x: 0.5, y: 0.5), volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.file = file
        self.from = from
        self.to = to
        self.fit = fit
        self.focus = focus
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}

/// Video over the clips.
public struct EditOverlay: Sendable, Equatable {
    public var file: URL
    /// When it appears and goes on the edit; nil end runs it for its own
    /// length, or to the edit's end.
    public var start: Double
    public var end: Double?
    /// Where in its file it starts playing.
    public var from: Double
    /// A corner (``PictureCorner/auto`` is not offered here: there is no
    /// single clip under it to look at) — or ``rect`` or ``fullFrame``.
    public var corner: PictureCorner
    /// Its place as shares of the frame from the top left (x, y, width,
    /// height); beats the corner. The overlay is fitted inside it, centred.
    public var rect: CGRect?
    /// Its width as a share of the frame's, for a corner.
    public var size: Double
    public var margin: Double
    public var roundness: Double
    /// Cover the whole frame: a cut-away.
    public var fullFrame: Bool
    /// Seconds to fade in and out.
    public var fade: Double
    /// Its own sound's level, 0–2; 0, the default, mutes it.
    public var volume: Double

    public init(_ file: URL, start: Double, end: Double? = nil, from: Double = 0, corner: PictureCorner = .bottomRight,
                rect: CGRect? = nil, size: Double = 0.3, margin: Double = 0.04, roundness: Double = 0,
                fullFrame: Bool = false, fade: Double = 0, volume: Double = 0) {
        self.file = file
        self.start = start
        self.end = end
        self.from = from
        self.corner = corner
        self.rect = rect
        self.size = size
        self.margin = margin
        self.roundness = roundness
        self.fullFrame = fullFrame
        self.fade = fade
        self.volume = volume
    }
}

/// Something drawn over the picture between two times: a full-frame image
/// with transparency, asked for at every frame it shows on.
public struct EditDrawing: Sendable {
    public var start: Double
    public var end: Double
    /// The picture at a time on the edit, as big as the frame it is given;
    /// nil draws nothing at that frame. Called from the compositor's
    /// threads, possibly at once — guard any state it keeps.
    public var draw: @Sendable (_ time: Double, _ frame: CGSize) -> CGImage?

    public init(start: Double, end: Double, draw: @escaping @Sendable (_ time: Double, _ frame: CGSize) -> CGImage?) {
        self.start = start
        self.end = end
        self.draw = draw
    }
}

/// Sound laid onto the edit at a time.
public struct EditSound: Sendable, Equatable {
    public var file: URL
    public var start: Double
    /// The stretch of the file used; nil `to` for its end.
    public var from: Double
    public var to: Double?
    /// 0–2.
    public var volume: Double

    public init(_ file: URL, start: Double, from: Double = 0, to: Double? = nil, volume: Double = 1) {
        self.file = file
        self.start = start
        self.from = from
        self.to = to
        self.volume = volume
    }
}

/// The edit's music bed.
public struct EditMusic: Sendable, Equatable {
    public var file: URL
    public var bed: MusicBed

    public init(_ file: URL, bed: MusicBed = MusicBed()) {
        self.file = file
        self.bed = bed
    }
}

extension EditTimeline {

    /// Where each clip lands on an edit, end to end, given each file's
    /// length in seconds — for resolving times that refer to clips before
    /// the edit is rendered.
    public static func ranges(of clips: [EditClip], lengths: [Double]) -> [ClosedRange<Double>] {
        EditRules.clipRanges(clips, lengths: lengths)
    }
}
