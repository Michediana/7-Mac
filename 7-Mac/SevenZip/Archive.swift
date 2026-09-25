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

    init(_ outcome: SZKOutcome) {
        files = outcome.fileCount
        folders = outcome.folderCount
        bytes = outcome.byteCount
        processedBytes = outcome.processedByteCount
        archiveSize = outcome.archiveSize
        entryErrors = outcome.entryErrors as [NSError]
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

    private init(_ archive: SZKArchive, parent: Archive? = nil) {
        self.archive = archive
        // A nested archive reads through its parent's stream, so the two
        // must never run at once: they share the parent's queue.
        self.queue = parent?.queue
            ?? DispatchQueue(label: "eu.dgnet.7-Mac.archive.\(ObjectIdentifier(archive).hashValue)")
        self.parent = parent
        pathInParent = archive.pathInParent
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
                              onProgress: ProgressObserver? = nil) async throws -> ArchiveOutcome {
        let options = SZKCreateOptions()
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
