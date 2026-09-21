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
    var preset: CompressionPreset
    var password: String?
    var encryptsHeader: Bool
}

nonisolated enum JobRequest: Sendable {
    case extract(archive: URL)
    case compress(CompressionRequest)
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
        case .compress(let compression):
            title = compression.output.lastPathComponent
        }
    }

    var isExtraction: Bool {
        if case .extract = request { return true }
        return false
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
            return note ?? "Waiting"
        case .running:
            if let note { return note }
            var parts: [String] = []
            if totalBytes > 0 {
                parts.append("\(Display.bytes(completedBytes)) of \(Display.bytes(totalBytes))")
            } else if completedBytes > 0 {
                parts.append(Display.bytes(completedBytes))
            }
            if let bytesPerSecond, bytesPerSecond > 0 {
                parts.append(Display.rate(bytesPerSecond))
            }
            if let secondsRemaining {
                parts.append(Display.remaining(secondsRemaining))
            }
            if parts.isEmpty { parts.append(isExtraction ? "Reading the archive" : "Scanning") }
            return parts.joined(separator: " · ")
        case .finished:
            guard let outcome else { return "Done" }
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
                parts.append("\(outcome.entryErrors.count) skipped")
            }
            return parts.joined(separator: " · ")
        case .failed:
            return failure?.archiveDescription ?? "Failed"
        case .cancelled:
            return "Cancelled"
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
