//
//  AppModel.swift
//  7-Mac
//
//  What the windows talk to: settings, the queue, and the two questions a
//  job can ask a person.
//

import AppKit
import Foundation
import Observation
import SevenZipKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel: JobInteraction {
    /// One instance, because there is one queue.
    ///
    /// The app delegate needs it before any window exists — a `.7z`
    /// double-clicked from the Finder arrives at `application(_:open:)`
    /// during launch — so passing it down from the scene is not an option.
    static let shared = AppModel()

    let preferences = Preferences()
    let queue: JobQueue

    /// Non-nil while a password sheet is up.
    var passwordPrompt: PasswordPrompt?
    /// Non-nil while the compress sheet is up.
    var compressionDraft: CompressionDraft?

    /// A window to open once there is a way to open one.
    enum WindowRequest {
        case main
        case browser(BrowserTarget)
        case checksums(ChecksumTarget)
    }

    /// SwiftUI only hands out `openWindow` inside a scene, and archives
    /// arrive from the Finder before any window exists — so the menu bar
    /// installs it, and anything that came in earlier waits here.
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var pendingWindows: [WindowRequest] = []
    /// Whether anything has asked for a window since launch. If a Finder
    /// "Open With" only asked for a browser, the main window stays shut.
    @ObservationIgnored private(set) var hasRequestedWindow = false
    /// Non-nil while a test report sheet is up in the main window.
    var shownTestReport: TestReport?

    init() {
        queue = JobQueue(preferences: preferences)
        queue.interaction = self
    }

    // MARK: - Taking work in

    /// Decides what a set of dropped or opened items means.
    ///
    /// Everything recognisable as an archive extracts; anything else — a
    /// folder, a document, a mixed selection — goes to the compress sheet.
    func accept(_ urls: [URL]) {
        let urls = urls.filter { $0.isFileURL }
        guard !urls.isEmpty else { return }

        if urls.allSatisfy(ArchiveNaming.looksLikeArchive) {
            extract(urls)
        } else {
            beginCompression(of: urls)
        }
    }

    /// Files opened from the Finder: the Dock icon, a double-click, "Open
    /// With". Unlike a drop, what this means is a preference.
    func open(_ urls: [URL]) {
        let urls = urls.filter { $0.isFileURL }
        if preferences.openAction == .browse,
           !urls.isEmpty, urls.allSatisfy({ !ArchiveNaming.isDirectory($0) }) {
            browse(urls)
        } else {
            // The queue and the compress sheet live in the main window.
            show(.main)
            accept(urls)
        }
    }

    func browse(_ urls: [URL]) {
        for url in urls { show(.browser(BrowserTarget(url: url))) }
    }

    // MARK: - Windows

    func show(_ request: WindowRequest) {
        hasRequestedWindow = true
        pendingWindows.append(request)
        drainPendingWindows()
    }

    /// Called from the menu bar, which exists from launch on.
    func install(_ action: OpenWindowAction) {
        guard openWindow == nil else { return }
        openWindow = action
        // Not from inside the scene update that handed the action over.
        Task { @MainActor in self.drainPendingWindows() }
    }

    private func drainPendingWindows() {
        guard let openWindow else { return }
        let requests = pendingWindows
        pendingWindows = []
        for request in requests {
            switch request {
            case .main: openWindow(id: WindowID.main)
            case .browser(let target): openWindow(id: WindowID.browser, value: target)
            case .checksums(let target): openWindow(id: WindowID.checksums, value: target)
            }
        }
    }

    func extract(_ urls: [URL]) {
        queue.enqueue(urls.map { .extract(archive: $0) })
    }

    func beginCompression(of urls: [URL]) {
        guard !urls.isEmpty else { return }
        show(.main)
        compressionDraft = CompressionDraft(sources: urls, preferences: preferences)
    }

    func startCompression(_ draft: CompressionDraft) {
        preferences.profileID = draft.profileID
        preferences.defaultFormat = draft.formatName
        queue.enqueue([.compress(draft.request)])
        compressionDraft = nil
    }

    // MARK: - Panels

    func chooseArchivesToExtract() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose archives to extract.")
        panel.prompt = String(localized: "Extract")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // Explicit choice, so no extension filter: if the engine can open it,
        // it gets extracted.
        extract(panel.urls)
    }

    func chooseArchivesToBrowse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose archives to look inside.")
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        browse(panel.urls)
    }

    func chooseArchivesToTest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose archives to test. Nothing is written: every entry is decoded and checked.")
        panel.prompt = String(localized: "Test")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        test(panel.urls)
    }

    func test(_ urls: [URL]) {
        queue.enqueue(urls.map { .test(archive: $0) })
    }

    func chooseItemsForChecksums() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose files or folders to checksum.")
        panel.prompt = String(localized: "Checksum")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        show(.checksums(ChecksumTarget(urls: panel.urls)))
    }

    func chooseItemsToCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose files and folders to compress.")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        beginCompression(of: panel.urls)
    }

    // MARK: - JobInteraction

    func askPassword(for archive: URL, incorrect: Bool) async -> PasswordAnswer? {
        await withCheckedContinuation { continuation in
            passwordPrompt = PasswordPrompt(archiveName: archive.lastPathComponent,
                                            incorrect: incorrect,
                                            offersKeychain: preferences.offersKeychain) { [weak self] answer in
                self?.passwordPrompt = nil
                continuation.resume(returning: answer)
            }
        }
    }

    func askWritableFolder(message: String, suggesting: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = String(localized: "Use This Folder")
        if let suggesting { panel.directoryURL = suggesting }

        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        FolderAccess.shared.grant(chosen)
        return chosen
    }
}

