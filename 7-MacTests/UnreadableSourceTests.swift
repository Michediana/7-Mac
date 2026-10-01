//
//  UnreadableSourceTests.swift
//  7-MacTests
//
//  Compressing something the app may not read — a file without read
//  permission, a folder macOS keeps to itself — skips it and says so. It does
//  not fail the archive that holds everything else.
//

import XCTest
import SevenZipKit
@testable import __Mac

final class UnreadableSourceTests: XCTestCase {
    private var fixtures: Fixtures!
    private var locked: [URL] = []

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        // Or the fixture directory cannot be removed.
        for url in locked {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        fixtures.destroy()
        fixtures = nil
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        locked.append(url)
    }

    func testAnUnreadableFileIsSkippedNotFatal() async throws {
        try await assertSkipsUnreadableFile(format: "7z")
    }

    func testZipSkipsItToo() async throws {
        try await assertSkipsUnreadableFile(format: "zip")
    }

    private func assertSkipsUnreadableFile(format: String) async throws {
        let secret = fixtures.tree.appending(component: "secret.txt")
        try "nobody reads this\n".write(to: secret, atomically: true, encoding: .utf8)
        try lock(secret)

        let archive = fixtures.path("partial.\(format)")
        let outcome = try await Archive.create(at: archive, from: [fixtures.tree], format: format)

        XCTAssertEqual(outcome.entryErrors.count, 1)
        XCTAssertEqual((outcome.entryErrors.first?.userInfo[NSFilePathErrorKey] as? String)
            .map { ($0 as NSString).lastPathComponent }, "secret.txt")
        XCTAssertEqual(outcome.entryErrors.first?.sevenZipCode, .unreadable)

        // Everything else went in. The skipped file is not there at all — not
        // even as an empty stand-in — and is not counted.
        let entries = try await Archive.open(archive).entries
        let names = entries.map(\.path)
        XCTAssertTrue(names.contains { $0.hasSuffix("hello.txt") }, "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix("secret.txt") }, "\(names)")
        XCTAssertEqual(outcome.files, UInt64(entries.filter { !$0.isDirectory }.count))
    }

    func testNothingReadableLeavesNoArchive() async throws {
        let only = fixtures.path("only.txt")
        try "locked\n".write(to: only, atomically: true, encoding: .utf8)
        try lock(only)

        let archive = fixtures.path("empty.7z")
        do {
            try await Archive.create(at: archive, from: [only])
            XCTFail("an archive with nothing in it should be an error")
        } catch {
            XCTAssertEqual(error.sevenZipCode, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testAnUnreadableFolderAmongTheSourcesIsLeftOut() throws {
        let closed = fixtures.path("Closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try lock(closed)

        let (readable, unreadable) = JobQueue.partitionReadable([fixtures.tree, closed])
        XCTAssertEqual(readable, [fixtures.tree])
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.userInfo[NSFilePathErrorKey] as? String,
                       closed.path(percentEncoded: false))
        XCTAssertEqual(unreadable.first?.sevenZipCode, .unreadable)
    }

    func testALinkIsNotFollowedToDecide() throws {
        // The fixture's link.txt points at a relative path that does not
        // resolve from here; it is stored as a link, so it counts as readable.
        let link = fixtures.tree.appending(component: "link.txt")
        XCTAssertEqual(JobQueue.partitionReadable([link]).0, [link])
    }

    @MainActor
    func testTheRowSaysWhatWasSkipped() throws {
        let job = Job(.test(archive: fixtures.path("x.7z")))
        let error = NSError(domain: SZKErrorDomain, code: SZKError.Code.unreadable.rawValue,
                            userInfo: [NSFilePathErrorKey: "/Users/someone/Pictures/Photos Library.photoslibrary"])
        job.begin()
        job.finish(ArchiveOutcome(files: 10, entryErrors: [error]), at: fixtures.path("x.7z"))
        XCTAssertTrue(job.finishedWithSkips)
        XCTAssertTrue(try XCTUnwrap(job.skippedDetail).hasPrefix("Photos Library.photoslibrary: "))
    }
}
