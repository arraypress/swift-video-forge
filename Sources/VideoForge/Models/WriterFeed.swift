//
//  WriterFeed.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  One writer input and the step that feeds it, and the whole job a
//  ``WriterPump`` runs: the reader, the writer and every feed.
//

import AVFoundation
import Foundation

/// One writer input and the step that feeds it its next sample.
///
/// The step appends at most one sample and returns true, or returns false
/// when its source has run dry. It throws to stop the whole job; the error
/// comes out of ``WriterPump/run(_:from:until:)`` as thrown.
public struct WriterFeed {
    /// The input this feed fills.
    public let input: AVAssetWriterInput
    /// Appends the next sample; false at the end.
    let step: () throws -> Bool

    /// - Parameters:
    ///   - input: The input to fill.
    ///   - step: Appends the next sample and returns true, or returns false
    ///     at the end of the source.
    public init(input: AVAssetWriterInput, step: @escaping () throws -> Bool) {
        self.input = input
        self.step = step
    }
}

/// A reader, a writer and the feeds between them.
public struct WriterJob {
    /// The reader the feeds draw from, started by the pump; nil when the
    /// feeds make their own samples.
    public var reader: AVAssetReader?
    /// The writer, with every feed's input already added.
    public var writer: AVAssetWriter
    /// One feed per writer input.
    public var feeds: [WriterFeed]

    /// - Parameters:
    ///   - reader: The reader to start, if any.
    ///   - writer: The writer, inputs added.
    ///   - feeds: One feed per input.
    public init(reader: AVAssetReader?, writer: AVAssetWriter, feeds: [WriterFeed]) {
        self.reader = reader
        self.writer = writer
        self.feeds = feeds
    }
}
