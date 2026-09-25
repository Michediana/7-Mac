//
//  ArchiveBrowser.swift
//  7-Mac
//
//  One browser window's worth of state: the archive, the archives opened out
//  of it, and everything the window can do with an entry short of writing it
//  somewhere permanent — that is the queue's job.
//
//  Nested archives are the reason this is a stack and not a single archive.
//  `sample.tar.gz` is a gzip stream holding one tar; what a person wants to
//  see is the tar's contents, so the browser opens both and shows the inner
//  one, with the outer still there to go back to.
//

import AppKit
import Foundation
import Observation
import SevenZipKit

/// Something slow the browser is doing, with a way to stop it.
@MainActor @Observable
final class BrowserActivity {
    let title: String
    fileprivate(set) var completedBytes: UInt64 = 0
    fileprivate(set) var totalBytes: UInt64 = 0
    fileprivate var onCancel: (() -> Void)?

    init(title: String) { self.title = title }

    var fractionCompleted: Double? {
        totalBytes == 0 ? nil : min(1, Double(completedBytes) / Double(totalBytes))
    }

    func cancel() { onCancel?() }
}

@MainActor @Observable
final class ArchiveBrowser {
    /// One archive in the stack.
    struct Level: Identifiable {
        let id = UUID()
        let archive: Archive
        fileprivate(set) var tree: ArchiveTree
        /// The file name, or the entry name for a nested archive.
        let title: String
        /// The one that worked, once one has. Kept for this window only.
        fileprivate(set) var password: String?
        /// Whether reading this level needs its parent's queue to be free:
        /// true for an archive opened in place, false for one unpacked to a
        /// file of its own.
        let isInPlace: Bool
    }

    enum Phase: Equatable {
        case opening
        case ready
        case failed(String)
    }

    /// The archive the window was opened on.
    let url: URL
    private(set) var levels: [Level] = []
    private(set) var phase: Phase = .opening

    var selection: Set<ArchiveNode.ID> = []
    var sortOrder: [KeyPathComparator<ArchiveNode>] = [
        KeyPathComparator(\ArchiveNode.name, comparator: .localizedStandard),
    ] {
        didSet { resort() }
    }
    var searchText = "" {
        didSet { refreshMatches() }
    }
    var filter: EntryFilter = .everything {
        didSet { refreshMatches() }
    }

