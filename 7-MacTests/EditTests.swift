//
//  EditTests.swift
//  7-MacTests
//
//  M4: an archive changed in place — entries deleted, renamed, added — and
//  every change undoable. What matters each time is that the entries nobody
//  touched come back byte for byte, and that a change that fails leaves the
//  file exactly as it was.
//

import XCTest
import SevenZipKit
@testable import __Mac

@MainActor
final class EditTests: XCTestCase {
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

    // MARK: - Delete

    func testDeletingAFileLeavesEverythingElseIntact() async throws {
        let browser = try await open(try await make("tree.7z"))
        await browser.delete([try node(browser, "tree/blob.bin").id])
        XCTAssertNil(browser.problem)

        let paths = try await paths(in: browser.url)
        XCTAssertFalse(paths.contains("tree/blob.bin"))
        XCTAssertTrue(paths.contains("tree/sub/nested.txt"))
        try await assertContents(of: browser.url, match: ["hello.txt", "sub/nested.txt", "unicode-é☃.txt"])
        XCTAssertEqual(browser.roots.first?.children.contains { $0.name == "blob.bin" }, false,
                       "the browser shows the new archive")
        browser.close()
    }

    func testDeletingAFolderTakesItsContentsWithIt() async throws {
        let browser = try await open(try await make("tree.zip"))
        await browser.delete([try node(browser, "tree/sub").id])
        let paths = try await paths(in: browser.url)
        XCTAssertFalse(paths.contains { $0.hasPrefix("tree/sub") }, "\(paths)")
        XCTAssertTrue(paths.contains("tree/hello.txt"))
        browser.close()
    }

    // MARK: - Rename

