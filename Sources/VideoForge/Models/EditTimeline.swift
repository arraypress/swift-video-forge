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

    /// An edit.
    ///
    /// - Parameters:
    ///   - clips: The clips, end to end.
    ///   - size: The written frame; nil for the first clip's.
    ///   - frameRate: Frames a second; nil for the first clip's.
    ///   - overlays: Video over the clips.
    ///   - drawings: Titles, captions and anything else drawn over the picture.
    ///   - voices: Sound laid onto the clips' own.
    ///   - music: A music bed under everything.
    ///   - sounds: One-shot sound effects.
    ///   - effects: How the sound effects are levelled.
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
