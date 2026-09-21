//
//  AppLogicTests.swift
//  7-MacTests
//
//  M2's decisions, the ones that have a right answer: where an extraction
//  lands, what a new archive is called, and how fast the engine is going.
//

import XCTest
import SevenZipKit
@testable import __Mac

final class ArchiveNamingTests: XCTestCase {
    private var fixtures: Fixtures!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        fixtures?.destroy()
        fixtures = nil
    }

    // MARK: - Stems

    func testStemStripsOneArchiveExtension() {
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/report.7z")), "report")
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/report.zip")), "report")
    }

    func testStemStripsCompoundExtensions() {
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/site.tar.gz")), "site")
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/site.tar.xz")), "site")
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/site.tgz")), "site")
    }

    func testStemLeavesNamesThatOnlyLookLikeExtensions() {
        // `2026` is not a format, so the dot is part of the name.
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/notes.2026.zip")), "notes.2026")
        XCTAssertEqual(ArchiveNaming.stem(of: URL(filePath: "/a/plain")), "plain")
    }

    // MARK: - Drop classification

    func testDropTreatsArchivesAsExtractable() throws {
        let archive = fixtures.path("thing.7z")
        try Data().write(to: archive)
        XCTAssertTrue(ArchiveNaming.looksLikeArchive(archive))
    }

    func testDropDoesNotTreatFoldersOrPlainFilesAsArchives() throws {
        XCTAssertFalse(ArchiveNaming.looksLikeArchive(fixtures.tree))
        let document = fixtures.tree.appendingPathComponent("hello.txt")
        XCTAssertFalse(ArchiveNaming.looksLikeArchive(document))
    }

    func testDropIgnoresTheFormatsTheEngineClaimsButNobodyMeans() throws {
        // The engine really can open a PE image, and offering to unpack one
        // because it was dragged in would be a bad guess.
        let executable = fixtures.path("tool.exe")
        try Data().write(to: executable)
        XCTAssertTrue(ArchiveNaming.engineExtensions.contains("exe"),
                      "the engine is expected to claim .exe; if it stopped, this test is moot")
        XCTAssertFalse(ArchiveNaming.looksLikeArchive(executable))
    }

    // MARK: - Unique names

    func testUniqueLeavesAFreeNameAlone() {
        let free = fixtures.path("nothing-here")
        XCTAssertEqual(ArchiveNaming.unique(free), free)
    }

    func testUniqueStepsAsideForWhatIsAlreadyThere() throws {
        let taken = fixtures.path("taken.7z")
        try Data().write(to: taken)
        XCTAssertEqual(ArchiveNaming.unique(taken).lastPathComponent, "taken 2.7z")

        try Data().write(to: fixtures.path("taken 2.7z"))
        XCTAssertEqual(ArchiveNaming.unique(taken).lastPathComponent, "taken 3.7z")
    }

    // MARK: - Where an extraction lands

    /// One top-level folder unpacks in place: wrapping `tree/` in a folder
    /// called `tree` is the double folder everyone complains about.
    func testSingleRootedArchiveUnpacksInPlace() async throws {
        let archive = fixtures.path("tree.7z")
        try await Archive.create(at: archive, from: [fixtures.tree])
        let opened = try await Archive.open(archive)

        let base = fixtures.path("landing")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        XCTAssertEqual(ArchiveNaming.extractionDestination(entries: opened.entries,
                                                            archive: archive,
                                                            in: base),
                       base)
    }

    /// …unless the name is taken, in which case merging silently would be
    /// the wrong kind of helpful.
    func testSingleRootedArchiveMakesItsOwnFolderWhenTheNameIsTaken() async throws {
        let archive = fixtures.path("tree.7z")
        try await Archive.create(at: archive, from: [fixtures.tree])
        let opened = try await Archive.open(archive)

        let base = fixtures.path("landing")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("tree"),
                                                withIntermediateDirectories: true)

        // Named after the archive, and stepped aside from the folder that is
        // already there.
        XCTAssertEqual(ArchiveNaming.extractionDestination(entries: opened.entries,
                                                            archive: archive,
                                                            in: base).lastPathComponent,
                       "tree 2")
    }

    /// A tarbomb gets a folder, so it cannot scatter over the Desktop.
    func testMultiRootedArchiveGetsAFolderNamedAfterItself() async throws {
        let archive = fixtures.path("loose.7z")
        let sources = [
            fixtures.tree.appendingPathComponent("hello.txt"),
            fixtures.tree.appendingPathComponent("blob.bin"),
        ]
        try await Archive.create(at: archive, from: sources)
        let opened = try await Archive.open(archive)

        let base = fixtures.path("landing")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        XCTAssertEqual(ArchiveNaming.extractionDestination(entries: opened.entries,
                                                            archive: archive,
                                                            in: base),
                       base.appendingPathComponent("loose"))
    }

    // MARK: - Common parent

    func testCommonParentOfASelectionInOneFolder() {
        let parent = ArchiveNaming.commonParent(of: [
            URL(filePath: "/Users/x/Documents/a.txt"),
            URL(filePath: "/Users/x/Documents/b.txt"),
        ])
        XCTAssertEqual(parent?.path(percentEncoded: false), "/Users/x/Documents/")
    }

    func testCommonParentOfAScatteredSelectionClimbs() {
        let parent = ArchiveNaming.commonParent(of: [
            URL(filePath: "/Users/x/Documents/a.txt"),
            URL(filePath: "/Users/x/Downloads/b.txt"),
        ])
        XCTAssertEqual(parent?.path(percentEncoded: false), "/Users/x/")
    }
}

