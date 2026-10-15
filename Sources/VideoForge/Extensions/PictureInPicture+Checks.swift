//
//  PictureInPicture+Checks.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

public extension PictureInPicture {

    /// What is wrong with these settings, as a phrase — nil when nothing
    /// is. A caller can refuse bad settings before reading a file.
    var problem: String? { OverlayLayout.problem(with: self) }
}
