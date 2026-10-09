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

    /// Something `count` can count.
    enum Noun { case file, folder, item, match, problem, thread }

    /// `3 files`, `1 folder`.
    ///
    /// Each phrase is a plural variation in the string catalog, so every
    /// language supplies its own forms: Polish has three ("2 pliki",
    /// "5 plików"), and a plain singular/plural pair cannot express them.
    static func count(_ n: UInt64, _ noun: Noun) -> String {
        let n = Int(clamping: n)
        return switch noun {
        case .file:    String(localized: "\(n) files")
        case .folder:  String(localized: "\(n) folders")
        case .item:    String(localized: "\(n) items")
        case .match:   String(localized: "\(n) matches")
        case .problem: String(localized: "\(n) problems")
        case .thread:  String(localized: "\(n) threads")
        }
    }
}