/// A sheet's worth of state, with exactly one way out.
@MainActor @Observable
final class PasswordPrompt: Identifiable {
    let id = UUID()
    let archiveName: String
    let incorrect: Bool
    let offersKeychain: Bool

    var password = ""
    var remember = false

    private var finish: ((PasswordAnswer?) -> Void)?

    init(archiveName: String, incorrect: Bool, offersKeychain: Bool,
         finish: @escaping (PasswordAnswer?) -> Void) {
        self.archiveName = archiveName
        self.incorrect = incorrect
        self.offersKeychain = offersKeychain
        self.finish = finish
    }

    /// Resumes the waiting job. Idempotent, because a sheet can be dismissed
    /// in more ways than it has buttons and resuming twice is a crash.
    func submit() {
        let answer = PasswordAnswer(password: password, remember: remember && offersKeychain)
        complete(password.isEmpty ? nil : answer)
    }

    func cancel() { complete(nil) }

    private func complete(_ answer: PasswordAnswer?) {
        guard let finish else { return }
        self.finish = nil
        finish(answer)
    }
}

/// What the compress sheet edits.
@MainActor @Observable
final class CompressionDraft: Identifiable {
    let id = UUID()
    let sources: [URL]

    var formatName: String {
        didSet { profile.format = formatName }
    }
    /// The profile the settings came from, and the settings themselves —
    /// which the Advanced section may have moved away from it.
    private(set) var profileID: UUID
    var profile: CompressionProfile
    var output: URL
    var password = ""
    var encryptsHeader = false
    /// Bytes per volume; 0 for one file.
    var volumeSize: UInt64 = 0

    let preferences: Preferences

    init(sources: [URL], preferences: Preferences) {
        self.sources = sources
        self.preferences = preferences
        var profile = preferences.profile(withID: preferences.profileID)
        profileID = profile.id

        let folder = ArchiveNaming.commonParent(of: sources)
            ?? URL.downloadsDirectory
        let name = ArchiveNaming.suggestedArchiveName(for: sources)
        let candidates = Self.formats(for: sources)
        let chosen = candidates.contains(preferences.defaultFormat)
            ? preferences.defaultFormat
            : (candidates.first ?? "7z")
        formatName = chosen
        profile.format = chosen
        self.profile = profile
        output = ArchiveNaming.unique(
            folder.appending(component: "\(name).\(Self.fileExtension(for: chosen))"))
    }

