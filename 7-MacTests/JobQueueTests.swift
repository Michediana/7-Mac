//
//  JobQueueTests.swift
//  7-MacTests
//
//  The M2 exit criterion, as far as it can be checked without a person:
//  drop in an archive, get its contents back; hand in a folder, get an
//  archive; and every question a job asks gets asked exactly once.
//

import XCTest
import SevenZipKit
@testable import __Mac

@MainActor
final class JobQueueTests: XCTestCase {
    private var fixtures: Fixtures!
    private var preferences: Preferences!
    private var interaction: StubInteraction!
    private var queue: JobQueue!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        // A throwaway suite: a test must not rewrite the preferences of
        // whoever is running it.
        suiteName = "7-MacTests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = Preferences(defaults: suite)
        // Opening a Finder window per assertion is not a test.
        preferences.revealWhenDone = false
        interaction = StubInteraction()
        queue = JobQueue(preferences: preferences)
        queue.interaction = interaction
    }

    override func tearDown() {
        fixtures?.destroy()
        fixtures = nil
        if let suiteName {
            suite?.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
        }
        suite = nil
        queue = nil
    }

    // MARK: - Extraction

    func testExtractionJobRunsAndPutsTheTreeBack() async throws {
        let archive = try await makeArchive()

        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .finished)
        let destination = try XCTUnwrap(job.resultURL)
        XCTAssertEqual(Fixtures.differences(between: fixtures.tree,
                                            and: destination.appendingPathComponent("tree")),
                       [])
        XCTAssertEqual(interaction.passwordAsks, 0, "a plain archive must not ask for anything")
    }

    func testTheQueueRunsJobsInOrderAndOneAtATime() async throws {
        let first = try await makeArchive(named: "first.7z")
        let second = try await makeArchive(named: "second.7z")

        let jobs = queue.enqueue([.extract(archive: first), .extract(archive: second)])
        XCTAssertEqual(jobs.count, 2)
        XCTAssertLessThanOrEqual(queue.jobs.count(where: { $0.state == .running }), 1)

        for job in jobs { try await finish(job) }
        XCTAssertEqual(jobs.map(\.state), [.finished, .finished])
    }

    // MARK: - Passwords

    func testAnEncryptedArchiveIsAskedAboutOnceAndThenExtracted() async throws {
        let archive = try await makeArchive(named: "locked.7z", password: "hunter2")
        interaction.passwords = ["hunter2"]

        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .finished, job.statusLine)
        XCTAssertEqual(interaction.passwordAsks, 1,
                       "the prompt comes before the run, not once per entry")
    }

    /// An encrypted header means the entry list will not even open, so the
    /// question has to come from the open step rather than the extract step.
    func testAnEncryptedHeaderIsAskedAboutAtOpenTime() async throws {
        let archive = try await makeArchive(named: "sealed.7z",
                                            password: "hunter2",
                                            encryptsHeader: true)
        interaction.passwords = ["hunter2"]

        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .finished, job.statusLine)
        XCTAssertEqual(interaction.passwordAsks, 1)
    }

    func testAWrongPasswordIsAskedAgain() async throws {
        let archive = try await makeArchive(named: "locked.7z", password: "hunter2")
        interaction.passwords = ["wrong", "hunter2"]

        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .finished, job.statusLine)
        XCTAssertEqual(interaction.passwordAsks, 2)
    }

    func testDecliningThePasswordCancelsTheJobRatherThanFailingIt() async throws {
        let archive = try await makeArchive(named: "locked.7z", password: "hunter2")
        interaction.passwords = []

        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .cancelled)
        XCTAssertEqual(interaction.passwordAsks, 1)
    }

    // MARK: - Compression

    func testCompressionJobWritesAnArchiveWeCanReadBack() async throws {
        let output = fixtures.path("out/made.7z")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let request = CompressionRequest(sources: [fixtures.tree],
                                         output: output,
                                         formatName: "7z",
                                         profile: .fast,
                                         password: nil,
                                         encryptsHeader: false)

        let job = try XCTUnwrap(queue.enqueue([.compress(request)]).first)
        try await finish(job)

        XCTAssertEqual(job.state, .finished, job.statusLine)
        let written = try XCTUnwrap(job.resultURL)
        let opened = try await Archive.open(written)
        XCTAssertEqual(opened.formatName, "7z")
        XCTAssertTrue(opened.entries.contains { $0.path == "tree/hello.txt" },
                      "got \(opened.entries.map(\.path))")
    }

    /// Two jobs can pick the same name minutes apart; the second one steps
    /// aside rather than failing on `create`'s refusal to overwrite.
    func testASecondArchiveWithTheSameNameStepsAside() async throws {
        let output = fixtures.path("out/made.7z")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let request = CompressionRequest(sources: [fixtures.tree],
                                         output: output,
                                         formatName: "7z",
                                         profile: .fast,
                                         password: nil,
                                         encryptsHeader: false)

        let jobs = queue.enqueue([.compress(request), .compress(request)])
        for job in jobs { try await finish(job) }

        XCTAssertEqual(jobs.map(\.state), [.finished, .finished])
        XCTAssertEqual(jobs[0].resultURL?.lastPathComponent, "made.7z")
        XCTAssertEqual(jobs[1].resultURL?.lastPathComponent, "made 2.7z")
    }

    // MARK: - Cancelling

    func testCancellingAWaitingJobNeverStartsIt() async throws {
        let first = try await makeArchive(named: "first.7z")
        let second = try await makeArchive(named: "second.7z")

        let jobs = queue.enqueue([.extract(archive: first), .extract(archive: second)])
        jobs[1].cancel()
        for job in jobs { try await finish(job) }

        XCTAssertEqual(jobs[0].state, .finished)
        XCTAssertEqual(jobs[1].state, .cancelled)
        XCTAssertNil(jobs[1].resultURL)
    }

    func testClearFinishedLeavesTheRestAlone() async throws {
        let archive = try await makeArchive()
        let job = try XCTUnwrap(queue.enqueue([.extract(archive: archive)]).first)
        try await finish(job)

        XCTAssertTrue(queue.hasFinishedJobs)
        queue.clearFinished()
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertFalse(queue.hasFinishedJobs)
    }

    // MARK: - Helpers

    private func makeArchive(named name: String = "source.7z",
                             password: String? = nil,
                             encryptsHeader: Bool = false) async throws -> URL {
        let box = fixtures.path("box-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let archive = box.appendingPathComponent(name)
        try await Archive.create(at: archive,
                                 from: [fixtures.tree],
                                 password: password,
                                 encryptsHeader: encryptsHeader)
        return archive
    }

    /// Waits for the queue to be done with `job`.
    private func finish(_ job: Job, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !job.isFinished {
            if Date() > deadline { XCTFail("\(job.title) never finished: \(job.statusLine)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class StubInteraction: JobInteraction {
    /// Handed out in order; running out means the person gave up.
    var passwords: [String] = []
    var folder: URL?
    private(set) var passwordAsks = 0
    private(set) var folderAsks = 0

    func askPassword(for archive: URL, incorrect: Bool) async -> PasswordAnswer? {
        passwordAsks += 1
        guard !passwords.isEmpty else { return nil }
        return PasswordAnswer(password: passwords.removeFirst(), remember: false)
    }

    func askWritableFolder(message: String, suggesting: URL?) async -> URL? {
        folderAsks += 1
        return folder
    }
}