    /// Search results or a filtered list: flat, because a match is only
    /// useful where you can see it.
    private(set) var matches: [ArchiveNode] = []
    var isShowingMatches: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter != .everything
    }

    /// Bound to `.quickLookPreview`.
    var previewURL: URL?
    var passwordPrompt: PasswordPrompt?
    /// A problem worth an alert that does not end the window.
    var problem: String?
    private(set) var activity: BrowserActivity?

    private let preferences: Preferences
    private let queue: JobQueue
    /// Previews and unpacked archives go here, and all of it goes when the
    /// window does.
    let scratch: URL
    /// Level id + node id → extracted copy, so a second look is instant.
    private var extracted: [String: URL] = [:]

    init(url: URL, preferences: Preferences, queue: JobQueue) {
        self.url = url
        self.preferences = preferences
        self.queue = queue
        scratch = Self.scratchRoot.appending(component: UUID().uuidString, directoryHint: .isDirectory)
    }

    var current: Level? { levels.last }
    var roots: [ArchiveNode] { current?.tree.roots ?? [] }

    // MARK: - Opening

    /// Opens the archive, asking for a password if its entry list is
    /// encrypted, and goes straight through a compressor to the archive
    /// inside it.
    func open() async {
        phase = .opening
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var password = preferences.offersKeychain ? PasswordStore.password(for: url) : nil
        var incorrect = password != nil
        var remember = false
        while true {
            do {
                let archive = try await Archive.open(url, password: provider(password))
                if remember, let password { PasswordStore.save(password, for: url) }
                let level = await makeLevel(archive, title: url.lastPathComponent,
                                            password: archive.hasEncryptedHeader ? password : nil,
                                            isInPlace: false)
                levels = [level]
                phase = .ready
                break
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: url.lastPathComponent, incorrect: incorrect,
                                                     offersKeychain: preferences.offersKeychain)
                else {
                    phase = .failed("This archive is encrypted.")
                    return
                }
                password = answer.password
                remember = answer.remember
                incorrect = true
            } catch {
                phase = .failed(error.archiveDescription)
                return
            }
        }

        if let wrapped = Self.wrappedArchive(in: levels[0].archive),
           let node = levels[0].tree.allNodes.first(where: { $0.record?.index == wrapped }) {
            await descend(into: node)
        }
    }

    /// For a compressor holding a single archive — the tar in a `.tar.gz` —
    /// the index of that archive. Nothing else is worth skipping past: a zip
    /// that happens to contain one zip is still a zip you may want to see.
    nonisolated static func wrappedArchive(in archive: Archive) -> Int? {
        guard compressorFormats.contains(archive.formatName),
              archive.entries.count == 1,
              let only = archive.entries.first,
              !only.isDirectory,
              ArchiveNaming.droppedArchiveExtensions.contains(
                  (only.path as NSString).pathExtension.lowercased())
        else { return nil }
        return Int(only.index)
    }

    /// Formats that wrap one stream, as the engine names them.
    nonisolated static let compressorFormats: Set<String> = [
        "gzip", "bzip2", "xz", "zstd", "lzma", "lzma86", "Z",
    ]

    private func makeLevel(_ archive: Archive, title: String, password: String?,
                           isInPlace: Bool) async -> Level {
        var tree = await Task.detached(priority: .userInitiated) {
            ArchiveTree(entries: archive.entries)
        }.value
        tree.sort(using: sortOrder)
        return Level(archive: archive, tree: tree, title: title, password: password,
                     isInPlace: isInPlace)
    }

    // MARK: - Nested archives

    /// Whether double-clicking `node` should open it as an archive rather
    /// than preview it. The same narrow list a drop uses — `.exe` opens in
    /// the engine, but a person double-clicking one wants to look at it.
    func looksLikeArchive(_ node: ArchiveNode) -> Bool {
        !node.isDirectory && ArchiveNaming.droppedArchiveExtensions.contains(
            (node.name as NSString).pathExtension.lowercased())
    }

    /// Opens `node` as an archive and pushes it onto the stack.
    ///
    /// In place when the container allows it — a tar inside a tar costs
    /// nothing. Otherwise the entry is unpacked to the window's scratch
    /// folder first, which is what 7-Zip's own file manager does too: a
    /// compressed stream cannot be read from the middle.
    func descend(into node: ArchiveNode) async {
        guard let level = current, let index = node.record?.index, !node.isDirectory,
              activity == nil
        else { return }

        // In place first. The parent's password is not a guess worth making:
        // an inner archive has its own, if it has one at all.
        var password: String?
        var incorrect = false
        inPlace: while true {
            do {
                let nested = try await level.archive.openEntry(index, password: provider(password))
                push(await makeLevel(nested, title: node.name, password: password, isInPlace: true))
                return
            } catch where error.sevenZipCode == .unsupported {
                // The ordinary case for anything compressed. Unpack it.
                break inPlace
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: node.name, incorrect: incorrect) else { return }
                password = answer.password
                incorrect = true
            } catch {
                problem = "“\(node.name)” could not be opened: \(error.archiveDescription.lowercased())."
                return
            }
        }

        guard let file = await extractForViewing(node, in: level) else { return }
        password = nil
        incorrect = false
        while true {
            do {
                let nested = try await Archive.open(file, password: provider(password))
                push(await makeLevel(nested, title: node.name,
                                     password: nested.hasEncryptedHeader ? password : nil,
                                     isInPlace: false))
                return
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: node.name, incorrect: incorrect) else { return }
                password = answer.password
                incorrect = true
            } catch {
                problem = "“\(node.name)” is not an archive 7-Mac can open."
                return
            }
        }
    }

    private func push(_ level: Level) {
        levels.append(level)
        selection = []
        refreshMatches()
    }

    /// Pops back to `level`.
    func goBack(to level: Level.ID) {
        guard let position = levels.firstIndex(where: { $0.id == level }),
              position < levels.count - 1
        else { return }
        levels.removeSubrange((position + 1)...)
        selection = []
        refreshMatches()
    }

    func goUp() {
        guard levels.count > 1 else { return }
        goBack(to: levels[levels.count - 2].id)
    }

    // MARK: - Preview

    /// Unpacks one file to the scratch folder and hands it to Quick Look.
    func preview(_ node: ArchiveNode) async {
        guard !node.isDirectory, let level = current else { return }
        guard let file = await extractForViewing(node, in: level) else { return }
        previewURL = file
    }

    /// The selected file, for the space bar.
    var previewableSelection: ArchiveNode? {
        guard selection.count == 1, let id = selection.first,
              let node = current?.tree.node(id), !node.isDirectory
        else { return nil }
        return node
    }

    /// Unpacks `node` into the scratch folder, asking for a password when
    /// the entry needs one, and returns the file. `nil` means it did not
    /// happen, and when that was not the person's own choice, `problem` says
    /// why.
    private func extractForViewing(_ node: ArchiveNode, in level: Level) async -> URL? {
        guard let index = node.record?.index else { return nil }
        let key = "\(level.id)/\(node.id)"
        if let cached = extracted[key],
           FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)) {
            return cached
        }

        var password = level.password
        var incorrect = false
        if node.isEncrypted, password == nil {
            guard let answer = await askPassword(for: node.name, incorrect: false) else { return nil }
            password = answer.password
        }

        let folder = scratch.appending(component: "\(level.id.uuidString.prefix(8))-\(node.id)",
                                       directoryHint: .isDirectory)
        while true {
            let activity = BrowserActivity(title: "Unpacking “\(node.name)”")
            let attempt = password
            let result: Result<ArchiveOutcome, any Error> = await perform(activity) {
                try await level.archive.extract(IndexSet(integer: index), to: folder,
                                                paths: .flatten, overwrite: .overwrite,
                                                password: self.provider(attempt),
                                                onProgress: self.progressSink(activity))
            }
            switch result {
            case .success(let outcome) where outcome.entryErrors.isEmpty:
                remember(password, for: level)
                // Flattening writes the entry under its own name — unless the
                // filesystem would not take that name and the engine had to
                // change it. The folder holds exactly one thing either way.
                let arrived = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil))?.first
                    ?? folder.appending(component: node.name)
                extracted[key] = arrived
                return arrived
            case .success(let outcome):
                problem = "“\(node.name)” could not be unpacked: "
                    + (outcome.entryErrors.first?.archiveDescription.lowercased() ?? "unknown error") + "."
                return nil
            case .failure(let error) where error.isPasswordProblem:
                incorrect = true
                guard let answer = await askPassword(for: node.name, incorrect: incorrect) else { return nil }
                password = answer.password
            case .failure(let error) where error is CancellationError || error.sevenZipCode == .cancelled:
                return nil
            case .failure(let error):
                problem = "“\(node.name)” could not be unpacked: \(error.archiveDescription.lowercased())."
                return nil
            }
        }
    }

    // MARK: - Extracting

    /// What "Extract" would take: the selection, or everything.
    var extractionSummary: String {
        guard let level = current else { return "" }
        if selection.isEmpty {
            return "Everything in “\(level.title)”"
        }
        let (files, bytes) = level.tree.summary(of: selection)
        return "\(Display.count(UInt64(files), "file", "files")), \(Display.bytes(bytes))"
    }

    /// Queues the selection — or the whole archive when nothing is selected
    /// — for extraction into `folder`.
    ///
    /// A selection lands without the folders its entries share, the way a
    /// file dragged out of a Finder window leaves its parents behind. The
    /// whole archive gets the same treatment as a drop: its own folder unless
    /// it has a single root.
    func extract(to folder: URL) async {
        guard let level = current else { return }
        var password = level.password
        let indexes = selection.isEmpty ? nil : level.tree.entryIndexes(for: selection)
        if let indexes, indexes.isEmpty { return }

        // Ask now, while the window that needs the answer is in front, rather
        // than from the queue later.
        let encrypted = level.archive.entries.contains { entry in
            entry.isEncrypted && (indexes?.contains(Int(entry.index)) ?? true)
        }
        if encrypted, password == nil {
            guard let answer = await askPassword(for: level.title, incorrect: false) else { return }
            password = answer.password
        }

        let title: String
        if indexes == nil {
            title = level.title
        } else if selection.count == 1, let id = selection.first, let node = level.tree.node(id) {
            title = "\(node.name) from \(level.title)"
        } else {
            title = "\(Display.count(UInt64(selection.count), "item", "items")) from \(level.title)"
        }
        queue.enqueue([.extractEntries(EntrySelection(archive: level.archive,
                                                      archiveName: level.title,
                                                      indexes: indexes,
                                                      destination: folder,
                                                      password: password,
                                                      title: title))])
    }

    /// The folder the root archive sits in: the natural default for both the
    /// panel and "Extract Here".
    var defaultDestination: URL { url.deletingLastPathComponent() }

    // MARK: - Closing

    /// Stops whatever is running and deletes the scratch folder.
    func close() {
        activity?.cancel()
        passwordPrompt?.cancel()
        previewURL = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Scratch folders of windows that never got to clean up — a crash, a
    /// force quit. Called once at launch.
    static func sweepAbandonedScratch() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    nonisolated static var scratchRoot: URL {
        FileManager.default.temporaryDirectory.appending(component: "Browse", directoryHint: .isDirectory)
    }

    // MARK: - Plumbing

    private func resort() {
        for position in levels.indices {
            levels[position].tree.sort(using: sortOrder)
        }
        refreshMatches()
    }

    private func refreshMatches() {
        guard isShowingMatches, let tree = current?.tree else {
            matches = []
            return
        }
        matches = tree.matches(searchText, filter: filter, comparators: sortOrder)
    }

    private func remember(_ password: String?, for level: Level) {
        guard let password, let position = levels.firstIndex(where: { $0.id == level.id }) else { return }
        levels[position].password = password
    }

    /// Runs `work` as the browser's one activity, so the window can show it
    /// and the person can stop it.
    private func perform<T: Sendable>(_ activity: BrowserActivity,
                                      _ work: @escaping @MainActor () async throws -> T)
        async -> Result<T, any Error> {
        self.activity = activity
        defer { self.activity = nil }
        let task = Task { @MainActor in
            do { return Result<T, any Error>.success(try await work()) }
            catch { return .failure(error) }
        }
        activity.onCancel = { task.cancel() }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func progressSink(_ activity: BrowserActivity) -> ProgressObserver {
        let throttle = ProgressThrottle()
        return { progress in
            guard throttle.allow() else { return }
            Task { @MainActor in
                activity.totalBytes = progress.totalBytes
                activity.completedBytes = progress.completedBytes
            }
        }
    }

    /// The keychain is only offered for the archive file itself: a password
    /// keyed to a path inside a scratch folder would be forgotten at once.
    private func askPassword(for name: String, incorrect: Bool,
                             offersKeychain: Bool = false) async -> PasswordAnswer? {
        await withCheckedContinuation { continuation in
            passwordPrompt = PasswordPrompt(archiveName: name, incorrect: incorrect,
                                            offersKeychain: offersKeychain) { [weak self] answer in
                self?.passwordPrompt = nil
                continuation.resume(returning: answer)
            }
        }
    }

    private nonisolated func provider(_ password: String?) -> PasswordProvider? {
        guard let password else { return nil }
        return { password }
    }
}
