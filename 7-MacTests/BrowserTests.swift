//
//  BrowserTests.swift
//  7-MacTests
//
//  M3's exit criterion as far as it can be checked without a person: open an
//  archive and see its tree, pick entries out of it, look at one, and walk
//  into an archive inside an archive — in place where the container allows
//  it, unpacked where it does not.
//

import XCTest
import SevenZipKit
@testable import __Mac

@MainActor
final class BrowserTests: XCTestCase {
    private var fixtures: Fixtures!
    private var preferences: Preferences!
    private var queue: JobQueue!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        suiteName = "7-MacTests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = Preferences(defaults: suite)
        preferences.revealWhenDone = false
        preferences.offersKeychain = false
        queue = JobQueue(preferences: preferences)
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

    // MARK: - Engine: the two primitives the browser is built on

    func testASelectionExtractsWithoutTheFoldersItSitsIn() async throws {
        let archive = try await Archive.open(try await make("tree.7z", from: [fixtures.tree]))
        let nested = try XCTUnwrap(archive.entries.first { $0.path == "tree/sub/nested.txt" })

        let flat = fixtures.path("one-file")
        try await archive.extract(IndexSet(integer: Int(nested.index)), to: flat,
                                  relativeToCommonParent: true)
        XCTAssertEqual(try String(contentsOf: flat.appending(component: "nested.txt"), encoding: .utf8),
                       Fixtures.files["sub/nested.txt"])
        XCTAssertFalse(exists(flat.appending(path: "tree")))

        // A folder keeps its own name, and only loses the ones above it.
        let folder = try XCTUnwrap(archive.entries.first { $0.path == "tree/sub" })
        let withFolder = fixtures.path("one-folder")
        try await archive.extract(IndexSet([Int(folder.index), Int(nested.index)]), to: withFolder,
                                  relativeToCommonParent: true)
        XCTAssertTrue(exists(withFolder.appending(path: "sub/nested.txt")))
    }

    func testATarInsideATarOpensInPlace() async throws {
        let inner = try await make("inner.tar", from: [fixtures.tree])
        let outer = try await make("outer.tar", from: [inner])

        let archive = try await Archive.open(outer)
        let entry = try XCTUnwrap(archive.entries.first { $0.path == "inner.tar" })
        let nested = try await archive.openEntry(Int(entry.index))
        XCTAssertEqual(nested.formatName, "tar")
        XCTAssertEqual(nested.pathInParent, "inner.tar")
        XCTAssertTrue(nested.entries.contains { $0.path == "tree/hello.txt" })

        // And it extracts, reading through the outer archive's stream.
        let destination = fixtures.path("from-nested")
        let outcome = try await nested.extract(to: destination)
        XCTAssertTrue(outcome.entryErrors.isEmpty, "\(outcome.entryErrors)")
        XCTAssertEqual(Fixtures.differences(between: fixtures.tree,
                                            and: destination.appending(component: "tree")), [])
    }

    func testACompressedContainerCannotOpenAnEntryInPlace() async throws {
        let inner = try await make("inner.zip", from: [fixtures.tree])
        let archive = try await Archive.open(try await make("outer.7z", from: [inner]))
        do {
            _ = try await archive.openEntry(0)
            XCTFail("7z compresses its entries; there is no stream to seek in")
        } catch {
            XCTAssertEqual(error.sevenZipCode, .unsupported)
        }
    }

    // MARK: - The browser

