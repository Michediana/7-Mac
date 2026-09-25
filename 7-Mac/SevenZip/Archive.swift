//
//  Archive.swift
//  7-Mac
//
//  Async Swift wrapper around SZKArchive.
//

import Foundation
@preconcurrency import SevenZipKit

/// Asked for a password. Return `nil` to give up, which surfaces as
/// `SZKError.cancelled`.
public typealias PasswordProvider = @Sendable () -> String?

/// Called as work proceeds, off the main actor. Throwing is not how you stop
/// an operation — cancel the enclosing `Task` instead.
public typealias ProgressObserver = @Sendable (ArchiveProgress) -> Void

/// A snapshot of an operation in flight.
nonisolated public struct ArchiveProgress: Sendable {
    public let totalBytes: UInt64
    public let completedBytes: UInt64
    public let currentPath: String
    public let currentIsDirectory: Bool

    /// 0…1, or `nil` while the engine does not yet know the total.
    public var fractionCompleted: Double? {
        totalBytes == 0 ? nil : min(1, Double(completedBytes) / Double(totalBytes))
    }

    init(_ progress: SZKProgress) {
        totalBytes = progress.totalBytes
        completedBytes = progress.completedBytes
        currentPath = progress.currentPath
        currentIsDirectory = progress.currentIsDirectory
    }
}

/// What an operation did, reported even when it ended in an error.
nonisolated public struct ArchiveOutcome: Sendable {
    public let files: UInt64
    public let folders: UInt64
    public let bytes: UInt64
    /// Bytes the engine decoded. Larger than `bytes` for a partial extract
    /// from a solid archive, which decodes a whole block to reach one entry.
    public let processedBytes: UInt64
    public let archiveSize: UInt64
    /// Entries that failed while the run carried on.
    public let entryErrors: [NSError]

    init(files: UInt64 = 0, folders: UInt64 = 0, bytes: UInt64 = 0, processedBytes: UInt64 = 0,
         archiveSize: UInt64 = 0, entryErrors: [NSError] = []) {
        self.files = files
        self.folders = folders
        self.bytes = bytes
        self.processedBytes = processedBytes
        self.archiveSize = archiveSize
        self.entryErrors = entryErrors
    }

    init(_ outcome: SZKOutcome) {
        files = outcome.fileCount
        folders = outcome.folderCount
        bytes = outcome.byteCount
        processedBytes = outcome.processedByteCount
        archiveSize = outcome.archiveSize
        entryErrors = outcome.entryErrors as [NSError]
    }
}

/// Checksums of a set of files, or of an archive's entries.
nonisolated public struct HashReport: Sendable {
    public struct Item: Sendable, Identifiable {
        public let id: Int
        public let path: String
        public let isDirectory: Bool
        public let size: UInt64
        /// One per method, in `methods` order; empty for a folder.
        public let digests: [String]
    }

    /// As the engine names them: `CRC32`, `SHA256`…
    public let methods: [String]
    public let items: [Item]
    /// 7-Zip's "sum of data", one per method over every file.
    public let dataSums: [String]
    public let files: UInt64
    public let bytes: UInt64
    public let failures: [NSError]

    init(methods: [String], items: [Item], dataSums: [String], files: UInt64, bytes: UInt64,
         failures: [NSError]) {
        self.methods = methods
        self.items = items
        self.dataSums = dataSums
        self.files = files
        self.bytes = bytes
        self.failures = failures
    }

    init(_ report: SZKHashReport) {
        methods = report.methods
        items = report.items.enumerated().map { position, item in
            Item(id: position, path: item.path, isDirectory: item.isDirectory,
                 size: item.size, digests: item.digests)
        }
        dataSums = report.dataSums
        files = report.fileCount
        bytes = report.byteCount
        failures = report.failures as [NSError]
    }
}