final class RateEstimateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNoEstimateFromASingleSample() {
        var rate = RateEstimate()
        rate.record(0, at: start)
        XCTAssertNil(rate.bytesPerSecond)
        XCTAssertNil(rate.secondsRemaining(completed: 0, total: 100))
    }

    func testSteadyThroughputConverges() {
        var rate = RateEstimate()
        // 1 MB every second.
        for second in 0...20 {
            rate.record(UInt64(second) * 1_000_000, at: start.addingTimeInterval(Double(second)))
        }
        let measured = try? XCTUnwrap(rate.bytesPerSecond)
        XCTAssertEqual(measured ?? 0, 1_000_000, accuracy: 20_000)
    }

    func testTimeRemainingFollowsTheRate() {
        var rate = RateEstimate()
        for second in 0...20 {
            rate.record(UInt64(second) * 1_000_000, at: start.addingTimeInterval(Double(second)))
        }
        let remaining = rate.secondsRemaining(completed: 20_000_000, total: 30_000_000)
        XCTAssertEqual(try XCTUnwrap(remaining), 10, accuracy: 0.5)
    }

    /// Samples taken microseconds apart measure the scheduler, not the disk.
    func testSamplesTooCloseTogetherAreIgnored() {
        var rate = RateEstimate()
        rate.record(0, at: start)
        rate.record(1_000_000, at: start.addingTimeInterval(0.001))
        XCTAssertNil(rate.bytesPerSecond, "a 1 ms window must not become 1 GB/s")
    }

    /// A retry after a wrong password rewinds the byte count; the old average
    /// describes a run that is no longer happening.
    func testRewindingTheCounterDropsTheEstimate() {
        var rate = RateEstimate()
        for second in 0...10 {
            rate.record(UInt64(second) * 1_000_000, at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertNotNil(rate.bytesPerSecond)
        rate.record(0, at: start.addingTimeInterval(11))
        XCTAssertNil(rate.bytesPerSecond)
    }
}

@MainActor
final class CompressionDraftTests: XCTestCase {
    private var fixtures: Fixtures!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        fixtures?.destroy()
        fixtures = nil
    }

    /// gzip, bzip2 and xz hold exactly one member; the engine answers
    /// `SZKErrorUnsupported` for a folder, so they are not offered for one.
    func testSingleMemberFormatsAreOnlyOfferedForASingleFile() {
        let file = fixtures.tree.appendingPathComponent("hello.txt")
        XCTAssertTrue(CompressionDraft.formats(for: [file]).contains("gzip"))
        XCTAssertFalse(CompressionDraft.formats(for: [fixtures.tree]).contains("gzip"))
        XCTAssertFalse(CompressionDraft.formats(for: [fixtures.tree]).contains("xz"))
    }

    func testEveryOfferedFormatIsOneTheEngineCanActuallyWrite() {
        let writable = Set(SevenZip.writableFormats.map(\.name))
        for name in CompressionDraft.formats(for: [fixtures.tree]) {
            XCTAssertTrue(writable.contains(name), "\(name) is not writable")
        }
        // The roadmap's standing limit, checked from the UI's side too.
        XCTAssertFalse(CompressionDraft.formats(for: [fixtures.tree]).contains("zstd"))
    }

    func testChangingTheFormatRenamesTheOutput() {
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: Preferences())
        draft.formatName = "zip"
        draft.formatChanged()
        XCTAssertEqual(draft.output.pathExtension, "zip")
        XCTAssertEqual(ArchiveNaming.stem(of: draft.output), "tree")
    }

    func testOnly7zAndZipTakeAPassword() {
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: Preferences())
        draft.formatName = "7z"
        XCTAssertTrue(draft.supportsPassword)
        XCTAssertTrue(draft.supportsHeaderEncryption)
        draft.formatName = "zip"
        XCTAssertTrue(draft.supportsPassword)
        XCTAssertFalse(draft.supportsHeaderEncryption, "only 7z hides the entry list")
        draft.formatName = "tar"
        XCTAssertFalse(draft.supportsPassword)
    }

    /// Switching away from 7z must not leave a header-encryption flag behind
    /// for a format that cannot honour it.
    func testChangingFormatClearsSettingsTheNewFormatCannotHonour() {
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: Preferences())
        draft.formatName = "7z"
        draft.password = "secret"
        draft.encryptsHeader = true
        draft.formatName = "tar"
        draft.formatChanged()
        XCTAssertTrue(draft.password.isEmpty)
        XCTAssertFalse(draft.encryptsHeader)
        XCTAssertNil(draft.request.password)
    }

    func testASingleSelectionIsNamedAfterItself() {
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: Preferences())
        XCTAssertEqual(ArchiveNaming.stem(of: draft.output), "tree")
    }

    func testAMultipleSelectionIsCalledArchive() {
        let sources = [
            fixtures.tree.appendingPathComponent("hello.txt"),
            fixtures.tree.appendingPathComponent("blob.bin"),
        ]
        let draft = CompressionDraft(sources: sources, preferences: Preferences())
        XCTAssertEqual(ArchiveNaming.stem(of: draft.output), "Archive")
        XCTAssertEqual(draft.output.deletingLastPathComponent().path(percentEncoded: false),
                       fixtures.tree.path(percentEncoded: false) + "/")
    }
}