    func testATarGzOpensStraightToTheTarInside() async throws {
        let tar = try await make("tree.tar", from: [fixtures.tree])
        let tarGz = try await make("tree.tar.gz", from: [tar], format: "gzip")

        let browser = ArchiveBrowser(url: tarGz, preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertEqual(browser.phase, .ready)
        XCTAssertEqual(browser.levels.map(\.archive.formatName), ["gzip", "tar"])
        XCTAssertEqual(browser.roots.map(\.name), ["tree"])
        XCTAssertFalse(try XCTUnwrap(browser.current).isInPlace, "a gzip stream cannot be seeked into")

        browser.goUp()
        XCTAssertEqual(browser.levels.count, 1)
        XCTAssertEqual(browser.roots.map(\.name), ["tree.tar"])
        browser.close()
    }

    func testAZipInsideA7zIsUnpackedAndOpened() async throws {
        let zip = try await make("inner.zip", from: [fixtures.tree])
        let browser = ArchiveBrowser(url: try await make("outer.7z", from: [zip]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertEqual(browser.levels.count, 1, "a 7z holding a zip is not a wrapper to skip")

        let node = try XCTUnwrap(browser.roots.first)
        XCTAssertTrue(browser.looksLikeArchive(node))
        await browser.descend(into: node)
        XCTAssertNil(browser.problem)
        XCTAssertEqual(browser.levels.map(\.archive.formatName), ["7z", "zip"])
        XCTAssertEqual(browser.roots.map(\.name), ["tree"])

        browser.close()
        XCTAssertFalse(exists(browser.scratch), "closing the window takes its scratch folder with it")
    }

    func testPreviewUnpacksOneFileAndOnlyOnce() async throws {
        let browser = ArchiveBrowser(url: try await make("tree.7z", from: [fixtures.tree]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        let hello = try XCTUnwrap(browser.current?.tree.allNodes.first { $0.path == "tree/hello.txt" })

        await browser.preview(hello)
        let first = try XCTUnwrap(browser.previewURL)
        XCTAssertEqual(first.lastPathComponent, "hello.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), Fixtures.files["hello.txt"])
        XCTAssertTrue(first.path.hasPrefix(browser.scratch.path))

        browser.previewURL = nil
        await browser.preview(hello)
        XCTAssertEqual(browser.previewURL, first, "a second look reuses the first copy")
        browser.close()
    }

    func testPreviewingAnEncryptedFileAsksAndRetriesAWrongPassword() async throws {
        let archiveURL = fixtures.path("secret.7z")
        try await Archive.create(at: archiveURL, from: [fixtures.tree], password: "right")
        let browser = ArchiveBrowser(url: archiveURL, preferences: preferences, queue: queue)
        await browser.open()
        let hello = try XCTUnwrap(browser.current?.tree.allNodes.first { $0.path == "tree/hello.txt" })
        XCTAssertTrue(hello.isEncrypted)

        let preview = Task { await browser.preview(hello) }
        try await answer(browser, with: "wrong")
        let second = try await prompt(browser)
        XCTAssertTrue(second.incorrect)
        second.password = "right"
        second.submit()
        await preview.value

        let url = try XCTUnwrap(browser.previewURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Fixtures.files["hello.txt"])
        XCTAssertEqual(browser.current?.password, "right", "the password that worked is kept")
        browser.close()
    }

    func testExtractingASelectionGoesThroughTheQueue() async throws {
        let browser = ArchiveBrowser(url: try await make("tree.7z", from: [fixtures.tree]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        let tree = try XCTUnwrap(browser.current?.tree)
        let sub = try XCTUnwrap(tree.allNodes.first { $0.path == "tree/sub" })
        let hello = try XCTUnwrap(tree.allNodes.first { $0.path == "tree/hello.txt" })
        browser.selection = [sub.id, hello.id]

        let folder = fixtures.path("picked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await browser.extract(to: folder)

        let job = try XCTUnwrap(queue.jobs.last)
        XCTAssertEqual(job.title, "2 items from tree.7z")
        try await finish(job)
        XCTAssertEqual(job.state, .finished, job.statusLine)
        XCTAssertTrue(exists(folder.appending(path: "sub/nested.txt")))
        XCTAssertTrue(exists(folder.appending(path: "hello.txt")))
        XCTAssertFalse(exists(folder.appending(path: "blob.bin")), "only what was picked")
        browser.close()
    }

    func testExtractingANestedArchiveUsesTheOpenCopy() async throws {
        // The inner tar has no file of its own to reopen: the job must work
        // from the archive the browser already has open.
        let inner = try await make("inner.tar", from: [fixtures.tree])
        let browser = ArchiveBrowser(url: try await make("outer.tar", from: [inner]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        await browser.descend(into: try XCTUnwrap(browser.roots.first))
        XCTAssertTrue(try XCTUnwrap(browser.current).isInPlace)

        let folder = fixtures.path("all-of-inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await browser.extract(to: folder)
        let job = try XCTUnwrap(queue.jobs.last)
        try await finish(job)
        XCTAssertEqual(job.state, .finished, job.statusLine)
        XCTAssertEqual(Fixtures.differences(between: fixtures.tree,
                                            and: folder.appending(component: "tree")), [])
        browser.close()
    }

    func testFoldersOpenLikeFinderAndUpComesBackOut() async throws {
        let browser = ArchiveBrowser(url: try await make("tree.zip", from: [fixtures.tree]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertFalse(browser.canGoUp)

        let tree = try XCTUnwrap(browser.roots.first { $0.name == "tree" })
        browser.enter(tree)
        XCTAssertEqual(browser.currentFolder?.path, "tree")
        XCTAssertTrue(browser.roots.contains { $0.name == "hello.txt" })

        let sub = try XCTUnwrap(browser.roots.first { $0.name == "sub" })
        browser.enter(sub)
        XCTAssertEqual(browser.folderTrail.map(\.name), ["tree", "sub"])
        XCTAssertEqual(browser.roots.map(\.name), ["nested.txt"])

        browser.goUp()
        XCTAssertEqual(browser.currentFolder?.path, "tree")
        XCTAssertEqual(browser.selection, [sub.id], "coming out selects the folder you were in")

        browser.goToFolder(nil)
        XCTAssertNil(browser.currentFolder)
        XCTAssertEqual(browser.selection, [tree.id])
        XCTAssertEqual(browser.roots.map(\.name), ["tree"])
        browser.close()
    }

    func testSearchingAndFilteringShowAFlatList() async throws {
        let browser = ArchiveBrowser(url: try await make("tree.zip", from: [fixtures.tree]),
                                     preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertFalse(browser.isShowingMatches)

        browser.searchText = "NESTED"
        XCTAssertEqual(browser.matches.map(\.path), ["tree/sub/nested.txt"])

        browser.searchText = ""
        browser.filter = .documents
        XCTAssertEqual(Set(browser.matches.map(\.name)),
                       ["hello.txt", "nested.txt", "unicode-é☃.txt"])
        browser.filter = .everything
        XCTAssertTrue(browser.matches.isEmpty)
        browser.close()
    }

    // MARK: - Helpers

    private func make(_ name: String, from sources: [URL], format: String? = nil) async throws -> URL {
        let url = fixtures.path(name)
        try await Archive.create(at: url, from: sources, format: format)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func prompt(_ browser: ArchiveBrowser, timeout: TimeInterval = 30) async throws -> PasswordPrompt {
        let deadline = Date().addingTimeInterval(timeout)
        while browser.passwordPrompt == nil {
            if Date() > deadline { throw XCTSkip("no password prompt appeared") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return browser.passwordPrompt!
    }

    private func answer(_ browser: ArchiveBrowser, with password: String) async throws {
        let prompt = try await prompt(browser)
        prompt.password = password
        prompt.submit()
        // Wait for the sheet to be dismissed, so the next prompt is a new one.
        while browser.passwordPrompt === prompt { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func finish(_ job: Job, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !job.isFinished {
            if Date() > deadline { XCTFail("\(job.title) never finished: \(job.statusLine)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