/// An open archive.
///
/// Reads and writes run on a private serial queue, so `await`ing them never
/// blocks the caller. 7-Zip handlers keep position state on the underlying
/// stream, which is why the queue is serial: one operation at a time per
/// archive. Open the file twice if you want two running at once.
nonisolated public final class Archive: @unchecked Sendable {
    private let queue: DispatchQueue
    private let archive: SZKArchive

    public let url: URL
    public let formatName: String
    public let physicalSize: UInt64?
    public let hasEncryptedHeader: Bool
    public let volumeCount: Int
    public let additionalVolumeURLs: [URL]
    public let entries: [SZKArchiveEntry]
    /// For an archive read in place out of another: that archive, which this
    /// one reads through and therefore keeps alive.
    public let parent: Archive?
    /// The entry path this archive has inside `parent`.
    public let pathInParent: String?
    /// Why this archive cannot be edited, or `nil` when it can. Fixed at
    /// open: it depends on the format and how the file was reached.
    public let reasonNotModifiable: String?

    private init(_ archive: SZKArchive, parent: Archive? = nil) {
        self.archive = archive
        // A nested archive reads through its parent's stream, so the two
        // must never run at once: they share the parent's queue.
        self.queue = parent?.queue
            ?? DispatchQueue(label: "eu.dgnet.7-Mac.archive.\(ObjectIdentifier(archive).hashValue)")
        self.parent = parent
        pathInParent = archive.pathInParent
        // Writing a nested archive would produce a new copy of it, not a new
        // copy of the file that holds it.
        reasonNotModifiable = parent == nil ? archive.reasonNotModifiable
                                            : "this archive is inside another one"
        url = archive.url
        formatName = archive.formatName
        physicalSize = archive.physicalSize?.uint64Value
        hasEncryptedHeader = archive.hasEncryptedHeader
        volumeCount = Int(archive.volumeCount)
        additionalVolumeURLs = archive.additionalVolumeURLs
        entries = archive.entries
    }

    /// Opens the archive at `url`.
    ///
    /// Throws `SZKError.passwordRequired` when the entry list is encrypted and
    /// `password` is absent or declines.
    public static func open(_ url: URL, password: PasswordProvider? = nil) async throws -> Archive {
        try await withCheckedThrowingContinuation { continuation in
            Self.openQueue.async {
                do {
                    let opened = try SZKArchive(at: url, passwordProvider: password.map(bridge))
                    continuation.resume(returning: Archive(opened))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let openQueue = DispatchQueue(label: "eu.dgnet.7-Mac.archive.open",
                                                 attributes: .concurrent)

    /// Opens entry `index` as an archive without extracting it, reading
    /// through this archive's stream.
    ///
    /// Works for containers that can seek inside an entry — tar, iso, dmg,
    /// cpio, ar. Formats that compress their entries throw
    /// `SZKError.unsupported`; extract the entry and open the file instead.
    public func openEntry(_ index: Int, password: PasswordProvider? = nil) async throws -> Archive {
        try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) let archive = self.archive
            queue.async {
                do {
                    let nested = try archive.openEntry(at: UInt(index),
                                                       passwordProvider: password.map(bridge))
                    continuation.resume(returning: Archive(nested, parent: self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Extracts `selection`, or everything when it is `nil`, into `destination`.
    ///
    /// Selection is by entry index rather than by name pattern, so picking a
    /// handful out of a large archive costs a handful of entries' work. With
    /// `relativeToCommonParent` the selection lands without the folders its
    /// entries share, which is what extracting from a browser means.
    /// Cancelling the surrounding `Task` stops the engine cooperatively and
    /// throws `CancellationError`.
    @discardableResult
    public func extract(_ selection: IndexSet? = nil,
                        to destination: URL,
                        paths: SZKPathPolicy = .fullPaths,
                        relativeToCommonParent: Bool = false,
                        overwrite: SZKOverwritePolicy = .autoRename,
                        password: PasswordProvider? = nil,
                        onOverwrite: (@Sendable (SZKOverwriteRequest) -> SZKOverwriteDecision)? = nil,
                        onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        let options = SZKExtractOptions(destinationDirectory: destination)
        options.paths = paths
        options.relativeToCommonParent = relativeToCommonParent
        options.overwrite = overwrite

        return try await run { archive, progress in
            var outcome: SZKOutcome?
            try archive.extractIndexes(selection,
                                       options: options,
                                       progress: progress,
                                       passwordProvider: password.map(bridge),
                                       overwriteHandler: onOverwrite,
                                       outcome: &outcome)
            return outcome
        } onProgress: { onProgress?($0) }
    }

    // MARK: Rewriting
    //
    // Each writes a whole new archive to `destination` and leaves this one
    // alone; `ArchiveEditor` is what swaps the files and keeps the undo.


    /// Writes this archive without the entries in `indexes` to `destination`.
    @discardableResult
    public func writeDeleting(_ indexes: IndexSet, to destination: URL, password: String? = nil,
                              onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        try await run { archive, progress in
            var outcome: SZKOutcome?
            try archive.writeDeleting(indexes, to: destination, password: password,
                                             progress: progress, outcome: &outcome)
            return outcome
        } onProgress: { onProgress?($0) }
    }

    /// Writes this archive with the entries in `newPaths` renamed.
    @discardableResult
    public func writeRenaming(_ newPaths: [Int: String], to destination: URL, password: String? = nil,
                              onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        let boxed = Dictionary(uniqueKeysWithValues: newPaths.map { (NSNumber(value: $0.key), $0.value) })
        return try await run { archive, progress in
            var outcome: SZKOutcome?
            try archive.writeRenaming(boxed, to: destination, password: password,
                                      progress: progress, outcome: &outcome)
            return outcome
        } onProgress: { onProgress?($0) }
    }

    /// Writes this archive with `sources` added under `folder`.
    @discardableResult
    public func writeAdding(_ sources: [URL], inFolder folder: String, onlyIfNewer: Bool = false,
                            to destination: URL, password: String? = nil,
                            onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        try await run { archive, progress in
            var outcome: SZKOutcome?
            try archive.writeAdding(sources, inFolder: folder, onlyIfNewer: onlyIfNewer,
                                    to: destination, password: password,
                                    progress: progress, outcome: &outcome)
            return outcome
        } onProgress: { onProgress?($0) }
    }

    /// Decodes `selection` (everything when `nil`) and checksums each entry,
    /// writing nothing. Entries that fail to decode are in `failures`.
    public func hash(_ selection: IndexSet? = nil, methods: [String],
                     password: PasswordProvider? = nil,
                     onProgress: ProgressObserver? = nil) async throws -> HashReport {
        try await withTaskCancellationState { isCancelled in
            try await withCheckedThrowingContinuation { continuation in
                nonisolated(unsafe) let archive = self.archive
                queue.async {
                    do {
                        let report = try archive.hashIndexes(selection, methods: methods,
                                                             progress: progressBridge(isCancelled, onProgress),
                                                             passwordProvider: password.map(bridge))
                        continuation.resume(returning: HashReport(report))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Decodes and verifies without writing anything.
    @discardableResult
    public func test(_ selection: IndexSet? = nil,
                     password: PasswordProvider? = nil,
                     onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        try await run { archive, progress in
            var outcome: SZKOutcome?
            try archive.test(selection,
                             progress: progress,
                             passwordProvider: password.map(bridge),
                             outcome: &outcome)
            return outcome
        } onProgress: { onProgress?($0) }
    }

    /// Creates an archive at `url` from `sources`, scanning folders recursively.
    /// Paths are stored relative to each source's parent, so adding `/a/b/tree`
    /// stores `tree/…`. Fails if anything already exists at `url`.
    @discardableResult
    public static func create(at url: URL,
                              from sources: [URL],
                              format: String? = nil,
                              level: SZKCompressionLevel = .normal,
                              password: String? = nil,
                              encryptsHeader: Bool = false,
                              volumeSize: UInt64 = 0,
                              methodProperties: [String: String]? = nil,
                              excluding excludedNames: [String] = [],
                              storesSymbolicLinks: Bool = true,
                              storesHardLinks: Bool = true,
                              onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        let options = SZKCreateOptions()
        options.excludedNamePatterns = excludedNames
        options.storesSymbolicLinks = storesSymbolicLinks
        options.storesHardLinks = storesHardLinks
        options.formatName = format
        options.level = level
        options.password = password
        options.encryptsHeader = encryptsHeader
        options.volumeSize = volumeSize
        options.methodProperties = methodProperties

        return try await withTaskCancellationState { isCancelled in
            try await withCheckedThrowingContinuation { continuation in
                openQueue.async {
                    do {
                        var outcome: SZKOutcome?
                        try SZKArchive.createArchive(at: url,
                                                     from: sources,
                                                     options: options,
                                                     progress: progressBridge(isCancelled, onProgress),
                                                     outcome: &outcome)
                        continuation.resume(returning: ArchiveOutcome(outcome ?? SZKOutcome()))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Plumbing

    private func run(_ body: @escaping @Sendable (SZKArchive, SZKProgressHandler?) throws -> SZKOutcome?,
                     onProgress: @escaping @Sendable (ArchiveProgress) -> Void)
        async throws -> ArchiveOutcome {
        try await withTaskCancellationState { isCancelled in
            try await withCheckedThrowingContinuation { continuation in
                // SZKArchive is not Sendable and does not need to be: this
                // queue is serial, so only one operation touches it at a time.
                nonisolated(unsafe) let archive = self.archive
                queue.async {
                    do {
                        let outcome = try body(archive, progressBridge(isCancelled, onProgress))
                        continuation.resume(returning: ArchiveOutcome(outcome ?? SZKOutcome()))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: - Hashing files

public nonisolated extension SevenZip {
    /// Every hash the engine computes, e.g. `CRC32`, `SHA256`, `BLAKE2sp`.
    static var hashMethods: [String] { SZKHasher.methodNames }

    /// Checksums files and folders (recursively) off the caller's thread.
    static func hash(_ urls: [URL], methods: [String],
                     onProgress: ProgressObserver? = nil) async throws -> HashReport {
        try await withTaskCancellationState { isCancelled in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let report = try SZKHasher.hashURLs(urls, methods: methods,
                                                        progress: progressBridge(isCancelled, onProgress))
                        continuation.resume(returning: HashReport(report))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: - Bridging Swift cancellation onto the engine's cooperative checks

/// A flag the engine's progress callback can read from whichever thread it is
/// running on. The engine stops at its next checkpoint, which is what makes
/// cancelling an extraction safe rather than abrupt.
private nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

private nonisolated func withTaskCancellationState<T: Sendable>(
    _ body: (CancellationFlag) async throws -> T) async throws -> T {
    let flag = CancellationFlag()
    return try await withTaskCancellationHandler {
        let result = try await body(flag)
        try Task.checkCancellation()
        return result
    } onCancel: {
        flag.cancel()
    }
}

private nonisolated func progressBridge(_ flag: CancellationFlag,
                            _ observer: (@Sendable (ArchiveProgress) -> Void)?)
    -> SZKProgressHandler {
    { progress in
        if flag.isCancelled { return false }
        observer?(ArchiveProgress(progress))
        return true
    }
}

private nonisolated func bridge(_ provider: @escaping PasswordProvider) -> SZKPasswordProvider {
    { provider() }
}