final class DroppedItemsTests: XCTestCase {
    private var fixtures: Fixtures!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        fixtures?.destroy()
        fixtures = nil
    }

    func testProvidersResolveToFileURLsInOrder() async throws {
        let first = fixtures.tree.appendingPathComponent("hello.txt")
        let second = fixtures.tree.appendingPathComponent("blob.bin")
        let providers = [first, second].map { NSItemProvider(contentsOf: $0) }.compactMap { $0 }
        XCTAssertEqual(providers.count, 2)

        let resolved = await fileURLs(from: providers)
        XCTAssertEqual(resolved.map(\.lastPathComponent), ["hello.txt", "blob.bin"])
    }

    /// A drag of plain text carries no file, and must not become a job.
    func testNonFileProvidersAreIgnored() async throws {
        let text = NSItemProvider(object: "just some text" as NSString)
        let file = try XCTUnwrap(NSItemProvider(
            contentsOf: fixtures.tree.appendingPathComponent("hello.txt")))

        let resolved = await fileURLs(from: [text, file])
        XCTAssertEqual(resolved.map(\.lastPathComponent), ["hello.txt"])
    }

    func testAFolderDropIsAFileURLToo() async throws {
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: fixtures.tree))
        let resolved = await fileURLs(from: [provider])
        XCTAssertEqual(resolved.map(\.lastPathComponent), ["tree"])
    }
}
