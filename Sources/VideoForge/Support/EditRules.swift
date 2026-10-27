//
//  EditRules.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  An edit's arithmetic, pure: what is wrong with it (every problem named by
//  its place, `clips[2].to`, so a caller can fix them all in one go), where
//  each clip lands on the edit, where its picture goes in the frame, and how
//  bright it is through a dip to black. No file is opened here — the lengths
//  of the files come in as numbers — so every rule is pinned by a test.
//

import CoreGraphics
import Foundation

enum EditRules {

    /// How long each kind of file is, in seconds, for the checks.
    struct Lengths: Sendable, Equatable {
        var clips: [Double]
        /// Each clip's file has a picture.
        var clipsHaveVideo: [Bool]
        var overlays: [Double]
        var voices: [Double]
    }

    // MARK: - Problems

    /// Every problem with the edit, each with its place; empty when it can
    /// be rendered.
    static func problems(in edit: EditTimeline, lengths: Lengths) -> [String] {
        var found: [String] = []
        func add(_ place: String, _ text: String) { found.append("\(place): \(text)") }
        if edit.clips.isEmpty { add("clips", "an edit needs at least one clip") }
        if let size = edit.size, !(size.width >= 16 && size.height >= 16 && size.width <= 8192 && size.height <= 8192) {
            add("size", "must be 16–8192 pixels each way")
        }
        if let size = edit.size, Int(size.width) % 2 != 0 || Int(size.height) % 2 != 0 {
            add("size", "must be even each way — video encoders refuse odd sizes")
        }
        if let fps = edit.frameRate, !(fps >= 1 && fps <= 240) { add("fps", "must be 1–240") }

        for (index, clip) in edit.clips.enumerated() {
            let place = "clips[\(index)]"
            let length = index < lengths.clips.count ? lengths.clips[index] : 0
            if index < lengths.clipsHaveVideo.count, !lengths.clipsHaveVideo[index] {
                add(place + ".file", "\(clip.file.lastPathComponent) has no picture")
            }
            if !(clip.from >= 0) { add(place + ".from", "must be 0 or more") }
            if clip.from >= length { add(place + ".from", String(format: "%.2f s is past the file's end (%.2f s)", clip.from, length)) }
            if let to = clip.to {
                if to <= clip.from { add(place + ".to", "must be after from") }
                if to > length + 0.01 { add(place + ".to", String(format: "%.2f s is past the file's end (%.2f s)", to, length)) }
            }
            if !(0...2).contains(clip.volume) { add(place + ".volume", "must be 0–2") }
            if !(0...1).contains(clip.focus.x) || !(0...1).contains(clip.focus.y) { add(place + ".focus", "is shares of the frame, 0–1") }
            let span = clipSpan(clip, length: length)
            if clip.fadeIn < 0 || clip.fadeOut < 0 { add(place, "fades must be 0 or more") }
            if span > 0, clip.fadeIn + clip.fadeOut > span + 1e-9 {
                add(place, String(format: "fade_in + fade_out (%.2f s) is longer than the clip (%.2f s)", clip.fadeIn + clip.fadeOut, span))
            }
        }
        let total = duration(of: edit.clips, lengths: lengths.clips)

        for (index, overlay) in edit.overlays.enumerated() {
            let place = "overlays[\(index)]"
            let length = index < lengths.overlays.count ? lengths.overlays[index] : 0
            if overlay.corner == .auto { add(place + ".corner", "auto is not offered in an edit — name a corner, a rect or full_frame") }
            if !(overlay.start >= 0) { add(place + ".start", "must be 0 or more") }
            if overlay.start >= total { add(place + ".start", String(format: "%.2f s is after the edit ends (%.2f s)", overlay.start, total)) }
            if let end = overlay.end, end <= overlay.start { add(place + ".end", "must be after start") }
            if overlay.from < 0 || overlay.from >= length {
                add(place + ".from", String(format: "%.2f s is outside the file (%.2f s)", overlay.from, length))
            }
            if let rect = overlay.rect, !(rect.minX >= 0 && rect.minY >= 0 && rect.width > 0 && rect.height > 0
                                          && rect.maxX <= 1.0001 && rect.maxY <= 1.0001) {
                add(place + ".rect", "is [x, y, width, height] as shares of the frame, inside it")
            }
            if !(0.05...1).contains(overlay.size) { add(place + ".size", "must be 0.05–1") }
            if !(0...0.45).contains(overlay.margin) { add(place + ".margin", "must be 0–0.45") }
            if !(0...0.5).contains(overlay.roundness) { add(place + ".roundness", "must be 0–0.5") }
            if overlay.fade < 0 { add(place + ".fade", "must be 0 or more") }
            if !(0...2).contains(overlay.volume) { add(place + ".volume", "must be 0–2") }
        }
        for (index, drawing) in edit.drawings.enumerated() where !(drawing.end > drawing.start && drawing.start >= 0) {
            add("drawings[\(index)]", "must end after it starts, from 0")
        }
        for (index, voice) in edit.voices.enumerated() {
            let place = "voices[\(index)]"
            let length = index < lengths.voices.count ? lengths.voices[index] : 0
            if !(voice.start >= 0) || voice.start >= total {
                add(place + ".start", String(format: "%.2f s is outside the edit (%.2f s)", voice.start, total))
            }
            if voice.from < 0 || voice.from >= length { add(place + ".from", String(format: "%.2f s is outside the file (%.2f s)", voice.from, length)) }
            if let to = voice.to, to <= voice.from { add(place + ".to", "must be after from") }
            if !(0...2).contains(voice.volume) { add(place + ".volume", "must be 0–2") }
        }
        if let music = edit.music, let problem = music.bed.problem { add("music", problem) }
        if let music = edit.music, music.bed.start >= total { add("music.start", "is after the edit ends") }
        for (index, sound) in edit.sounds.enumerated() where !(sound.time >= 0 && sound.time < total) {
            add("sounds[\(index)].at", String(format: "%.2f s is outside the edit (%.2f s)", sound.time, total))
        }
        if let problem = edit.effects.problem { add("effects", problem) }
        return found
    }

