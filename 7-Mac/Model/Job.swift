//
//  Job.swift
//  7-Mac
//
//  One queued operation and its live state.
//

import Foundation
import Observation
import SevenZipKit

nonisolated struct CompressionRequest: Sendable {
    var sources: [URL]
    var output: URL
    var formatName: String
    var profile: CompressionProfile
    var password: String?
    var encryptsHeader: Bool
    /// Split into volumes of this many bytes; 0 for one file.
    var volumeSize: UInt64 = 0
    var excludedNames: [String] = []
    var storesSymbolicLinks = true
    var storesHardLinks = true
}

/// Entries picked in a browser window, out of an archive it already has
/// open — which may be one nested inside another and have no file of its own
/// to reopen.
nonisolated struct EntrySelection: Sendable {
    var archive: Archive
    /// The archive's name as the browser shows it.
    var archiveName: String
    /// `nil` for everything.
    var indexes: IndexSet?
    /// The folder the entries go into.
    var destination: URL
    var password: String?
    /// What the queue row says.
    var title: String
}

nonisolated enum JobRequest: Sendable {
    case extract(archive: URL)
    case extractEntries(EntrySelection)
    case compress(CompressionRequest)
    /// Decode everything, write nothing, report what was found.
    case test(archive: URL)
}

@MainActor @Observable
final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case running
        case finished
        case failed
        case cancelled
    }

    let id = UUID()
    let request: JobRequest
    /// The archive being read, or the archive being written.
    let title: String

    private(set) var state: State = .waiting
    var totalBytes: UInt64 = 0
    var completedBytes: UInt64 = 0
    var currentPath = ""
    private(set) var bytesPerSecond: Double?
    private(set) var secondsRemaining: TimeInterval?

    /// Set when the job ends: the folder written to, or the archive created.
    var resultURL: URL?
    var outcome: ArchiveOutcome?
    var failure: (any Error)?
    /// Filled in while waiting, e.g. "Asking for a password".
    var note: String?

    private var rate = RateEstimate()
    fileprivate var task: Task<Void, Never>?

    init(_ request: JobRequest) {
        self.request = request
        switch request {
        case .extract(let archive):
            title = archive.lastPathComponent
        case .extractEntries(let selection):
            title = selection.title
        case .compress(let compression):
            title = compression.output.lastPathComponent
        case .test(let archive):
            title = archive.lastPathComponent
        }
    }

    var isExtraction: Bool {
        switch request {
        case .extract, .extractEntries: true
        case .compress, .test:          false
        }
    }

    var isTest: Bool {
        if case .test = request { return true }
        return false
    }

    /// Set when a test finishes, healthy or not.
    var testReport: TestReport?

    /// The archive file a browser can open for this job, if there is one.
    var browsableArchive: URL? {
        switch request {
        case .extract(let archive), .test(let archive): archive
        default:                                         nil
        }
    }

    var isFinished: Bool {
        state == .finished || state == .failed || state == .cancelled
    }

    /// 0…1, or `nil` while the engine has not said how much work there is.
    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    // MARK: - Transitions, all driven by JobQueue

    func begin() {
        state = .running
        note = nil
        rate = RateEstimate()
    }

    func record(_ progress: ArchiveProgress) {
        totalBytes = progress.totalBytes
        completedBytes = progress.completedBytes
        currentPath = progress.currentPath
        rate.record(progress.completedBytes)
        bytesPerSecond = rate.bytesPerSecond
        secondsRemaining = rate.secondsRemaining(completed: completedBytes, total: totalBytes)
    }

    /// A retry — after a wrong password, say — starts the measurement over.
    func restartMeasurement() {
        rate = RateEstimate()
        bytesPerSecond = nil
        secondsRemaining = nil
        completedBytes = 0
    }

    func finish(_ outcome: ArchiveOutcome, at url: URL) {
        self.outcome = outcome
        resultURL = url
        completedBytes = max(completedBytes, totalBytes)
        secondsRemaining = nil
        currentPath = ""
        note = nil
        state = .finished
    }

    func fail(_ error: any Error) {
        if error is CancellationError || error.sevenZipCode == .cancelled {
            state = .cancelled
        } else {
            failure = error
            state = .failed
        }
        secondsRemaining = nil
        currentPath = ""
        note = nil
    }

    func attach(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        switch state {
        case .waiting:
            state = .cancelled
        case .running:
            task?.cancel()
        default:
            break
        }
    }

    // MARK: - What the row says

    var statusLine: String {
        switch state {
        case .waiting:
            return note ?? String(localized: "Waiting")
        case .running:
            if let note { return note }
            var parts: [String] = []
            if totalBytes > 0 {
                parts.append(String(localized: "\(Display.bytes(completedBytes)) of \(Display.bytes(totalBytes))"))
            } else if completedBytes > 0 {
                parts.append(Display.bytes(completedBytes))
            }
            if let bytesPerSecond, bytesPerSecond > 0 {
                parts.append(Display.rate(bytesPerSecond))
            }
            if let secondsRemaining {
                parts.append(Display.remaining(secondsRemaining))
            }
            if parts.isEmpty {
                parts.append(isExtraction || isTest ? String(localized: "Reading the archive") : String(localized: "Scanning"))
            }
            return parts.joined(separator: " · ")
        case .finished:
            if let testReport { return testReport.summary }
            guard let outcome else { return String(localized: "Done") }
            var parts = [Display.count(outcome.files, "file", "files")]
            if outcome.folders > 0 {
                parts.append(Display.count(outcome.folders, "folder", "folders"))
            }
            if isExtraction {
                parts.append(Display.bytes(outcome.bytes))
            } else if outcome.archiveSize > 0 {
                parts.append(Display.bytes(outcome.archiveSize))
            }
            if !outcome.entryErrors.isEmpty {
                parts.append(String(localized: "\(outcome.entryErrors.count) skipped"))
            }
            return parts.joined(separator: " · ")
        case .failed:
            return failure?.archiveDescription ?? String(localized: "Failed")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }
}

nonisolated extension Error {
    /// The engine's own reason where there is one, the system's otherwise.
    ///
    /// Sentence case, not title case: `localizedCapitalized` would turn
    /// "the password is not correct" into a headline.
    var archiveDescription: String {
        guard let code = sevenZipCode else { return localizedDescription }
        let reason = String(describing: code)
        return reason.prefix(1).localizedUppercase + reason.dropFirst()
    }
}
