//
//  ExportSpec+Codec.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  What an export spec comes to for a particular source: the concrete
//  codec, and the container that can hold it. The decisions live in
//  ``CodecPlan``; these are the doors a caller uses, so a CLI names its
//  output file with the same container the library will write.
//

import Foundation

public extension ExportSpec {

    /// The codec this writes for a source: ``VideoCodec/source`` resolved
    /// to the source's own, and the depth rule applied.
    ///
    /// - Parameter source: The clip being written.
    /// - Returns: A concrete codec — never ``VideoCodec/source``.
    /// - Throws: ``VideoForgeError/wouldTruncateDepth(codec:)`` when a
    ///   10-bit source is asked to be written by an 8-bit codec, and
    ///   ``VideoForgeError/codecTakesNoRate(codec:)`` for a bitrate or a
    ///   quality with ProRes.
    func codec(for source: VideoInfo) throws -> VideoCodec {
        try codec(forClips: [source])
    }

    /// The codec this writes for clips joined end to end: the first clip's
    /// own for ``VideoCodec/source``, and deep if any of them is deep.
    ///
    /// - Parameter sources: The clips, in order.
    /// - Returns: A concrete codec.
    /// - Throws: ``VideoForgeError/wouldTruncateDepth(codec:)``,
    ///   ``VideoForgeError/codecTakesNoRate(codec:)``.
    func codec(forClips sources: [VideoInfo]) throws -> VideoCodec {
        let deep = sources.contains(where: \.isDeep)
        // Alpha is kept only when every clip has it: a join of one clip with
        // alpha and one without has nothing to say for the second.
        let alpha = !sources.isEmpty && sources.allSatisfy(\.hasAlpha)
        let resolved = CodecPlan.resolve(codec, sourceCodec: sources.first?.video?.codec,
                                         deep: deep, alpha: alpha)
        try CodecPlan.checkDepth(resolved, deep: sources.contains(where: \.forbidsEightBit))
        try CodecPlan.checkRates(self, codec: resolved)
        return resolved
    }

    /// The container this writes for a source.
    ///
    /// ``container`` when it is set, then the destination's extension, then
    /// the source's — except that ProRes goes only into `.mov`: inherited
    /// from an `.mp4` source it becomes `.mov`, asked for by name it is
    /// refused.
    ///
    /// - Parameters:
    ///   - source: The clip being written.
    ///   - destination: Where it goes, when the caller has already named it.
    /// - Returns: The container.
    /// - Throws: ``VideoForgeError/codecNeedsContainer(codec:container:)``,
    ///   or the depth refusal from ``codec(for:)``.
    func container(for source: VideoInfo, destination: URL? = nil) throws -> VideoContainer {
        try CodecPlan.container(explicit: container, destination: destination,
                                inherited: source.container, codec: codec(for: source))
    }
}
