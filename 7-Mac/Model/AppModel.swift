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

    func extract(_ urls: [URL]) {
        queue.enqueue(urls.map { .extract(archive: $0) })
    }

    func beginCompression(of urls: [URL]) {
        guard !urls.isEmpty else { return }
        compressionDraft = CompressionDraft(sources: urls, preferences: preferences)
    }

    func startCompression(_ draft: CompressionDraft) {
        preferences.preset = draft.preset
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
        panel.message = "Choose archives to extract."
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // Explicit choice, so no extension filter: if the engine can open it,
        // it gets extracted.
        extract(panel.urls)
    }

    func chooseItemsToCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files and folders to compress."
        panel.prompt = "Choose"
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
        panel.prompt = "Use This Folder"
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

    var formatName: String
    var preset: CompressionPreset
    var output: URL
    var password = ""
    var encryptsHeader = false

    init(sources: [URL], preferences: Preferences) {
        self.sources = sources
        self.preset = preferences.preset

        let folder = ArchiveNaming.commonParent(of: sources)
            ?? URL.downloadsDirectory
        let name = ArchiveNaming.suggestedArchiveName(for: sources)
        let candidates = Self.formats(for: sources)
        let chosen = candidates.contains(preferences.defaultFormat)
            ? preferences.defaultFormat
            : (candidates.first ?? "7z")
        formatName = chosen
        output = ArchiveNaming.unique(
            folder.appending(component: "\(name).\(Self.fileExtension(for: chosen))"))
    }

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
    }

    func chooseOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.message = "Where should the archive go?"
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
                           preset: preset,
                           password: password.isEmpty ? nil : password,
                           encryptsHeader: encryptsHeader && supportsHeaderEncryption)
    }
}