    // MARK: Profiles

    /// Starts over from `id`'s settings. A saved profile carries its own
    /// format, which then becomes the draft's — when this selection can
    /// take it.
    func choose(_ id: UUID) {
        let chosen = preferences.profile(withID: id)
        profileID = chosen.id
        let format = chosen.isBuiltIn ? formatName : chosen.format
        profile = chosen
        if availableFormats.contains(format), format != formatName {
            formatName = format
            formatChanged()
        }
        profile.format = formatName
    }

    /// Whether the settings still match the profile they started from.
    var isModified: Bool {
        var base = preferences.profile(withID: profileID)
        base.format = formatName
        return base != profile
    }

    func saveProfile(named name: String) {
        let saved = preferences.save(profile, as: name)
        profileID = saved.id
        profile = saved
    }

    var memory: MemoryEstimate? { MemoryEstimate(profile) }

    /// Methods this format can use; empty when it has only one.
    var availableMethods: [CompressionMethod] { CompressionMethod.offered(for: formatName) }

    /// The writable formats that make sense for this selection.
    ///
    /// `gzip`, `bzip2` and `xz` hold exactly one file — the engine answers
    /// `SZKErrorUnsupported` for a folder — so they are only offered when the
    /// selection is a single file.
    static func formats(for sources: [URL]) -> [String] {
        let singleFile = sources.count == 1 && !ArchiveNaming.isDirectory(sources[0])
        let singleMemberOnly: Set<String> = ["gzip", "bzip2", "xz"]
        let order = ["7z", "zip", "tar", "gzip", "bzip2", "xz", "wim"]
        return SevenZip.writableFormats
            .map(\.name)
            .filter { singleFile || !singleMemberOnly.contains($0) }
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    var availableFormats: [String] { Self.formats(for: sources) }

    /// Only 7z and zip take a password; only 7z can also hide the entry list.
    var supportsPassword: Bool { formatName == "7z" || formatName == "zip" }
    var supportsHeaderEncryption: Bool { formatName == "7z" }

    static func fileExtension(for formatName: String) -> String {
        switch formatName {
        case "gzip":  "gz"
        case "bzip2": "bz2"
        default:      formatName
        }
    }

    /// Keeps the output name in step with the chosen format.
    func formatChanged() {
        let stem = ArchiveNaming.stem(of: output)
        output = ArchiveNaming.unique(
            output.deletingLastPathComponent()
                .appending(component: "\(stem).\(Self.fileExtension(for: formatName))"))
        if !supportsPassword { password = "" }
        if !supportsHeaderEncryption { encryptsHeader = false }
        // A method one format has and the next does not falls back to the
        // new format's default, as does its dictionary.
        if let method = profile.method, !availableMethods.contains(method) {
            profile.method = nil
            profile.dictionary = nil
        }
        if formatName != "7z" { profile.solid = .automatic }
    }

    func chooseOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.message = String(localized: "Where should the archive go?")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // A save panel is also a grant: remember it so the job does not have
        // to ask again for the same folder.
        FolderAccess.shared.grant(chosen.deletingLastPathComponent())
        output = chosen
    }

    /// Whether the job will have to stop and ask before it can write here.
    /// Saying so in the sheet is better than a panel appearing later.
    var needsPermission: Bool {
        !FolderAccess.shared.prepare(output.deletingLastPathComponent())
    }

    var request: CompressionRequest {
        CompressionRequest(sources: sources,
                           output: output,
                           formatName: formatName,
                           profile: profile,
                           password: password.isEmpty ? nil : password,
                           encryptsHeader: encryptsHeader && supportsHeaderEncryption,
                           volumeSize: volumeSize,
                           excludedNames: preferences.creationExclusions,
                           storesSymbolicLinks: preferences.storesSymbolicLinks,
                           storesHardLinks: preferences.storesHardLinks)
    }
}
