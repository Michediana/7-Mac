//
//  Display.swift
//  7-Mac
//
//  Number and duration formatting for the queue UI.
//

import Foundation

nonisolated enum Display {
    /// `1.2 MB`, in the units the Finder uses.
    static func bytes(_ count: UInt64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// `8.4 MB/s`.
    static func rate(_ bytesPerSecond: Double) -> String {
        let clamped = UInt64(max(0, bytesPerSecond.rounded()))
        return "\(bytes(clamped))/s"
    }

    /// A coarse "time left". Deliberately coarse: a remaining-time estimate
    /// that reads `1m 43s` claims a precision the measurement does not have.
    static func remaining(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<2:     String(localized: "a moment left")
        case ..<60:    String(localized: "\(Int(seconds.rounded())) seconds left")
        case ..<120:   String(localized: "about a minute left")
        case ..<3600:  String(localized: "about \(Int((seconds / 60).rounded())) minutes left")
        default:       String(localized: "about \(Int((seconds / 3600).rounded())) hours left")
        }
    }

    /// `3 files`, `1 folder`, and the honest `nothing` for an empty run.
    ///
    /// The nouns are looked up in the string catalog, so each language
    /// supplies its own pair: Italian's "file" does not change for plural.
    static func count(_ n: UInt64, _ singular: LocalizedStringResource,
                      _ plural: LocalizedStringResource) -> String {
        "\(n) \(String(localized: n == 1 ? singular : plural))"
    }
}
