//
//  IntegrityTests.swift
//  7-MacTests
//
//  Testing an archive and checksumming files: a healthy archive reported as
//  healthy, a damaged one reported entry by entry, and a pasted checksum
//  found wherever it is.
//

import XCTest
import SevenZipKit
@testable import __Mac

@MainActor
final class IntegrityTests: XCTestCase {
    private var fixtures: Fixtures!
    private var suiteName: String!
    private var suite: UserDefaults!
    private var queue: JobQueue!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        suiteName = "7-MacTests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let preferences = Preferences(defaults: suite)
        preferences.revealWhenDone = false
        preferences.offersKeychain = false
        queue = JobQueue(preferences: preferences)
    }

    override func tearDown() {
        fixtures?.destroy()
        if let suiteName {
            suite?.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
        }
    }

    // MARK: - Testing

    func testAHealthyArchiveReportsEveryFileIntact() async throws {
        let url = fixtures.path("tree.7z")
        try await Archive.create(at: url, from: [fixtures.tree])
        let job = try await run(.test(archive: url))
        let report = try XCTUnwrap(job.testReport)
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.rows.first { $0.path == "tree/hello.txt" }?.checksum, "6C47785C")
        XCTAssertTrue(job.statusLine.hasPrefix("All "), job.statusLine)
        XCTAssertTrue(report.text.contains("OK     6C47785C  tree/hello.txt"), report.text)
    }

    func testADamagedArchiveIsAFindingNotAFailure() async throws {
        let url = fixtures.path("damaged.zip")
        try await Archive.create(at: url, from: [fixtures.tree], format: "zip", level: .store)
        var bytes = try Data(contentsOf: url)
        let range = try XCTUnwrap(bytes.range(of: Data("hello from 7-Mac".utf8)))
        bytes[range.lowerBound] ^= 0xFF
        try bytes.write(to: url)

        let job = try await run(.test(archive: url))
        XCTAssertEqual(job.state, .finished, "the test ran; the archive is what failed")
        let report = try XCTUnwrap(job.testReport)
        XCTAssertFalse(report.isHealthy)
        let damaged = try XCTUnwrap(report.rows.first { $0.path == "tree/hello.txt" })
        XCTAssertNotNil(damaged.problem)
        XCTAssertNil(report.rows.first { $0.path == "tree/sub/nested.txt" }?.problem)
        XCTAssertTrue(report.text.contains("ERROR  tree/hello.txt"), report.text)
    }

    func testTheBrowserTestsJustTheSelection() async throws {
        let url = fixtures.path("tree.zip")
        try await Archive.create(at: url, from: [fixtures.tree])
        let browser = ArchiveBrowser(url: url, preferences: Preferences(defaults: suite), queue: queue)
        await browser.open()
        let sub = try XCTUnwrap(browser.current?.tree.allNodes.first { $0.path == "tree/sub" })
        browser.selection = [sub.id]
        await browser.test()
        let report = try XCTUnwrap(browser.shownTestReport)
        XCTAssertEqual(report.rows.map(\.path), ["tree/sub/nested.txt"])
        browser.close()
    }

    // MARK: - Checksums

    func testAPastedChecksumIsFoundWhateverItsDecoration() async throws {
        let model = ChecksumModel(source: .files([fixtures.tree.appending(component: "hello.txt")]))
        model.methods = ["CRC32", "SHA256"]
        model.run()
        let deadline = Date().addingTimeInterval(30)
        while model.isRunning || model.report == nil {
            if Date() > deadline { XCTFail("no report"); return }
            try await Task.sleep(for: .milliseconds(10))
        }

        let sha = "9c0dcd73470702de299268ab63eb6bdb8f6c7f73f6faae5a3b7f64763060e5a9"
        model.expected = "  SHA256:\(sha.uppercased())  hello.txt\n"
        XCTAssertEqual(model.matches?.map(\.method), ["SHA256"])
        model.expected = "6c47785c"
        XCTAssertEqual(model.matches?.map(\.method), ["CRC32"], "CRC is compared case-insensitively")
        model.expected = "deadbeef"
        XCTAssertEqual(model.matches?.count, 0)
        model.expected = ""
        XCTAssertNil(model.matches)

        let text = ChecksumModel.text(of: try XCTUnwrap(model.report))
        XCTAssertTrue(text.contains("# SHA256\n\(sha)  hello.txt"), text)
    }

    func testTheExportReadsBackWithShasum() {
        // One method, no headers: exactly the `shasum -a 256` format.
        let report = HashReport(methods: ["SHA256"],
                                items: [.init(id: 0, path: "a.txt", isDirectory: false, size: 1, digests: ["ab"]),
                                        .init(id: 1, path: "dir", isDirectory: true, size: 0, digests: [])],
                                dataSums: ["ab"], files: 1, bytes: 1, failures: [])
        XCTAssertEqual(ChecksumModel.text(of: report), "ab  a.txt\n")
    }

    // MARK: - Helpers

    private func run(_ request: JobRequest) async throws -> Job {
        let job = try XCTUnwrap(queue.enqueue([request]).first)
        let deadline = Date().addingTimeInterval(60)
        while !job.isFinished {
            if Date() > deadline { XCTFail("\(job.title) never finished: \(job.statusLine)"); break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return job
    }
}
