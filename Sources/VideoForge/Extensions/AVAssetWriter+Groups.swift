//
//  AVAssetWriter+Groups.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  Alternate tracks — subtitles in several languages, several audio
//  tracks — go in a group, or players will not offer them: a subtitle
//  track outside an alternate group never appears in the legible
//  media-selection group.
//

import AVFoundation
import Foundation

extension AVAssetWriter {

    /// Puts inputs in one alternate group, when the writer takes it.
    ///
    /// - Parameters:
    ///   - inputs: The alternates. Nothing happens for none.
    ///   - defaultInput: The one a player picks first, or nil for none.
    func addAlternateGroup(_ inputs: [AVAssetWriterInput], defaultInput: AVAssetWriterInput?) {
        guard !inputs.isEmpty else { return }
        let group = AVAssetWriterInputGroup(inputs: inputs, defaultInput: defaultInput)
        if canAdd(group) { add(group) }
    }
}
