//
//  EditProblems.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Problems found checking an edit, each named by its place
/// (`clips[2].to: …`). Internal: callers get them from
/// ``VideoForge/problems(in:)``, or as one ``VideoForgeError/invalidOptions(_:)``.
enum EditProblems: Error {
    /// Every problem found, one a line.
    case found([String])
}
