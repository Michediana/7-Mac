//
//  JobQueue.swift
//  7-Mac
//
//  The queue, and the logic that actually runs a job.
//
//  Jobs run one at a time on purpose. Compression already saturates every
//  core the machine has, and two extractions racing for the same disk finish
//  later than the same two in sequence — a queue is the honest model, not a
//  limitation to work around.
//

import AppKit
import Foundation
import Observation
import SevenZipKit

nonisolated struct PasswordAnswer: Sendable {
    var password: String
    var remember: Bool
}

/// The parts of a job that need a human. Implemented by `AppModel`, which
/// owns the windows the questions appear in.
@MainActor
protocol JobInteraction: AnyObject {
    func askPassword(for archive: URL, incorrect: Bool) async -> PasswordAnswer?
    /// Presents an open panel and records the grant. `nil` means the user
    /// backed out.
    func askWritableFolder(message: String, suggesting: URL?) async -> URL?
}

@MainActor @Observable
final class JobQueue {
    private(set) var jobs: [Job] = []
    weak var interaction: (any JobInteraction)?

    private let preferences: Preferences
    private var pumping = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Queue

    var runningJob: Job? { jobs.first { $0.state == .running } }
    var waitingCount: Int { jobs.count(where: { $0.state == .waiting }) }
    var hasFinishedJobs: Bool { jobs.contains(where: \.isFinished) }
    var isBusy: Bool { runningJob != nil || waitingCount > 0 }

    @discardableResult
    func enqueue(_ requests: [JobRequest]) -> [Job] {
        let new = requests.map(Job.init)
        jobs.append(contentsOf: new)
        pumpIfNeeded()
        return new
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
    }

    func cancelAll() {
        for job in jobs where !job.isFinished { job.cancel() }
    }

    private func pumpIfNeeded() {
        guard !pumping else { return }
        pumping = true
        Task { @MainActor in
            defer { pumping = false }
            while let next = jobs.first(where: { $0.state == .waiting }) {
                await run(next)
            }
        }
    }

    private func run(_ job: Job) async {
        job.begin()
        // Unstructured on purpose: this is the handle `job.cancel()` pulls,
        // and it must not inherit cancellation from the pump.
        let task = Task { @MainActor in
            do {
                let (outcome, url) = try await perform(job)
                job.finish(outcome, at: url)
                if preferences.revealWhenDone, !job.isTest {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                job.fail(error)
            }
        }
        job.attach(task)
        await task.value
    }

    private func perform(_ job: Job) async throws -> (ArchiveOutcome, URL) {
        switch job.request {
        case .extract(let archive):
            try await extract(archive, for: job)
        case .extractEntries(let selection):
            try await extract(selection, for: job)
        case .compress(let request):
            try await compress(request, for: job)
        case .test(let archive):
            try await test(archive, for: job)
        }
    }

    // MARK: - Extraction

    private func extract(_ archiveURL: URL, for job: Job) async throws -> (ArchiveOutcome, URL) {
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }

        var password = preferences.offersKeychain ? PasswordStore.password(for: archiveURL) : nil
        var remember = false

        // Opening is itself a password step: a 7z with an encrypted header
        // will not even list its entries without one.
        var archive: Archive
        while true {
            do {
                archive = try await Archive.open(archiveURL, password: provider(password))
                break
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: archiveURL, job: job,
                                                     incorrect: password != nil)
                else { throw CancellationError() }
                password = answer.password
                remember = answer.remember
            }
        }

        let base = try await destinationFolder(for: archiveURL, job: job)
        let destination = ArchiveNaming.extractionDestination(entries: archive.entries,
                                                              archive: archiveURL,
                                                              in: base)

        // Ask before starting rather than partway through. Encrypted entries
        // usually sit behind unencrypted ones, and discovering the password
        // problem after writing half the archive is a worse place to be.
        if password == nil,
           archive.hasEncryptedHeader || archive.entries.contains(where: \.isEncrypted) {
            guard let answer = await askPassword(for: archiveURL, job: job, incorrect: false)
            else { throw CancellationError() }
            password = answer.password
            remember = answer.remember
        }

