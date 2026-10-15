//
//  WriterFeed+Copying.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  The commonest feed: every sample a reader output gives, as it gives it.
//

import AVFoundation
import Foundation

public extension WriterFeed {

    /// A feed that copies a reader output's samples into an input.
    ///
    /// A refused append is not lost: the writer fails, and the pump reports
    /// the writer's own reason.
    ///
    /// - Parameters:
    ///   - output: The reader output.
    ///   - input: The writer input.
    /// - Returns: The feed.
    static func copying(from output: AVAssetReaderOutput, to input: AVAssetWriterInput) -> WriterFeed {
        WriterFeed(input: input) {
            guard let sample = output.copyNextSampleBuffer() else { return false }
            input.append(sample)
            return true
        }
    }
}
