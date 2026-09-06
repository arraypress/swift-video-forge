//
//  VideoProcessOptions.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One video job.
///
/// ```swift
/// let options = VideoProcessOptions(
///     operations: [.trim(.between(5, 15)), .resize(.height(1080))],
///     export: .container(.mp4)
/// )
/// ```
public struct VideoProcessOptions: Sendable, Codable, Equatable, Hashable {
    /// What to do, in order.
    public var operations: [VideoOperation]
    /// How to write the result.
    public var export: ExportSpec
    /// Whether an existing file at the destination may be replaced.
    public var overwrites: Bool

    /// - Parameters:
    ///   - operations: What to do, in order.
    ///   - export: How to write the result.
    ///   - overwrites: Whether an existing destination may be replaced.
    public init(operations: [VideoOperation] = [],
                export: ExportSpec = ExportSpec(),
                overwrites: Bool = false) {
        self.operations = operations
        self.export = export
        self.overwrites = overwrites
    }

    /// Whether every operation can be done by rearranging time alone, so
    /// the frames never have to be decoded.
    public var isTimeOnly: Bool { operations.allSatisfy(\.isTimeOnly) }

    /// Keep a stretch and write it out.
    public static func trim(_ spec: TrimSpec) -> VideoProcessOptions {
        VideoProcessOptions(operations: [.trim(spec)])
    }

    /// Scale to a height and write it out.
    public static func resize(height: Int) -> VideoProcessOptions {
        VideoProcessOptions(operations: [.resize(.height(height))])
    }
}
