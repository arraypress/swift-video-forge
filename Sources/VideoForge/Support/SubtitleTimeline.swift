//
//  SubtitleTimeline.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Cues overlap; samples in a track cannot. Writing cuts the timeline at
//  every cue boundary and puts in each piece every cue on screen during it,
//  stacked in the order they appeared — which is what a viewer would see.
//  Reading reverses it as far as it can be reversed: consecutive pieces
//  with the same text become one cue, and gaps disappear. Two overlapping
//  cues therefore come back as the three pieces actually shown.
//

import Foundation
import SubtitleKit

/// Converts between cues and the non-overlapping pieces a track holds.
enum SubtitleTimeline {

    /// One stretch of a track: text, or `""` for a gap.
    struct Piece: Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    /// The pieces a track needs to show `cues` within `duration` seconds:
    /// covering from zero to the last cue's end without a hole, gaps empty,
    /// anything past `duration` cut off and empty or zero-length cues
    /// dropped.
    static func pieces(of cues: [SubtitleCue], within duration: Double) -> [Piece] {
        let shown = cues
            .filter { !$0.isEmpty && $0.start < duration }
            .map { SubtitleCue(start: $0.start, end: min($0.end, duration), text: $0.text) }
        let bounds = Array(Set(shown.flatMap { [$0.start, $0.end] } + [0])).sorted()
        guard bounds.count > 1 else { return [] }
        var pieces: [Piece] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let text = shown
                .filter { $0.start < end && $0.end > start }
                .map(\.text)
                .joined(separator: "\n")
            if let last = pieces.last, last.text == text, last.end == start {
                pieces[pieces.count - 1] = Piece(start: last.start, end: end, text: text)
            } else {
                pieces.append(Piece(start: start, end: end, text: text))
            }
        }
        return pieces
    }

    /// Cues back out of a track's pieces: neighbours with the same text
    /// joined, gaps dropped.
    static func cues(from pieces: [Piece]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for piece in pieces where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = cues.last, last.text == piece.text, abs(last.end - piece.start) < 0.001 {
                cues[cues.count - 1].end = piece.end
            } else {
                cues.append(SubtitleCue(start: piece.start, end: piece.end, text: piece.text))
            }
        }
        return cues
    }

    /// Cues out of `wvtt` samples, where each cue on screen is its own box:
    /// a cue lasts while consecutive samples keep carrying its text.
    static func cues(fromConcurrent samples: [(start: Double, end: Double, texts: [String])]) -> [SubtitleCue] {
        var finished: [SubtitleCue] = []
        var open: [SubtitleCue] = []
        for sample in samples {
            var stillOpen: [SubtitleCue] = []
            for cue in open {
                if sample.texts.contains(cue.text), abs(cue.end - sample.start) < 0.001 {
                    stillOpen.append(SubtitleCue(start: cue.start, end: sample.end, text: cue.text))
                } else {
                    finished.append(cue)
                }
            }
            for text in sample.texts where !stillOpen.contains(where: { $0.text == text }) {
                stillOpen.append(SubtitleCue(start: sample.start, end: sample.end, text: text))
            }
            open = stillOpen
        }
        return (finished + open).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }
}