    // MARK: - Where things land

    /// How much of its file a clip uses, in seconds.
    static func clipSpan(_ clip: EditClip, length: Double) -> Double {
        max(0, min(clip.to ?? length, length) - clip.from)
    }

    /// Each clip's stretch of the edit, end to end.
    static func clipRanges(_ clips: [EditClip], lengths: [Double]) -> [ClosedRange<Double>] {
        var cursor = 0.0
        return clips.enumerated().map { index, clip in
            let span = clipSpan(clip, length: index < lengths.count ? lengths[index] : 0)
            defer { cursor += span }
            return cursor...(cursor + span)
        }
    }

    /// The edit's length: its clips'.
    static func duration(of clips: [EditClip], lengths: [Double]) -> Double {
        clipRanges(clips, lengths: lengths).last?.upperBound ?? 0
    }

    /// When an overlay shows on the edit: to its end, its file's end or the
    /// edit's, whichever is first.
    static func window(of overlay: EditOverlay, length: Double, total: Double) -> ClosedRange<Double> {
        let stop = min(overlay.end ?? .infinity, overlay.start + max(0, length - overlay.from), total)
        return overlay.start...max(overlay.start, stop)
    }

    /// Every time something starts or stops, sorted, from 0 to the end —
    /// the edges of the compositor's instructions.
    static func edges(clips: [ClosedRange<Double>], overlays: [ClosedRange<Double>], total: Double) -> [Double] {
        var times: Set<Double> = [0, total]
        for range in clips + overlays { times.insert(range.lowerBound); times.insert(range.upperBound) }
        return times.filter { $0 >= 0 && $0 <= total }.sorted()
    }

    // MARK: - The picture

    /// Where an upright clip's picture goes in the frame, from the top left:
    /// covering it around the focus point, or fitted inside it, centred.
    static func placement(of source: CGSize, in frame: CGSize, fit: EditFit, focus: CGPoint) -> CGRect {
        guard source.width > 0, source.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: frame)
        }
        switch fit {
        case .fit, .blur:
            let scale = min(frame.width / source.width, frame.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                          width: size.width, height: size.height)
        case .fill:
            let scale = max(frame.width / source.width, frame.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            // The focus point as near the frame's centre as the overhang allows.
            let x = min(0, max(frame.width - size.width, frame.width / 2 - focus.x * size.width))
            let y = min(0, max(frame.height - size.height, frame.height / 2 - focus.y * size.height))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// Where an overlay goes, from the top left.
    static func overlayRect(_ overlay: EditOverlay, frame: CGSize, source: CGSize) -> CGRect {
        if overlay.fullFrame { return OverlayLayout.cover(frame: frame, overlay: source) }
        if let share = overlay.rect {
            let box = CGRect(x: share.minX * frame.width, y: share.minY * frame.height,
                             width: share.width * frame.width, height: share.height * frame.height)
            let fitted = placement(of: source, in: box.size, fit: .fit, focus: CGPoint(x: 0.5, y: 0.5))
            return fitted.offsetBy(dx: box.minX, dy: box.minY).integral
        }
        return OverlayLayout.rect(for: overlay.corner, frame: frame, overlay: source, size: overlay.size, margin: overlay.margin)
    }

    /// A clip's brightness at a time through its dips to black, 0–1. Like an
    /// overlay's fade, each frame is lit as if sampled at its end, so the
    /// first frame of a fade-in is not black.
    static func brightness(at time: Double, range: ClosedRange<Double>, fadeIn: Double, fadeOut: Double,
                           frameDuration: Double) -> Double {
        var level = 1.0
        if fadeIn > 0 { level = min(level, (time - range.lowerBound + frameDuration) / fadeIn) }
        if fadeOut > 0 { level = min(level, (range.upperBound - time) / fadeOut) }
        return max(0, min(1, level))
    }
}
