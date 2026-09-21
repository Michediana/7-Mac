//
//  ArchiveTests.swift
//  7-MacTests
//
//  Round trips through the engine: create with our own code, read it back
//  with our own code, and compare against the bytes we started from.
//

import XCTest
import SevenZipKit
@testable import __Mac

final class ArchiveTests: XCTestCase {
    private var fixtures: Fixtures!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        fixtures.destroy()
        fixtures = nil
    }

    // MARK: - Round trips

    func testSevenZipRoundTrip() async throws {
        try await assertRoundTrip(format: "7z", name: "round.7z")
    }

    func testZipRoundTrip() async throws {
        try await assertRoundTrip(format: "zip", name: "round.zip")
    }

    func testTarRoundTrip() async throws {
        try await assertRoundTrip(format: "tar", name: "round.tar")
    }

    /// No explicit format: the engine picks one from the extension.
    func testFormatIsInferredFromTheExtension() async throws {
        let archive = try await assertRoundTrip(format: nil, name: "inferred.7z")
        XCTAssertEqual(archive.formatName, "7z")
    }

    @discardableResult
    private func assertRoundTrip(format: String?, name: String,
                                 password: String? = nil,
                                 encryptsHeader: Bool = false,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async throws -> Archive {
        let archiveURL = fixtures.path(name)
        let created = try await Archive.create(at: archiveURL, from: [fixtures.tree],
                                               format: format, password: password,
                                               encryptsHeader: encryptsHeader)
        XCTAssertGreaterThan(created.archiveSize, 0, "nothing was written", file: file, line: line)
        XCTAssertTrue(created.entryErrors.isEmpty, "\(created.entryErrors)", file: file, line: line)

        let provider: PasswordProvider? = password.map { supplied in { supplied } }
        let archive = try await Archive.open(archiveURL, password: provider)

        let destination = fixtures.path("out-\(name)")
        let outcome = try await archive.extract(to: destination, password: provider)
        XCTAssertTrue(outcome.entryErrors.isEmpty, "\(outcome.entryErrors)", file: file, line: line)

        let problems = Fixtures.differences(between: fixtures.tree,
                                            and: destination.appendingPathComponent("tree"))
        XCTAssertEqual(problems, [], file: file, line: line)
        return archive
    }

    // MARK: - Encryption

    func testEncryptedContentsRoundTrip() async throws {
        try await assertRoundTrip(format: "7z", name: "secret.7z", password: "hunter2")
    }

    func testEncryptedHeaderRoundTrips() async throws {
        let archive = try await assertRoundTrip(format: "7z", name: "header.7z",
                                                password: "hunter2", encryptsHeader: true)
        XCTAssertTrue(archive.hasEncryptedHeader)
    }

    /// With an encrypted header the entry list is unreadable, so opening is
    /// where it fails — not extraction.
    func testEncryptedHeaderCannotEvenBeOpenedWithoutAPassword() async throws {
        let url = fixtures.path("locked.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z",
                                 password: "hunter2", encryptsHeader: true)

        await assertFails(.passwordRequired) { _ = try await Archive.open(url) }
    }

    func testWrongPasswordIsReportedAsSuch() async throws {
        let url = fixtures.path("locked2.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z",
                                 password: "hunter2", encryptsHeader: true)

        await assertFails(.passwordWrong) { _ = try await Archive.open(url, password: { "wrong" }) }
    }

    /// Without header encryption the list is readable, so the wrong password
    /// is only discovered when the data is decoded.
    func testWrongPasswordOnContentsFailsDuringExtraction() async throws {
        let url = fixtures.path("locked3.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z", password: "hunter2")

        let archive = try await Archive.open(url)
        XCTAssertFalse(archive.entries.isEmpty, "the entry list should be readable")
        XCTAssertTrue(archive.entries.contains { $0.isEncrypted })

        await assertFails(.passwordWrong) {
            _ = try await archive.extract(to: self.fixtures.path("nope"), password: { "wrong" })
        }
    }

    // MARK: - Volumes

    func testMultiVolumeArchiveRoundTrips() async throws {
        let url = fixtures.path("split.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z",
                                 level: .store, volumeSize: 100 * 1024)

        let firstVolume = fixtures.path("split.7z.001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstVolume.path),
                      "volumes should be numbered from .001")

        let archive = try await Archive.open(firstVolume)
        XCTAssertGreaterThan(archive.volumeCount, 1)
        XCTAssertEqual(archive.additionalVolumeURLs.count, archive.volumeCount - 1)

        let destination = fixtures.path("out-split")
        try await archive.extract(to: destination)
        XCTAssertEqual(Fixtures.differences(between: fixtures.tree,
                                            and: destination.appendingPathComponent("tree")), [])
    }

    // MARK: - Reading

    func testEntriesCarryTypedProperties() async throws {
        let url = fixtures.path("props.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z")
        let archive = try await Archive.open(url)

        let hello = try XCTUnwrap(archive.entries.first { $0.path.hasSuffix("hello.txt") })
        XCTAssertEqual(hello.uncompressedSize?.intValue, Fixtures.files["hello.txt"]!.utf8.count)
        XCTAssertNotNil(hello.checksum)
        XCTAssertNotNil(hello.modificationDate)
        XCTAssertFalse(hello.isDirectory)
        XCTAssertFalse(hello.isEncrypted)
        XCTAssertEqual(hello.posixPermissions?.intValue, 0o644)

        XCTAssertTrue(archive.entries.contains { $0.isDirectory })
        XCTAssertTrue(archive.entries.contains { $0.isSymbolicLink },
                      "symlinks should be stored as links, not followed")
    }

    /// Paths are not ASCII in the real world.
    func testNonASCIIPathsSurviveTheRoundTrip() async throws {
        let url = fixtures.path("unicode.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z")
        let archive = try await Archive.open(url)
        XCTAssertTrue(archive.entries.contains { $0.path.hasSuffix("unicode-é☃.txt") },
                      "got: \(archive.entries.map(\.path))")
    }

    func testOpeningSomethingThatIsNotAnArchiveFails() async throws {
        let plain = fixtures.path("plain.txt")
        try "not an archive".write(to: plain, atomically: true, encoding: .utf8)
        await assertFails(.notAnArchive) { _ = try await Archive.open(plain) }
    }

    // MARK: - Partial extraction

    /// Selecting by index is the point of embedding the library: one entry out
    /// of a solid block costs one entry, even though the engine has to decode
    /// the block to reach it.
    func testExtractingASingleEntryWritesOnlyThatEntry() async throws {
        let url = fixtures.path("partial.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z")
        let archive = try await Archive.open(url)

        let hello = try XCTUnwrap(archive.entries.first { $0.path.hasSuffix("hello.txt") })
        let destination = fixtures.path("out-partial")
        let outcome = try await archive.extract(IndexSet(integer: Int(hello.index)), to: destination)

        XCTAssertEqual(outcome.files, 1)
        XCTAssertEqual(outcome.bytes, UInt64(Fixtures.files["hello.txt"]!.utf8.count))
        XCTAssertGreaterThan(outcome.processedBytes, outcome.bytes,
                             "a solid block has to be decoded to reach one entry")

        let written = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
            .filter { !$0.hasSuffix("/") }
        XCTAssertEqual(written.sorted(), ["tree", "tree/hello.txt"])
    }

    func testFlatteningDropsTheDirectoryStructure() async throws {
        let url = fixtures.path("flat.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z")
        let archive = try await Archive.open(url)

        let destination = fixtures.path("out-flat")
        try await archive.extract(to: destination, paths: .flatten)

        let nested = destination.appendingPathComponent("nested.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
                      "sub/nested.txt should land at the top level")
    }

    // MARK: - Testing and damage

    func testTestingAGoodArchivePasses() async throws {
        let url = fixtures.path("good.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z")
        let archive = try await Archive.open(url)

        let outcome = try await archive.test()
        XCTAssertTrue(outcome.entryErrors.isEmpty)
        XCTAssertGreaterThan(outcome.bytes, 0)
    }

    func testTestingACorruptedArchiveFails() async throws {
        let url = fixtures.path("broken.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z", level: .store)

        // Flip bytes well past the header so the archive still opens and the
        // damage is only found when the data is read.
        var bytes = try Data(contentsOf: url)
        for offset in 2048..<3072 { bytes[offset] = ~bytes[offset] }
        try bytes.write(to: url)

        let archive = try await Archive.open(url)
        var failed = false
        do {
            _ = try await archive.test()
        } catch {
            failed = true
            XCTAssertEqual(error.sevenZipCode, .damaged, "got \(error)")
        }
        XCTAssertTrue(failed, "corrupted data should not verify")
    }

    // MARK: - Limits we accept

    func testCreatingAZstdArchiveIsRejected() async throws {
        await assertFails(.unsupported) {
            try await Archive.create(at: self.fixtures.path("no.zst"),
                                     from: [self.fixtures.tree], format: "zstd")
        }
    }

    /// gzip, bzip2 and xz hold exactly one stream. Handing them a folder is a
    /// mistake worth catching before the UI offers it.
    func testCreatingAnXzArchiveFromAFolderIsRejected() async throws {
        await assertFails(.unsupported) {
            try await Archive.create(at: self.fixtures.path("no.xz"),
                                     from: [self.fixtures.tree], format: "xz")
        }
    }

    func testCreateRefusesToClobberAnExistingFile() async throws {
        let url = fixtures.path("taken.7z")
        try "already here".write(to: url, atomically: true, encoding: .utf8)
        await assertFails(.failed) {
            try await Archive.create(at: url, from: [self.fixtures.tree], format: "7z")
        }
    }

    // MARK: - Cancellation

    func testCancellingAnExtractionStopsIt() async throws {
        let url = fixtures.path("cancel.7z")
        try await Archive.create(at: url, from: [fixtures.tree], format: "7z", level: .store)
        let archive = try await Archive.open(url)

        let started = expectation(description: "extraction started")
        // Progress fires once per chunk, so the first one is the signal and
        // the rest are noise.
        started.assertForOverFulfill = false
        let task = Task {
            try await archive.extract(to: self.fixtures.path("out-cancel"), onProgress: { _ in
                started.fulfill()
            })
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled extraction should not succeed")
        } catch {
            // Either the engine noticed first or Swift did; both are cancellation.
            XCTAssertTrue(error is CancellationError || error.sevenZipCode == .cancelled,
                          "got \(error)")
        }
    }

    // MARK: - Helpers

    private func assertFails(_ expected: SZKError.Code,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected), but it succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(error.sevenZipCode, expected, "got \(error)", file: file, line: line)
        }
    }
}
