//
//  ArchiveEditor.swift
//  7-Mac
//
//  Changing an archive file, safely and undoably.
//
//  The engine never edits an archive where it lies: it writes a complete new
//  one. So an edit here is three steps — write the new archive next to the
//  old, keep a copy of the old, swap the two — and undo is the same swap run
//  backwards. Until the swap, the person's file is untouched, which is what
//  lets a failed or cancelled edit simply not have happened.
//
//  The copies are clones on APFS: the same blocks, shared, until one side
//  changes. On other filesystems they are real copies, which for a large
//  archive on an external drive costs time and space — the price of an undo
//  that cannot lose the original.
//

import Foundation

/// Why an edit could not go ahead before it started.
nonisolated enum ArchiveEditError: LocalizedError {
    /// The sandbox will not let us write the folder the archive is in.
    case folderNotWritable(URL)

    var errorDescription: String? {
        switch self {
        case .folderNotWritable(let folder):
            String(localized: "7-Mac is not allowed to write into “\(folder.lastPathComponent)”.")
        }
    }
}

@MainActor
final class ArchiveEditor {
    /// One edit that can be taken back, or put back.
    struct Step {
        /// "Delete 3 Items", as the Edit menu will say it.
        let title: String
        /// The archive as it was on the other side of this step.
        let snapshot: URL
    }

    let url: URL
    private let snapshots: URL
    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []

    /// `scratch` is the browser window's folder, and goes with it: an undo
    /// history outliving the window that shows it would be undo nobody can
    /// reach.
    init(url: URL, scratch: URL) {
        self.url = url
        snapshots = scratch.appending(component: "undo", directoryHint: .isDirectory)
    }

    var folder: URL { url.deletingLastPathComponent() }

    /// Runs `write` into a new file beside the archive and, if it succeeds,
    /// puts that file in the archive's place — keeping the old one to undo
    /// to. On failure nothing has changed, and the half-written file is gone.
    func apply(_ title: String,
               write: (URL) async throws -> ArchiveOutcome) async throws -> ArchiveOutcome {
        let incoming = try temporarySibling()
        let outcome: ArchiveOutcome
        do {
            outcome = try await write(incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }

        let snapshot = try await snapshotOfCurrent()
        do {
            try swapIn(incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            discard(snapshot)
            throw error
        }
        undoSteps.append(Step(title: title, snapshot: snapshot))
        clear(&redoSteps)
        return outcome
    }

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    /// Puts back the archive as it was before the last edit, and returns
    /// that edit's title.
    @discardableResult
    func undo() async throws -> String? {
        try await step(back: true)
    }

    /// Does the last undone edit again.
    @discardableResult
    func redo() async throws -> String? {
        try await step(back: false)
    }

    /// Forgets the history and its copies, when the window closes.
    func discardHistory() {
        undoSteps = []
        redoSteps = []
        try? FileManager.default.removeItem(at: snapshots)
    }

    // MARK: - Plumbing

    private func step(back: Bool) async throws -> String? {
        guard let step = back ? undoSteps.last : redoSteps.last else { return nil }
        // The present becomes the other side's snapshot before it is replaced.
        let present = try await snapshotOfCurrent()
        let incoming = try temporarySibling()
        do {
            try await clone(step.snapshot, to: incoming)
            try swapIn(incoming)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            discard(present)
            throw error
        }
        discard(step.snapshot)
        let reverse = Step(title: step.title, snapshot: present)
        if back {
            undoSteps.removeLast()
            redoSteps.append(reverse)
        } else {
            redoSteps.removeLast()
            undoSteps.append(reverse)
        }
        return step.title
    }

    /// A name next to the archive that nothing occupies. Beside it rather
    /// than in a temporary folder so the final swap is a rename on one
    /// volume — atomic — and not a copy across two.
    private func temporarySibling() throws -> URL {
        guard FolderAccess.shared.prepare(folder) else {
            throw ArchiveEditError.folderNotWritable(folder)
        }
        return folder.appending(component: ".\(url.lastPathComponent).7-Mac-\(UUID().uuidString.prefix(8))")
    }

    private func snapshotOfCurrent() async throws -> URL {
        let snapshot = snapshots.appending(component: UUID().uuidString, directoryHint: .isDirectory)
            .appending(component: url.lastPathComponent)
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await clone(url, to: snapshot)
        return snapshot
    }

    /// `copyItem` clones on APFS and copies elsewhere. Off the main actor,
    /// because elsewhere can take a while.
    private func clone(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    /// Replaces the archive with `incoming`, atomically. The archive keeps
    /// its identity as far as the Finder is concerned: same name, same
    /// place, same tags.
    private func swapIn(_ incoming: URL) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: incoming)
    }

    private func clear(_ steps: inout [Step]) {
        for step in steps { discard(step.snapshot) }
        steps = []
    }

    /// Each snapshot has a folder of its own, so it can keep the archive's
    /// name; the folder goes with it.
    private func discard(_ snapshot: URL) {
        try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent())
    }
}