    func testRenamingAFileKeepsItsContents() async throws {
        let browser = try await open(try await make("tree.7z"))
        let hello = try node(browser, "tree/hello.txt")
        XCTAssertNil(browser.validateNewName("greeting.txt", for: hello))
        await browser.rename(hello, to: "greeting.txt")
        XCTAssertNil(browser.problem)

        let archive = try await Archive.open(browser.url)
        XCTAssertFalse(archive.entries.contains { $0.path == "tree/hello.txt" })
        let destination = fixtures.path("renamed")
        try await archive.extract(to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "tree/greeting.txt"), encoding: .utf8),
                       Fixtures.files["hello.txt"])
        browser.close()
    }

    func testRenamingAFolderRenamesEverythingUnderIt() async throws {
        let browser = try await open(try await make("tree.tar"))
        await browser.rename(try node(browser, "tree/sub"), to: "moved")
        let paths = try await paths(in: browser.url)
        XCTAssertTrue(paths.contains("tree/moved/nested.txt"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("tree/sub") })
        browser.close()
    }

    func testANameThatIsTakenOrMalformedIsRefused() async throws {
        let browser = try await open(try await make("tree.zip"))
        let hello = try node(browser, "tree/hello.txt")
        XCTAssertNotNil(browser.validateNewName("blob.bin", for: hello), "a sibling has it")
        XCTAssertNotNil(browser.validateNewName("a/b", for: hello))
        XCTAssertNotNil(browser.validateNewName("  ", for: hello))
        XCTAssertNil(browser.validateNewName("hello.txt", for: hello), "its own name is fine")
        browser.close()
    }

    // MARK: - Add

    func testAddingFilesPutsThemInTheChosenFolder() async throws {
        let browser = try await open(try await make("tree.7z"))
        let extra = fixtures.path("extra.txt")
        try "added later\n".write(to: extra, atomically: true, encoding: .utf8)

        await browser.add([extra], into: try node(browser, "tree/sub"))
        XCTAssertNil(browser.problem)
        let archive = try await Archive.open(browser.url)
        XCTAssertTrue(archive.entries.contains { $0.path == "tree/sub/extra.txt" })

        let destination = fixtures.path("with-extra")
        try await archive.extract(to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "tree/sub/extra.txt"), encoding: .utf8),
                       "added later\n")
        XCTAssertEqual(Fixtures.differences(between: fixtures.tree,
                                            and: destination.appending(component: "tree")), [],
                       "nothing that was there already changed")
        browser.close()
    }

    func testOnlyReplacingOlderLeavesANewerEntryAlone() async throws {
        let browser = try await open(try await make("tree.zip"))
        // A file of the same name as an entry, but dated before it.
        let stale = fixtures.path("disk/hello.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "stale\n".write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: stale.path)

        preferences.onlyReplaceOlder = true
        await browser.add([stale], into: try node(browser, "tree"))
        let kept = try await text(of: "tree/hello.txt", in: browser.url)
        XCTAssertEqual(kept, Fixtures.files["hello.txt"])

        preferences.onlyReplaceOlder = false
        await browser.add([stale], into: try node(browser, "tree"))
        let replaced = try await text(of: "tree/hello.txt", in: browser.url)
        XCTAssertEqual(replaced, "stale\n")
        browser.close()
    }

    func testAddingToAnEncryptedArchiveEncryptsTheNewEntryToo() async throws {
        let url = fixtures.path("secret.7z")
        try await Archive.create(at: url, from: [fixtures.tree], password: "pw", encryptsHeader: true)
        let browser = ArchiveBrowser(url: url, preferences: preferences, queue: queue)
        let opening = Task { await browser.open() }
        try await answer(browser, "pw")
        await opening.value
        XCTAssertEqual(browser.phase, .ready)

        let extra = fixtures.path("extra.txt")
        try "secret too\n".write(to: extra, atomically: true, encoding: .utf8)
        await browser.add([extra], into: nil)
        XCTAssertNil(browser.problem)

        do {
            _ = try await Archive.open(url)
            XCTFail("the entry list should still be encrypted")
        } catch {
            XCTAssertEqual(error.sevenZipCode, .passwordRequired)
        }
        let reopened = try await Archive.open(url, password: { "pw" })
        let added = try XCTUnwrap(reopened.entries.first { $0.path == "extra.txt" })
        XCTAssertTrue(added.isEncrypted)
        browser.close()
    }

    func testDeletingFromASolidEncryptedArchiveAsksForThePassword() async throws {
        // Contents encrypted, entry list not: the archive opens without a
        // password, but taking one file out of a solid block means decoding
        // and re-encoding the rest of it.
        let url = fixtures.path("solid-secret.7z")
        try await Archive.create(at: url, from: [fixtures.tree], password: "pw")
        let browser = try await open(url)
        XCTAssertNil(browser.current?.password)

        let hello = try node(browser, "tree/hello.txt")
        let deleting = Task { await browser.delete([hello.id]) }
        try await answer(browser, "pw")
        await deleting.value
        XCTAssertNil(browser.problem)

        let archive = try await Archive.open(url)
        XCTAssertFalse(archive.entries.contains { $0.path == "tree/hello.txt" })
        let destination = fixtures.path("after-delete")
        let outcome = try await archive.extract(to: destination, password: { "pw" })
        XCTAssertTrue(outcome.entryErrors.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "tree/sub/nested.txt"), encoding: .utf8),
                       Fixtures.files["sub/nested.txt"])
        browser.close()
    }

    // MARK: - Undo

    func testUndoPutsTheOriginalBackAndRedoTheEdit() async throws {
        let url = try await make("tree.7z")
        let original = try Data(contentsOf: url)
        let browser = try await open(url)

        await browser.delete([try node(browser, "tree/sub").id])
        let edited = try Data(contentsOf: url)
        XCTAssertNotEqual(edited, original)
        XCTAssertTrue(browser.canUndo)

        await browser.undo()
        XCTAssertEqual(try Data(contentsOf: url), original, "byte for byte what it was")
        XCTAssertTrue(browser.canRedo)
        XCTAssertNotNil(try? node(browser, "tree/sub"), "and the browser shows it")

        await browser.redo()
        XCTAssertEqual(try Data(contentsOf: url), edited)
        XCTAssertFalse(browser.canRedo)

        browser.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.scratch.path),
                       "the history goes with the window")
    }

    func testANewEditForgetsWhatWasUndone() async throws {
        let browser = try await open(try await make("tree.zip"))
        await browser.delete([try node(browser, "tree/blob.bin").id])
        await browser.undo()
        XCTAssertTrue(browser.canRedo)
        await browser.rename(try node(browser, "tree/hello.txt"), to: "hi.txt")
        XCTAssertFalse(browser.canRedo)
        browser.close()
    }

    // MARK: - What cannot be edited, and failing safely

    func testArchivesThatCannotBeRewrittenSaySo() async throws {
        let tar = try await make("tree.tar")
        let tarGz = fixtures.path("tree.tar.gz")
        try await Archive.create(at: tarGz, from: [tar], format: "gzip")

        let browser = ArchiveBrowser(url: tarGz, preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertEqual(browser.levels.count, 2)
        XCTAssertEqual(browser.editBlockedReason, "this archive is inside another one")
        browser.goUp()
        XCTAssertNotNil(browser.editBlockedReason, "a gzip stream has no entries to edit")
        browser.close()
    }

    func testAFailedEditLeavesTheFileAsItWasAndNothingBesideIt() async throws {
        let url = try await make("tree.zip")
        let original = try Data(contentsOf: url)
        let browser = try await open(url)

        // A source that does not exist: the add fails before any writing.
        await browser.add([fixtures.path("no-such-file")], into: nil)
        XCTAssertNotNil(browser.problem)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(browser.canUndo)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixtures.root.path)
            .filter { $0.contains(".7-Mac-") }
        XCTAssertEqual(leftovers, [], "no half-written archive left next to it")
        browser.close()
    }

    // MARK: - Helpers

    private func make(_ name: String) async throws -> URL {
        let url = fixtures.path(name)
        try await Archive.create(at: url, from: [fixtures.tree])
        return url
    }

    private func open(_ url: URL) async throws -> ArchiveBrowser {
        let browser = ArchiveBrowser(url: url, preferences: preferences, queue: queue)
        await browser.open()
        XCTAssertEqual(browser.phase, .ready)
        XCTAssertNil(browser.editBlockedReason)
        return browser
    }

    private func node(_ browser: ArchiveBrowser, _ path: String) throws -> ArchiveNode {
        try XCTUnwrap(browser.current?.tree.allNodes.first { $0.path == path }, "no \(path)")
    }

    private func paths(in url: URL) async throws -> Set<String> {
        Set(try await Archive.open(url).entries.map(\.path))
    }

    private func text(of path: String, in url: URL) async throws -> String {
        let archive = try await Archive.open(url)
        let entry = try XCTUnwrap(archive.entries.first { $0.path == path })
        let destination = fixtures.path("read-\(UUID().uuidString)")
        try await archive.extract(IndexSet(integer: Int(entry.index)), to: destination, paths: .flatten)
        return try String(contentsOf: destination.appending(component: (path as NSString).lastPathComponent),
                          encoding: .utf8)
    }

    /// The listed fixture files come back with the right bytes.
    private func assertContents(of url: URL, match files: [String],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let destination = fixtures.path("check-\(UUID().uuidString)")
        try await Archive.open(url).extract(to: destination)
        for name in files {
            let actual = try? String(contentsOf: destination.appending(path: "tree/\(name)"), encoding: .utf8)
            XCTAssertEqual(actual, Fixtures.files[name], name, file: file, line: line)
        }
    }

    private func answer(_ browser: ArchiveBrowser, _ password: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while browser.passwordPrompt == nil {
            if Date() > deadline { XCTFail("no password prompt"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.passwordPrompt?.password = password
        browser.passwordPrompt?.submit()
    }
}
