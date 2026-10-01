//
//  FinderHandoff.swift
//  7-Mac, 7-MacFinder
//
//  How the Finder menu tells the app what to do. Compiled into both targets.
//
//  The extension cannot simply open the files with the app: it is sandboxed
//  and has no access to them, and Launch Services refuses to hand on what the
//  sender cannot read. So it writes a note into the app group the two share —
//  what was chosen, on which paths — and opens `sevenmac://finder/<id>`. The
//  app reads the note and reaches the files through the folders it has been
//  granted, asking for one only the first time.
//

import Foundation

nonisolated enum FinderAction: String, Codable, Sendable {
    case extract
    case browse
    case test
    case compress
    case checksums
}

nonisolated struct FinderHandoff: Codable, Sendable {
    var id: UUID
    var action: FinderAction
    var paths: [String]
    var date: Date

    var urls: [URL] { paths.map { URL(filePath: $0) } }

    /// Long enough for a cold launch, short enough that an old note found
    /// lying around is not acted on.
    static let lifetime: TimeInterval = 60

    static let scheme = "sevenmac"
    private static let host = "finder"

    /// `<team>.com.michediana.Seven-Mac`, written into both Info.plists at
    /// build time so it always matches the entitlement.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "SevenMacAppGroup") as? String
    }

    /// One file per request, so two quick clicks cannot overwrite each other.
    static var directory: URL? {
        guard let groupID,
              let container = FileManager.default
                  .containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        return container.appending(components: "Library", "Finder Requests", directoryHint: .isDirectory)
    }

    init(action: FinderAction, urls: [URL], now: Date = .now) {
        id = UUID()
        self.action = action
        paths = urls.map { $0.standardizedFileURL.path(percentEncoded: false) }
        date = now
    }

    var url: URL { URL(string: "\(Self.scheme)://\(Self.host)/\(id.uuidString)")! }

    /// Writes the note and returns the URL that names it.
    static func post(_ action: FinderAction, for urls: [URL], now: Date = .now) throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handoff = FinderHandoff(action: action, urls: urls, now: now)
        try JSONEncoder().encode(handoff)
            .write(to: directory.appending(component: "\(handoff.id.uuidString).json"), options: .atomic)
        return handoff.url
    }

    /// The note a `sevenmac://finder/<id>` URL names, consumed. `nil` for any
    /// other URL, an unknown id, or a note past its lifetime.
    static func take(_ url: URL, now: Date = .now) -> FinderHandoff? {
        guard url.scheme == scheme, url.host() == host,
              let id = UUID(uuidString: url.lastPathComponent),
              let directory
        else { return nil }
        let file = directory.appending(component: "\(id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file),
              let handoff = try? JSONDecoder().decode(FinderHandoff.self, from: data),
              handoff.id == id, now.timeIntervalSince(handoff.date) <= lifetime
        else { return nil }
        return handoff
    }
}

/// When the Finder last had the menu extension running.
///
/// The switch in System Settings says whether the menu is allowed, not
/// whether the Finder actually loaded it: an extension that failed to start
/// stays switched on and absent. So the extension notes the time whenever it
/// starts or builds a menu, and the app compares that with when the Finder
/// itself last started.
nonisolated enum FinderMenuHeartbeat {
    private static var file: URL? {
        FinderHandoff.directory?.deletingLastPathComponent().appending(component: "Finder Menu Heartbeat")
    }

    /// `always` on start: a Finder relaunched within the minute must still
    /// find a beat newer than itself.
    static func beat(always: Bool = false, now: Date = .now) {
        guard let file else { return }
        // A right-click should not mean a disk write every time.
        if !always, let last = lastBeat, now.timeIntervalSince(last) < 60 { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: file)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    static var lastBeat: Date? {
        guard let file else { return nil }
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
