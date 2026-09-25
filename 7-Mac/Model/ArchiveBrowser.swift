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
        /// The folder being looked at, by path — ids do not survive an
        /// edit, paths mostly do. Empty for the top of the archive.
        fileprivate(set) var folderPath = ""
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
    /// Non-nil while a test report sheet is up.
    var shownTestReport: TestReport?
    /// Non-nil while a checksum sheet is up.
    var checksums: ChecksumModel?
    private(set) var activity: BrowserActivity?

    let preferences: Preferences
    private let queue: JobQueue
    /// Asks for folder access when an edit needs to write beside the
    /// archive. The app model in the app, nothing in tests.
    private weak var interaction: (any JobInteraction)?
    /// The root archive's history. Only the root: an archive inside another
    /// is not a file that can be replaced.
    private(set) var editor: ArchiveEditor?
    /// The window's own, so Edit › Undo names the edit and ⌘Z reaches it.
    weak var undoManager: UndoManager?
    /// Edits and history steps queue up behind each other: each one swaps
    /// the file the next one reads.
    private var editChain: Task<Void, Never>?
    /// Previews and unpacked archives go here, and all of it goes when the
    /// window does.
    let scratch: URL
    /// Level id + node id → extracted copy, so a second look is instant.
    private var extracted: [String: URL] = [:]

    init(url: URL, preferences: Preferences, queue: JobQueue,
         interaction: (any JobInteraction)? = nil) {
        self.url = url
        self.preferences = preferences
        self.queue = queue
        self.interaction = interaction
        scratch = Self.scratchRoot.appending(component: UUID().uuidString, directoryHint: .isDirectory)
    }

    var current: Level? { levels.last }
    /// What the table lists: the open folder's contents, or the top.
    var roots: [ArchiveNode] { currentFolder?.children ?? current?.tree.roots ?? [] }

    /// The folder the current level is open on; nil at the top.
    var currentFolder: ArchiveNode? {
        guard let level = current, !level.folderPath.isEmpty else { return nil }
        return level.tree.folder(at: level.folderPath)
    }

    /// The open folder and the ones above it, outermost first.
    var folderTrail: [ArchiveNode] {
        guard let level = current else { return [] }
        let components = ArchiveTree.components(of: level.folderPath)
        return components.indices.compactMap {
            level.tree.folder(at: components[...$0].joined(separator: "/"))
        }
    }

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
                if editor == nil { editor = ArchiveEditor(url: url, scratch: scratch) }
                break
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: url.lastPathComponent, incorrect: incorrect,
                                                     offersKeychain: preferences.offersKeychain)
                else {
                    phase = .failed(String(localized: "This archive is encrypted."))
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
                problem = String(localized: "“\(node.name)” could not be opened: \(error.archiveDescription.lowercased()).")
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
                problem = String(localized: "“\(node.name)” is not an archive 7-Mac can open.")
                return
            }
        }
    }

    // MARK: - Folders

    /// Opens `folder` in the table, the way a double-click does in Finder.
    func enter(_ folder: ArchiveNode) {
        guard folder.isDirectory, !levels.isEmpty else { return }
        show(folder: folder.path)
    }

    /// Back to one of the folders above, or with nil to the top.
    func goToFolder(_ folder: ArchiveNode?) {
        guard !levels.isEmpty else { return }
        show(folder: folder?.path ?? "")
    }

    private func show(folder path: String) {
        let last = levels.count - 1
        let previous = levels[last].folderPath
        guard previous != path else { return }
        levels[last].folderPath = path
        // Coming back out selects the folder you were in, as Finder does.
        let target = ArchiveTree.components(of: path)
        let from = ArchiveTree.components(of: previous)
        if from.count > target.count, Array(from.prefix(target.count)) == target,
           let left = levels[last].tree.folder(at: from.prefix(target.count + 1).joined(separator: "/")) {
            selection = [left.id]
        } else {
            selection = []
        }
    }

    private func push(_ level: Level) {
        levels.append(level)
        selection = []
        refreshMatches()
    }

    /// Pops back to `level`, at the top of it.
    func goBack(to level: Level.ID) {
        guard let position = levels.firstIndex(where: { $0.id == level }) else { return }
        if position == levels.count - 1 {
            goToFolder(nil)
            return
        }
        levels.removeSubrange((position + 1)...)
        selection = []
        refreshMatches()
    }

    /// Up one: the enclosing folder, or the archive this one is inside.
    func goUp() {
        if let folder = currentFolder {
            let parent = (folder.path as NSString).deletingLastPathComponent
            show(folder: parent)
            return
        }
        guard levels.count > 1 else { return }
        goBack(to: levels[levels.count - 2].id)
    }

    var canGoUp: Bool { currentFolder != nil || levels.count > 1 }

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
            let activity = BrowserActivity(title: String(localized: "Unpacking “\(node.name)”"))
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
                let reason = outcome.entryErrors.first?.archiveDescription.lowercased()
                    ?? String(localized: "unknown error")
                problem = String(localized: "“\(node.name)” could not be unpacked: \(reason).")
                return nil
            case .failure(let error) where error.isPasswordProblem:
                incorrect = true
                guard let answer = await askPassword(for: node.name, incorrect: incorrect) else { return nil }
                password = answer.password
            case .failure(let error) where error is CancellationError || error.sevenZipCode == .cancelled:
                return nil
            case .failure(let error):
                problem = String(localized: "“\(node.name)” could not be unpacked: \(error.archiveDescription.lowercased()).")
                return nil
            }
        }
    }

    // MARK: - Extracting

    /// What "Extract" would take: the selection, or everything.
    var extractionSummary: String {
        guard let level = current else { return "" }
        if selection.isEmpty {
            return String(localized: "Everything in “\(level.title)”")
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
            title = String(localized: "\(node.name) from \(level.title)")
        } else {
            title = String(localized: "\(Display.count(UInt64(selection.count), "item", "items")) from \(level.title)")
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

    // MARK: - Testing and checksums

    /// Decodes the selection, or everything, and shows what it found. The
    /// same pass computes CRC32s, which the report lists.
    func test() async {
        guard let level = current else { return }
        let indexes = selection.isEmpty ? nil : level.tree.entryIndexes(for: selection)
        var password = level.password
        if password == nil, level.archive.entries.contains(where: {
            $0.isEncrypted && (indexes?.contains(Int($0.index)) ?? true)
        }) {
            guard let answer = await askPassword(for: level.title, incorrect: false) else { return }
            password = answer.password
        }
        var incorrect = false
        while true {
            let activity = BrowserActivity(title: String(localized: "Testing “\(level.title)”"))
            let attempt = password
            let result: Result<HashReport, any Error> = await perform(activity) {
                try await level.archive.hash(indexes, methods: ["CRC32"],
                                             password: self.provider(attempt),
                                             onProgress: self.progressSink(activity))
            }
            switch result {
            case .success(let report):
                let failures = report.failures.filter(\.isPasswordProblem)
                if !failures.isEmpty, failures.count == report.failures.count {
                    incorrect = true
                    guard let answer = await askPassword(for: level.title, incorrect: incorrect)
                    else { return }
                    password = answer.password
                    continue
                }
                remember(password, for: level)
                shownTestReport = TestReport(archiveName: level.title, report: report)
                return
            case .failure(let error) where error.isPasswordProblem:
                incorrect = true
                guard let answer = await askPassword(for: level.title, incorrect: incorrect) else { return }
                password = answer.password
            case .failure(let error) where error is CancellationError || error.sevenZipCode == .cancelled:
                return
            case .failure(let error):
                problem = String(localized: "Testing “\(level.title)” did not work: \(error.archiveDescription.lowercased()).")
                return
            }
        }
    }

    /// Checksums of the selected entries, or all of them, as they decode.
    func showChecksums() async {
        guard let level = current else { return }
        let indexes = selection.isEmpty ? nil : level.tree.entryIndexes(for: selection)
        var password = level.password
        if password == nil, level.archive.entries.contains(where: {
            $0.isEncrypted && (indexes?.contains(Int($0.index)) ?? true)
        }) {
            guard let answer = await askPassword(for: level.title, incorrect: false) else { return }
            password = answer.password
        }
        let title = selection.count == 1 ? (level.tree.node(selection.first!)?.name ?? level.title)
                                         : level.title
        checksums = ChecksumModel(source: .entries(archive: level.archive, indexes: indexes,
                                                   title: title, password: password))
    }

    // MARK: - Editing

    /// Why the archive on screen cannot be changed, or `nil` when it can.
    var editBlockedReason: String? {
        guard let level = current else { return String(localized: "nothing is open") }
        if levels.count > 1 || level.archive.parent != nil {
            return String(localized: "this archive is inside another one")
        }
        // The engine's reasons are English sentences; the catalog carries
        // each one it can give.
        if let reason = level.archive.reasonNotModifiable {
            return String(localized: String.LocalizationValue(reason))
        }
        // A compressor holds one stream, not a list of entries to edit.
        if Self.compressorFormats.contains(level.archive.formatName) {
            return String(localized: "a \(level.archive.formatName) file holds a single stream")
        }
        return nil
    }

    var canEdit: Bool { editBlockedReason == nil && activity == nil }

    /// Removes the selected entries — a folder with everything in it.
    func delete(_ ids: Set<ArchiveNode.ID>) async {
        guard let tree = current?.tree else { return }
        let indexes = tree.entryIndexes(for: ids)
        guard !indexes.isEmpty else { return }
        let title = ids.count == 1 ? String(localized: "Delete “\(tree.node(ids.first!)?.name ?? "")”")
                                   : String(localized: "Delete \(ids.count) Items")
        await edit(title) { archive, destination, password in
            try await archive.writeDeleting(indexes, to: destination, password: password,
                                            onProgress: self.progressSink(self.activity))
        }
    }

    /// Whether `name` would do as a new name for `node`: not empty, one path
    /// component, and not already a sibling's.
    func validateNewName(_ name: String, for node: ArchiveNode) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "A name cannot be empty.") }
        if trimmed.contains("/") { return String(localized: "A name cannot contain “/”.") }
        if trimmed == "." || trimmed == ".." { return String(localized: "That name is reserved.") }
        let path = Self.path(replacingLastComponentOf: node.path, with: trimmed)
        if trimmed != node.name,
           current?.tree.allNodes.contains(where: { $0.path == path && $0.id != node.id }) == true {
            return String(localized: "“\(trimmed)” is already taken.")
        }
        return nil
    }

    /// Renames `node`, and for a folder every entry beneath it: an archive
    /// has no folders to rename, only paths that begin the same way.
    func rename(_ node: ArchiveNode, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != node.name, validateNewName(name, for: node) == nil else { return }
        let newPath = Self.path(replacingLastComponentOf: node.path, with: name)
        var renames: [Int: String] = [:]
        for member in node.subtree {
            guard let index = member.record?.index else { continue }
            renames[index] = newPath + member.path.dropFirst(node.path.count)
        }
        guard !renames.isEmpty else { return }
        await edit(String(localized: "Rename “\(node.name)”")) { archive, destination, password in
            try await archive.writeRenaming(renames, to: destination, password: password,
                                            onProgress: self.progressSink(self.activity))
        }
    }

    /// Adds files and folders from disk into `folder`, or the root. What
    /// happens to a name already taken is the "only replace older" setting.
    func add(_ sources: [URL], into folder: ArchiveNode?) async {
        guard !sources.isEmpty, let level = current else { return }
        let folderPath = folder.map { $0.isDirectory ? $0.path : ($0.path as NSString).deletingLastPathComponent } ?? ""
        let onlyIfNewer = preferences.onlyReplaceOlder
        let title = sources.count == 1 ? String(localized: "Add “\(sources[0].lastPathComponent)”")
                                       : String(localized: "Add \(sources.count) Items")

        // New entries in an encrypted archive should be encrypted too, and
        // that takes the password up front: the engine will not ask for the
        // one it encrypts with.
        var password = level.password
        if password == nil, level.archive.entries.contains(where: \.isEncrypted) {
            guard let answer = await askPassword(for: level.title, incorrect: false) else { return }
            password = answer.password
        }

        await edit(title, password: password) { archive, destination, password in
            let scoped = sources.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            return try await archive.writeAdding(sources, inFolder: folderPath, onlyIfNewer: onlyIfNewer,
                                                 to: destination, password: password,
                                                 onProgress: self.progressSink(self.activity))
        }
    }

    /// Takes back the last edit. What ⌘Z does, by way of the window's undo
    /// manager; callable directly as well.
    func undo() async { await history(back: true) }
    func redo() async { await history(back: false) }

    var canUndo: Bool { editor?.canUndo ?? false }
    var canRedo: Bool { editor?.canRedo ?? false }

    /// Runs one edit: ask for what it needs, write, swap, reopen, remember
    /// how to undo it.
    private func edit(_ title: String, password initial: String? = nil,
                      write: @escaping @MainActor (Archive, URL, String?) async throws -> ArchiveOutcome) async {
        await serialized {
            guard self.editBlockedReason == nil, let editor = self.editor,
                  let level = self.levels.first
            else { return }
            var password = initial ?? level.password
            var incorrect = false
            while true {
                let activity = BrowserActivity(title: title)
                let attempt = password
                let result: Result<ArchiveOutcome, any Error> = await self.perform(activity) {
                    try await editor.apply(title) { destination in
                        try await write(level.archive, destination, attempt)
                    }
                }
                switch result {
                case .success:
                    await self.reopen(password: password)
                    self.registerHistory(title, back: true)
                    return
                case .failure(ArchiveEditError.folderNotWritable(let folder)):
                    guard let interaction = self.interaction,
                          await interaction.askWritableFolder(
                              message: String(localized: "To change “\(level.title)”, 7-Mac needs permission to write into the folder it is in. Choose “\(folder.lastPathComponent)”."),
                              suggesting: folder) != nil,
                          FolderAccess.shared.prepare(folder)
                    else {
                        self.problem = ArchiveEditError.folderNotWritable(folder).localizedDescription
                        return
                    }
                case .failure(let error) where error.isPasswordProblem:
                    guard let answer = await self.askPassword(for: level.title, incorrect: incorrect)
                    else { return }
                    password = answer.password
                    incorrect = true
                case .failure(let error) where error is CancellationError || error.sevenZipCode == .cancelled:
                    return
                case .failure(let error):
                    self.problem = String(localized: "\(title) did not work: \(error.archiveDescription.lowercased()). The archive has not been changed.")
                    return
                }
            }
        }
    }

    private func history(back: Bool) async {
        await serialized {
            guard let editor = self.editor,
                  back ? editor.canUndo : editor.canRedo
            else { return }
            let title = (back ? editor.undoSteps.last : editor.redoSteps.last)?.title ?? ""
            let activity = BrowserActivity(title: back ? String(localized: "Undoing \(title)") : String(localized: "Redoing \(title)"))
            let result = await self.perform(activity) {
                try await back ? editor.undo() : editor.redo()
            }
            switch result {
            case .success:
                await self.reopen(password: self.levels.first?.password)
            case .failure(let error):
                self.problem = back ? String(localized: "Could not undo \(title): \(error.localizedDescription)")
                                    : String(localized: "Could not redo \(title): \(error.localizedDescription)")
                // History that did not replay is history that cannot be
                // trusted to replay later either.
                self.undoManager?.removeAllActions(withTarget: self)
            }
        }
    }

    /// Tells the window's undo manager how to reverse what just happened.
    /// Registered from inside an undo, the same call becomes the redo —
    /// which is how UndoManager wants it done.
    private func registerHistory(_ title: String, back: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { browser in
            browser.registerHistory(title, back: !back)
            Task { await browser.history(back: back) }
        }
        undoManager.setActionName(title)
    }

    /// Reads the archive again after the file under it changed. The stack
    /// goes back to the root, and anything unpacked from the old file is
    /// forgotten: its indexes no longer mean the same entries.
    private func reopen(password: String?) async {
        do {
            let archive = try await Archive.open(url, password: provider(password))
            var level = await makeLevel(archive, title: url.lastPathComponent,
                                        password: password, isInPlace: false)
            // Stay in the folder that was open, or as near it as still exists.
            var folder = levels.first?.folderPath ?? ""
            while !folder.isEmpty, level.tree.folder(at: folder) == nil {
                folder = (folder as NSString).deletingLastPathComponent
            }
            level.folderPath = folder
            levels = [level]
            selection = []
            extracted = [:]
            refreshMatches()
        } catch {
            phase = .failed(error.archiveDescription)
        }
    }

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = editChain
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        editChain = next
        await next.value
    }

    nonisolated static func path(replacingLastComponentOf path: String, with name: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }

    // MARK: - Closing

    /// Stops whatever is running and deletes the scratch folder — with it
    /// the undo history, which nothing could reach once the window is gone.
    func close() {
        activity?.cancel()
        passwordPrompt?.cancel()
        previewURL = nil
        undoManager?.removeAllActions(withTarget: self)
        editor?.discardHistory()
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

    private func progressSink(_ activity: BrowserActivity?) -> ProgressObserver {
        let throttle = ProgressThrottle()
        return { progress in
            guard throttle.allow() else { return }
            Task { @MainActor in
                activity?.totalBytes = progress.totalBytes
                activity?.completedBytes = progress.completedBytes
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