        var retrying = false
        while true {
            do {
                let outcome = try await archive.extract(
                    to: destination,
                    // A retry replaces what the failed attempt already wrote.
                    // With the usual "keep both" policy it would instead leave
                    // a shadow copy of every entry extracted before the
                    // password went wrong.
                    overwrite: retrying ? .overwrite : preferences.overwritePolicy,
                    password: provider(password),
                    onProgress: progressSink(job))
                if remember, let password { PasswordStore.save(password, for: archiveURL) }
                return (outcome, destination)
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: archiveURL, job: job, incorrect: true)
                else { throw CancellationError() }
                password = answer.password
                remember = answer.remember
                retrying = true
                job.restartMeasurement()
            }
        }
    }

    /// Entries a browser picked, from the archive it already has open. No
    /// opening and no destination policy: the browser asked where.
    private func extract(_ selection: EntrySelection,
                         for job: Job) async throws -> (ArchiveOutcome, URL) {
        var folder = selection.destination
        if !FolderAccess.shared.prepare(folder) {
            job.note = String(localized: "Waiting for a destination")
            guard let chosen = await interaction?.askWritableFolder(
                message: String(localized: "7-Mac needs permission to write into “\(folder.lastPathComponent)”. Choose it, or pick somewhere else."),
                suggesting: folder)
            else { throw CancellationError() }
            folder = chosen
            job.note = nil
        }

        // A selection goes straight into the folder, the way a file dragged
        // out of a window would. The whole archive is a drop by another name,
        // and gets a drop's destination.
        let destination = selection.indexes == nil
            ? ArchiveNaming.extractionDestination(entries: selection.archive.entries,
                                                  archive: URL(filePath: selection.archiveName),
                                                  in: folder)
            : folder

        var password = selection.password
        var retrying = false
        while true {
            do {
                let outcome = try await selection.archive.extract(
                    selection.indexes,
                    to: destination,
                    relativeToCommonParent: selection.indexes != nil,
                    overwrite: retrying ? .overwrite : preferences.overwritePolicy,
                    password: provider(password),
                    onProgress: progressSink(job))
                return (outcome, destination)
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: URL(filePath: selection.archiveName), job: job,
                                                     incorrect: password != nil)
                else { throw CancellationError() }
                password = answer.password
                retrying = true
                job.restartMeasurement()
            }
        }
    }

    // MARK: - Testing

    /// Decodes every entry and checksums it as it goes. A damaged entry is a
    /// finding, not a failure: the job finishes and the report says so.
    private func test(_ archiveURL: URL, for job: Job) async throws -> (ArchiveOutcome, URL) {
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }

        var password = preferences.offersKeychain ? PasswordStore.password(for: archiveURL) : nil
        var archive: Archive
        while true {
            do {
                archive = try await Archive.open(archiveURL, password: provider(password))
                break
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: archiveURL, job: job,
                                                     incorrect: password != nil)
                else { throw CancellationError() }
                password = answer.password
            }
        }

        if password == nil, archive.entries.contains(where: \.isEncrypted) {
            guard let answer = await askPassword(for: archiveURL, job: job, incorrect: false)
            else { throw CancellationError() }
            password = answer.password
        }

        while true {
            do {
                let report = try await archive.hash(methods: ["CRC32"], password: provider(password),
                                                    onProgress: progressSink(job))
                let testReport = TestReport(archiveName: archiveURL.lastPathComponent, report: report)
                // A wrong password shows up as every encrypted entry failing
                // its check; that is a question to ask again, not a finding.
                let passwordFailures = report.failures.filter(\.isPasswordProblem)
                if !passwordFailures.isEmpty, passwordFailures.count == report.failures.count {
                    throw NSError(domain: SZKErrorDomain, code: SZKError.Code.passwordWrong.rawValue)
                }
                job.testReport = testReport
                return (ArchiveOutcome(files: report.files, bytes: report.bytes), archiveURL)
            } catch where error.isPasswordProblem {
                guard let answer = await askPassword(for: archiveURL, job: job, incorrect: true)
                else { throw CancellationError() }
                password = answer.password
                job.restartMeasurement()
            }
        }
    }

    // MARK: - Compression

    private func compress(_ request: CompressionRequest,
                          for job: Job) async throws -> (ArchiveOutcome, URL) {
        var scoped: [URL] = []
        for source in request.sources where source.startAccessingSecurityScopedResource() {
            scoped.append(source)
        }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }

        var output = request.output
        let folder = output.deletingLastPathComponent()
        if !FolderAccess.shared.prepare(folder) {
            job.note = String(localized: "Waiting for a destination")
            guard let chosen = await interaction?.askWritableFolder(
                message: String(localized: "Choose where to put \(output.lastPathComponent)."),
                suggesting: folder)
            else { throw CancellationError() }
            output = chosen.appending(component: output.lastPathComponent)
            job.note = nil
        }

        // `create` refuses to write over an existing file, which is the right
        // default for the engine and the wrong one for a queue: two jobs may
        // have picked the same name minutes apart.
        output = ArchiveNaming.unique(output)

        let outcome = try await Archive.create(at: output,
                                               from: request.sources,
                                               format: request.formatName,
                                               level: request.profile.compressionLevel,
                                               password: request.password,
                                               encryptsHeader: request.encryptsHeader,
                                               volumeSize: request.volumeSize,
                                               methodProperties: request.profile.methodProperties,
                                               excluding: request.excludedNames,
                                               storesSymbolicLinks: request.storesSymbolicLinks,
                                               storesHardLinks: request.storesHardLinks,
                                               onProgress: progressSink(job))
        // Split output is `name.7z.001`, `.002`…; the first volume is what
        // to show, and what opens the set.
        if request.volumeSize > 0 {
            let first = output.appendingPathExtension("001")
            if FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) {
                return (outcome, first)
            }
        }
        return (outcome, output)
    }

    // MARK: - Asking

    private func destinationFolder(for archiveURL: URL, job: Job) async throws -> URL {
        let suggestion: URL
        switch preferences.destinationPolicy {
        case .besideArchive:
            suggestion = archiveURL.deletingLastPathComponent()
        case .fixedFolder:
            suggestion = preferences.fixedDestination ?? archiveURL.deletingLastPathComponent()
        case .ask:
            job.note = String(localized: "Waiting for a destination")
            defer { job.note = nil }
            guard let chosen = await interaction?.askWritableFolder(
                message: String(localized: "Choose where to extract \(archiveURL.lastPathComponent)."),
                suggesting: archiveURL.deletingLastPathComponent())
            else { throw CancellationError() }
            return chosen
        }

        if FolderAccess.shared.prepare(suggestion) { return suggestion }

        // Under App Sandbox a dropped file grants access to the file, not to
        // the folder holding it. One panel per folder, then never again.
        job.note = String(localized: "Waiting for a destination")
        defer { job.note = nil }
        guard let chosen = await interaction?.askWritableFolder(
            message: String(localized: "7-Mac needs permission to write into “\(suggestion.lastPathComponent)”. Choose it, or pick somewhere else."),
            suggesting: suggestion)
        else { throw CancellationError() }
        return chosen
    }

    private func askPassword(for archive: URL, job: Job, incorrect: Bool) async -> PasswordAnswer? {
        guard let interaction else { return nil }
        job.note = incorrect ? String(localized: "That password did not work") : String(localized: "Waiting for a password")
        defer { job.note = nil }
        return await interaction.askPassword(for: archive, incorrect: incorrect)
    }

    // MARK: - Progress

    private func progressSink(_ job: Job) -> ProgressObserver {
        let throttle = ProgressThrottle()
        // The engine calls back from its own thread. `Job` is main-actor
        // isolated, so all this closure may do with it is hop back.
        return { progress in
            guard throttle.allow() else { return }
            Task { @MainActor in job.record(progress) }
        }
    }

    private func provider(_ password: String?) -> PasswordProvider? {
        guard let password else { return nil }
        return { password }
    }
}

/// `SetCompleted` fires far more often than a screen refreshes. Dropping the
/// surplus here keeps the main actor out of it entirely.
nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval = 1.0 / 15

    func allow(_ now: Date = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

nonisolated extension Error {
    var isPasswordProblem: Bool {
        sevenZipCode == .passwordRequired || sevenZipCode == .passwordWrong
    }
}
