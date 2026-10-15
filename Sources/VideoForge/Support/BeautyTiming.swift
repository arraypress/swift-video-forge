//
//  BeautyTiming.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import FaceBeauty
import Foundation

/// Moving a face's landmark track from the clip's timeline to the job's.
enum BeautyTiming {

    /// `keyframes`, tracked on the source, as they fall after the job's
    /// time steps: a trim moves them back by its start and drops those
    /// outside it; a speed change divides them. Every time step is done
    /// before any redraw, so all of them apply.
    static func retimed(_ keyframes: [FaceLandmarkFrame], through operations: [VideoOperation],
                        sourceDuration: Double) -> [FaceLandmarkFrame] {
        var frames = keyframes
        for operation in operations {
            switch operation {
            case .trim(let spec):
                let start = min(spec.start, sourceDuration)
                let end = spec.duration.map { start + $0 } ?? .infinity
                frames = frames.filter { $0.time >= start - 0.5 && $0.time <= end + 0.5 }
                    .map { var frame = $0; frame.time -= start; return frame }
            case .speed(let rate) where rate > 0:
                frames = frames.map { var frame = $0; frame.time /= rate; return frame }
            default:
                break
            }
        }
        return frames
    }
}
