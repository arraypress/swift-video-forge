//
//  SubtitleLanguage.swift
//  VideoForge
//
//  Created by David Sherlock on 2026.
//
//  A track declares its language twice: a three-letter ISO 639-2 code, which
//  every player reads, and a BCP 47 tag, which carries the region or script
//  the three letters cannot — `pt-BR`, `zh-Hant`. Both are written.
//

import Foundation

/// Language tags for a subtitle track.
enum SubtitleLanguage {

    /// The codes to write for a language the caller named — `en`, `eng`,
    /// `pt-BR`, `zh-Hant` — or nil when it names no language.
    ///
    /// - Returns: The ISO 639-2 code, and the BCP 47 tag when the name
    ///   carries more than the language alone.
    static func codes(for name: String) -> (iso639: String, bcp47: String?)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        // Components, not `Locale.Language`: that one fills in the likely
        // script and region, so a bare `en` would "have" both.
        let parts = Locale.Language.Components(identifier: trimmed)
        guard let code = parts.languageCode, code.isISOLanguage,
              let alpha3 = code.identifier(.alpha3) else { return nil }
        let tag = [code.identifier(.alpha2) ?? code.identifier, parts.script?.identifier, parts.region?.identifier]
            .compactMap { $0 }
        return (alpha3, tag.count > 1 ? tag.joined(separator: "-") : nil)
    }

    /// The language a track declares, the way a caller would write it —
    /// its BCP 47 tag as stored (`pt-BR`), else the two-letter code for its
    /// three (`ja` for `jpn`) — or nil for none or `und`.
    static func readable(code: String?, tag: String?) -> String? {
        if let tag, !tag.isEmpty, tag != "und" { return tag }
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    /// A language tag read off a subtitle file's name — `film.ja.srt`,
    /// `film.pt-BR.vtt` — or nil when the name carries none.
    static func fromFileName(_ url: URL) -> String? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        guard parts.count >= 2, let last = parts.last else { return nil }
        let tag = String(last)
        return codes(for: tag) == nil ? nil : tag
    }
}
