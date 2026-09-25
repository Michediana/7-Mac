//
//  ArchiveTreeTests.swift
//  7-MacTests
//
//  The flat entry list, turned into the tree a browser shows. Built from
//  records rather than real archives, because the interesting cases — a
//  folder named only by its children, a folder named after its children, the
//  same path twice — are ones our own writer never produces.
//

import XCTest
@testable import __Mac

final class ArchiveTreeTests: XCTestCase {

    // MARK: - Building

    func testFoldersTheArchiveNeverMentionsAreImplied() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "a/b/c.txt", size: 10, packedSize: 4),
        ])
        let a = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(a.name, "a")
        XCTAssertTrue(a.isDirectory)
        XCTAssertNil(a.record, "an implied folder has no entry to extract")
        let b = try XCTUnwrap(a.children.first)
        XCTAssertEqual(b.path, "a/b")
        XCTAssertEqual(b.children.map(\.name), ["c.txt"])
        XCTAssertEqual(tree.fileCount, 1)
        XCTAssertEqual(tree.folderCount, 2)
    }

    func testAFolderListedAfterItsChildrenTakesOverTheImpliedOne() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "docs/readme.md", size: 5),
            EntryRecord(index: 1, path: "docs", isDirectory: true, posixPermissions: 0o755),
        ])
        XCTAssertEqual(tree.roots.count, 1, "one docs, not two")
        let docs = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(docs.record?.index, 1)
        XCTAssertEqual(docs.children.map(\.name), ["readme.md"])
        XCTAssertEqual(docs.permissionsDescription, "drwxr-xr-x")
    }

    func testDotSlashAndDoubledSlashesAreNotComponents() {
        // `tar czf x.tgz .` writes every path like this.
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "./", isDirectory: true),
            EntryRecord(index: 1, path: "./src//main.c", size: 3),
        ])
        XCTAssertEqual(tree.roots.map(\.name), ["src"])
        XCTAssertEqual(tree.roots.first?.children.first?.path, "src/main.c")
    }

    func testTheSamePathTwiceIsTwoFiles() {
        // A tar appended to keeps both copies, and they are different files.
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "notes.txt", size: 1),
            EntryRecord(index: 1, path: "notes.txt", size: 2),
        ])
        XCTAssertEqual(tree.roots.map { $0.record?.index }, [0, 1])
    }

    func testFolderTotalsAddUpAndAnUnknownPackedSizeStaysUnknown() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "known/a", size: 100, packedSize: 40),
            EntryRecord(index: 1, path: "known/b", size: 50, packedSize: 10),
            EntryRecord(index: 2, path: "partly/a", size: 100, packedSize: 40),
            EntryRecord(index: 3, path: "partly/b", size: 50),
            EntryRecord(index: 4, path: "empty", isDirectory: true),
        ])
        let known = try XCTUnwrap(tree.roots.first { $0.name == "known" })
        XCTAssertEqual(known.size, 150)
        XCTAssertEqual(known.packedSize, 50)
        XCTAssertEqual(try XCTUnwrap(known.ratio), 1.0 / 3.0, accuracy: 0.001)

        let partly = try XCTUnwrap(tree.roots.first { $0.name == "partly" })
        XCTAssertEqual(partly.size, 150)
        XCTAssertNil(partly.packedSize, "half a sum is not a packed size")

        XCTAssertNil(tree.totalPackedSize)
        XCTAssertEqual(tree.totalSize, 300)
        let empty = try XCTUnwrap(tree.roots.first { $0.name == "empty" })
        XCTAssertEqual(empty.outlineChildren?.count, 0, "an empty folder still discloses")
    }

    // MARK: - Selection

    func testSelectingAFolderMeansEverythingInIt() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "keep/one", size: 1),
            EntryRecord(index: 1, path: "keep/deeper/two", size: 2),
            EntryRecord(index: 2, path: "skip/three", size: 3),
            EntryRecord(index: 3, path: "keep", isDirectory: true),
        ])
        let keep = try XCTUnwrap(tree.roots.first { $0.name == "keep" })
        XCTAssertEqual(tree.entryIndexes(for: [keep.id]), IndexSet([0, 1, 3]))

        let one = try XCTUnwrap(keep.children.first { $0.name == "one" })
        let summary = tree.summary(of: [keep.id, one.id])
        XCTAssertEqual(summary.files, 2, "a file inside a selected folder counts once")
        XCTAssertEqual(summary.bytes, 3)
    }

    func testAnImpliedFolderSelectsItsContentsOnly() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 7, path: "implied/file", size: 1),
        ])
        let implied = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(tree.entryIndexes(for: [implied.id]), IndexSet([7]))
    }

    // MARK: - Sorting and searching

    func testFoldersStayOnTopWhateverTheColumn() {
        var tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "big.bin", size: 900),
            EntryRecord(index: 1, path: "folder/small", size: 1),
            EntryRecord(index: 2, path: "medium.bin", size: 50),
        ])
        tree.sort(using: [KeyPathComparator(\ArchiveNode.sortSize, order: .reverse)])
        XCTAssertEqual(tree.roots.map(\.name), ["folder", "big.bin", "medium.bin"])

        tree.sort(using: [KeyPathComparator(\ArchiveNode.sortSize)])
        XCTAssertEqual(tree.roots.map(\.name), ["folder", "medium.bin", "big.bin"])
    }

    func testNamesSortTheWayTheFinderSortsThem() {
        var tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "file10.txt"),
            EntryRecord(index: 1, path: "file2.txt"),
            EntryRecord(index: 2, path: "File1.txt"),
        ])
        tree.sort(using: [KeyPathComparator(\ArchiveNode.name, comparator: .localizedStandard)])
        XCTAssertEqual(tree.roots.map(\.name), ["File1.txt", "file2.txt", "file10.txt"])
    }

    func testSearchIsFlatAndIgnoresCaseAndAccents() {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "deep/down/Résumé.pdf"),
            EntryRecord(index: 1, path: "resume-notes.txt"),
            EntryRecord(index: 2, path: "other.txt"),
        ])
        let found = tree.matches("resume", filter: .everything, comparators: [])
        XCTAssertEqual(found.map(\.path), ["deep/down/Résumé.pdf", "resume-notes.txt"])
    }

    func testFiltersKeepFilesOfOneKind() {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "photos/cat.jpg"),
            EntryRecord(index: 1, path: "photos/dog.PNG"),
            EntryRecord(index: 2, path: "src/main.swift"),
            EntryRecord(index: 3, path: "notes.txt"),
            EntryRecord(index: 4, path: "backup.tar.gz"),
            EntryRecord(index: 5, path: "secret.bin", isEncrypted: true),
        ])
        func names(_ filter: EntryFilter) -> [String] {
            tree.matches("", filter: filter, comparators: []).map(\.name)
        }
        XCTAssertEqual(names(.images), ["cat.jpg", "dog.PNG"])
        XCTAssertEqual(names(.sourceCode), ["main.swift"])
        XCTAssertEqual(names(.documents), ["notes.txt"])
        XCTAssertEqual(names(.archives), ["backup.tar.gz"])
        XCTAssertEqual(names(.encrypted), ["secret.bin"])
        XCTAssertEqual(tree.matches("cat", filter: .sourceCode, comparators: []).count, 0,
                       "search and filter narrow together")
    }

    // MARK: - Display

    func testChecksumsAndPermissionsReadLikeTheToolsPrintThem() throws {
        let tree = ArchiveTree(records: [
            EntryRecord(index: 0, path: "run.sh", checksum: 0xBEEF, posixPermissions: 0o750),
            EntryRecord(index: 1, path: "link", isSymbolicLink: true, posixPermissions: 0o777),
        ])
        let script = try XCTUnwrap(tree.roots.first { $0.name == "run.sh" })
        XCTAssertEqual(script.checksumDescription, "0000BEEF")
        XCTAssertEqual(script.permissionsDescription, "-rwxr-x---")
        let link = try XCTUnwrap(tree.roots.first { $0.name == "link" })
        XCTAssertEqual(link.permissionsDescription, "lrwxrwxrwx")
    }
}
