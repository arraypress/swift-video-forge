//
//  PictureCorner.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Where a picture-in-picture sits.
public enum PictureCorner: String, CaseIterable, Sendable, Codable, Hashable {
    case topLeft = "tl"
    case topRight = "tr"
    case bottomLeft = "bl"
    case bottomRight = "br"
    /// The corner that keeps clear of the faces in the frame underneath,
    /// found by looking — see ``OverlayLayout/choose(among:faces:)``.
    case auto

    /// The four real corners, in the order a tie is settled: bottom right
    /// first, where a picture-in-picture conventionally goes.
    public static let corners: [PictureCorner] = [.bottomRight, .bottomLeft, .topRight, .topLeft]

    /// The corner a name gives — `tr`, `top-right`, `topright` — or nil.
    public static func named(_ name: String) -> PictureCorner? {
        let plain = name.lowercased().filter { $0.isLetter }
        switch plain {
        case "tl", "topleft": return .topLeft
        case "tr", "topright": return .topRight
        case "bl", "bottomleft": return .bottomLeft
        case "br", "bottomright": return .bottomRight
        case "auto": return .auto
        default: return nil
        }
    }
}
