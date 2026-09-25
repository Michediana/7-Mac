//
//  SevenZip.swift
//  7-Mac
//
//  A Swift face for SevenZipKit.
//
//  This file is part of the app, not the framework, and that is deliberate:
//  SevenZipKit is LGPL because it carries the 7-Zip engine, while this wrapper
//  is ours and stays MIT. Calling an LGPL library across a dynamic link is
//  exactly the arrangement the licence is built for — see SevenZipKit/README.md.
//

import Foundation
import SevenZipKit

/// The embedded engine.
///
/// `nonisolated` throughout: the project defaults new types to `MainActor`,
/// and an archive facade has no business being pinned to it — the work happens
/// on a background queue and the callbacks arrive from there.
public nonisolated enum SevenZip {
    /// Upstream 7-Zip version, e.g. `26.03`.
    public static var engineVersion: String { SZKEngine.upstreamVersion }
    /// Upstream release date, e.g. `2026-09-03`.
    public static var engineDate: String { SZKEngine.upstreamDate }

    /// Every format the engine reads.
    public static var formats: [SZKFormat] { SZKEngine.formats }
    /// The seven it can also write. Read this instead of hardcoding a list.
    public static var writableFormats: [SZKFormat] { SZKEngine.writableFormats }

    public static func format(named name: String) -> SZKFormat? {
        SZKEngine.format(named: name)
    }

    /// Formats claiming `fileExtension`, given with or without a leading dot.
    public static func formats(forFileExtension fileExtension: String) -> [SZKFormat] {
        SZKEngine.formats(forFileExtension: fileExtension)
    }
}

// MARK: - Errors

nonisolated extension SZKError.Code: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled:        String(localized: "cancelled")
        case .passwordRequired: String(localized: "a password is required")
        case .passwordWrong:    String(localized: "the password is not correct")
        case .notAnArchive:     String(localized: "not an archive")
        case .unreadable:       String(localized: "could not be read or written")
        case .damaged:          String(localized: "damaged")
        case .unsupported:      String(localized: "unsupported")
        case .failed:           String(localized: "failed")
        @unknown default:       String(localized: "failed")
        }
    }
}

public nonisolated extension Error {
    /// The archive-specific reason, when this error came from the engine.
    var sevenZipCode: SZKError.Code? {
        let error = self as NSError
        guard error.domain == SZKErrorDomain else { return nil }
        return SZKError.Code(rawValue: error.code)
    }
}
