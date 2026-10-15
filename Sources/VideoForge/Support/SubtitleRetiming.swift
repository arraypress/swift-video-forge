//
//  SubtitleRetiming.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Subtitle samples moved through a track's edits, sample by sample.
//
//  MEASURED (0.5.0, trims of 0.25, 1.0, 1.5 and 2.5 s): a composition
//  export cannot shorten a sample, so a cut that falls inside a subtitle
//  sample keeps the whole sample and an edit list that starts partway
//  into it (`elst` media time 250 for a 0.25 s trim). AVPlayer honours
//  that edit; ffmpeg does not — it showed every cue 0.5–0.75 s early — and
//  `AVAssetReaderTrackOutput` hands a subtitle track's samples back in
//  MEDIA time, edit ignored, so reading the file showed them late by the
//  same edit. A trim that happened to land on a sample boundary (1.0 s)
//  had no partial edit, which is why it alone read right three ways.
//
//  So subtitles never go through an edit: the samples are cut at the edit
//  boundaries and re-timed here, and written as a track whose edit is
//  plain. And a track that already has an edit is read through it.
//

import CoreMedia
import Foundation

/// Re-times subtitle samples through a track's edits.
enum SubtitleRetiming {

    /// One edit: where in the source it reads, and where it plays. A nil
    /// source is an empty edit — time that passes with nothing in it.
    struct Segment: Sendable, Equatable {
        let source: CMTimeRange?
        let target: CMTimeRange
    }

    /// `samples`, as they play after `segments`: each sample cut to every
    /// segment it falls in, moved and — for a scaled segment — stretched
    /// with it, then put on `timescale`. A sample, or a piece of one, that
    /// no segment reads is left out.
    ///
    /// - Parameters:
    ///   - samples: The samples in source time, in order.
    ///   - segments: The edits, in order.
    ///   - timescale: The timescale to express the result in.
    /// - Returns: The samples in target time, in order, none empty.
    static func retime(_ samples: [Remuxer.Sample], through segments: [Segment],
                       timescale: CMTimeScale) -> [Remuxer.Sample] {
        var result: [Remuxer.Sample] = []
        for segment in segments {
            guard let source = segment.source, source.duration > .zero else { continue }
            let ratio = segment.target.duration.seconds / source.duration.seconds
            let place = { (time: CMTime) -> CMTime in
                let offset = time - source.start
                let moved = ratio == 1 ? offset : CMTimeMultiplyByFloat64(offset, multiplier: ratio)
                return CMTimeConvertScale(segment.target.start + moved, timescale: timescale,
                                          method: .roundHalfAwayFromZero)
            }
            for sample in samples {
                let kept = sample.range.intersection(source)
                guard kept.duration > .zero else { continue }
                let range = CMTimeRange(start: place(kept.start), end: place(kept.end))
                guard range.duration > .zero else { continue }
                result.append(Remuxer.Sample(range: range, data: sample.data))
            }
        }
        return result
    }

    /// `samples` with a gap sample put in front when they start after zero,
    /// so the track covers from the start and needs no empty edit — which
    /// is the next thing a reader might misread.
    static func filledFromZero(_ samples: [Remuxer.Sample], gap: Data) -> [Remuxer.Sample] {
        guard let first = samples.first, first.range.start > .zero else { return samples }
        return [Remuxer.Sample(range: CMTimeRange(start: .zero, end: first.range.start), data: gap)] + samples
    }
}
