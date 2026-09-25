//
//  EngineOptionsTests.swift
//  7-MacTests
//
//  M5's engine side: checksums that match what other tools print, and the
//  creation options — method, dictionary, solid blocks, exclusions, links —
//  actually reaching the archive rather than being accepted and ignored.
//

import XCTest
import CryptoKit
import SevenZipKit
@testable import __Mac

final class EngineOptionsTests: XCTestCase {
    private var fixtures: Fixtures!

    /// `hello.txt`'s bytes, checked against zlib, hashlib and shasum.
    private let helloCRC32 = "6C47785C"
    private let helloSHA256 = "9c0dcd73470702de299268ab63eb6bdb8f6c7f73f6faae5a3b7f64763060e5a9"
    private let helloMD5 = "d0a2192d9762e5a68d3f54b8060f69af"

    override func setUpWithError() throws {
        fixtures = try Fixtures()
    }

    override func tearDown() {
        fixtures.destroy()
        fixtures = nil
    }

    // MARK: - Hashing

    func testTheEngineHasTheHashesTheRoadmapPromises() {
        let methods = Set(SevenZip.hashMethods)
        for expected in ["CRC32", "CRC64", "SHA256", "SHA512", "SHA3-256", "MD5", "XXH64", "BLAKE2sp"] {
            XCTAssertTrue(methods.contains(expected), "\(expected) missing from \(methods.sorted())")
        }
    }

    func testFileHashesMatchWhatOtherToolsPrint() async throws {
        let hello = fixtures.tree.appending(component: "hello.txt")
        let report = try await SevenZip.hash([hello], methods: ["CRC32", "SHA256", "MD5"])
        XCTAssertEqual(report.methods, ["CRC32", "SHA256", "MD5"])
        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.path, "hello.txt")
        XCTAssertEqual(item.size, UInt64(Fixtures.files["hello.txt"]!.utf8.count))
        XCTAssertEqual(item.digests, [helloCRC32, helloSHA256, helloMD5])
    }

    func testAFolderIsHashedFileByFile() async throws {
        let report = try await SevenZip.hash([fixtures.tree], methods: ["SHA256"])
        let blob = try XCTUnwrap(report.items.first { $0.path == "tree/blob.bin" })
        let expected = SHA256.hash(data: try Data(contentsOf: fixtures.tree.appending(component: "blob.bin")))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(blob.digests, [expected])
        XCTAssertTrue(report.items.contains { $0.path == "tree/sub" && $0.isDirectory })
        XCTAssertEqual(report.dataSums.count, 1)
        XCTAssertGreaterThanOrEqual(report.files, 4)
    }

    func testAnUnknownMethodIsRefused() async throws {
        do {
            _ = try await SevenZip.hash([fixtures.tree], methods: ["NOT-A-HASH"])
            XCTFail("an unknown method should not produce a report")
        } catch {
            XCTAssertEqual(error.sevenZipCode, .unsupported)
        }
    }

    func testEntryHashesMatchTheFilesTheyCameFrom() async throws {
        let url = fixtures.path("tree.7z")
        try await Archive.create(at: url, from: [fixtures.tree])
        let archive = try await Archive.open(url)
        let report = try await archive.hash(methods: ["CRC32", "SHA256"])
        let hello = try XCTUnwrap(report.items.first { $0.path == "tree/hello.txt" })
        XCTAssertEqual(hello.digests, [helloCRC32, helloSHA256])
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testAnEncryptedArchiveIsHashedWithItsPassword() async throws {
        let url = fixtures.path("secret.7z")
        try await Archive.create(at: url, from: [fixtures.tree], password: "pw")
        let archive = try await Archive.open(url)
        do {
            _ = try await archive.hash(methods: ["SHA256"])
            XCTFail("no password, no hashes")
        } catch {
            XCTAssertTrue(error.isPasswordProblem, "\(error)")
        }
        let report = try await archive.hash(methods: ["SHA256"], password: { "pw" })
        XCTAssertEqual(report.items.first { $0.path == "tree/hello.txt" }?.digests, [helloSHA256])
    }

    func testADamagedArchiveStillGetsAReport() async throws {
        // Stored, not compressed, so a flipped byte lands in a file's data
        // and the CRC catches it, rather than breaking the whole stream.
        let url = fixtures.path("damaged.zip")
        try await Archive.create(at: url, from: [fixtures.tree], format: "zip", level: .store)
        var bytes = try Data(contentsOf: url)
        let marker = Data("hello from 7-Mac".utf8)
        let range = try XCTUnwrap(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 0xFF
        try bytes.write(to: url)

        let report = try await Archive.open(url).hash(methods: ["CRC32"])
        XCTAssertFalse(report.failures.isEmpty, "the damaged entry is reported")
        XCTAssertTrue(report.items.contains { $0.path == "tree/sub/nested.txt" },
                      "and the healthy ones are still hashed")
    }

    // MARK: - Creation options

    func testExcludedNamesStayOut() async throws {
        try "junk".write(to: fixtures.tree.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try "junk".write(to: fixtures.tree.appending(path: "sub/.DS_Store"), atomically: true, encoding: .utf8)
        try "fork".write(to: fixtures.tree.appending(path: "._hello.txt"), atomically: true, encoding: .utf8)

        let url = fixtures.path("clean.zip")
        try await Archive.create(at: url, from: [fixtures.tree], excluding: [".DS_Store", "._*"])
        let paths = try await Archive.open(url).entries.map(\.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix(".DS_Store") }, "\(paths)")
        XCTAssertFalse(paths.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
        XCTAssertTrue(paths.contains("tree/hello.txt"), "exclusions are names, not everything")
    }

    func testFollowingLinksStoresWhatTheyPointTo() async throws {
        // A relative link, so it resolves inside the tree wherever it is.
        try FileManager.default.createSymbolicLink(atPath: fixtures.tree.appending(path: "relative.txt").path,
                                                   withDestinationPath: "hello.txt")
        try FileManager.default.removeItem(at: fixtures.tree.appending(path: "link.txt"))
        let url = fixtures.path("followed.tar")
        try await Archive.create(at: url, from: [fixtures.tree], storesSymbolicLinks: false)
        let archive = try await Archive.open(url)
        let link = try XCTUnwrap(archive.entries.first { $0.path == "tree/relative.txt" })
        XCTAssertFalse(link.isSymbolicLink)

        let destination = fixtures.path("followed-out")
        try await archive.extract(to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "tree/relative.txt"), encoding: .utf8),
                       Fixtures.files["hello.txt"], "a copy of the target, not a link")
    }

    func testMethodAndDictionaryReachTheArchive() async throws {
        let ppmd = fixtures.path("ppmd.7z")
        try await Archive.create(at: ppmd, from: [fixtures.tree], methodProperties: ["m": "PPMd"])
        let ppmdMethod = try await Archive.open(ppmd).entries.first { $0.path == "tree/hello.txt" }?.method
        XCTAssertTrue(ppmdMethod?.uppercased().hasPrefix("PPMD") == true, ppmdMethod ?? "nil")

        // The engine shrinks the dictionary to the data it has, so ask for
        // one smaller than the 300 KB blob to see it arrive unchanged.
        let small = fixtures.path("small-dict.7z")
        try await Archive.create(at: small, from: [fixtures.tree],
                                 methodProperties: ["m": "LZMA2", "d": "64k"])
        let lzmaMethod = try await Archive.open(small).entries.first { $0.path == "tree/hello.txt" }?.method
        XCTAssertEqual(lzmaMethod, "LZMA2:16", "a 64 KB dictionary is 2^16")

        // Zip stores what does not shrink; give it something that does.
        let text = String(repeating: "compressible line of text\n", count: 2000)
        try text.write(to: fixtures.tree.appending(path: "big.txt"), atomically: true, encoding: .utf8)
        let bzip = fixtures.path("bzip.zip")
        try await Archive.create(at: bzip, from: [fixtures.tree], format: "zip",
                                 methodProperties: ["m": "BZip2"])
        let bzipMethod = try await Archive.open(bzip).entries.first { $0.path == "tree/big.txt" }?.method
        XCTAssertEqual(bzipMethod, "BZip2")
    }

    func testSolidOffGivesEveryFileItsOwnBlock() async throws {
        // In a solid 7z only the first file of a block reports a packed size.
        let solid = fixtures.path("solid.7z")
        try await Archive.create(at: solid, from: [fixtures.tree])
        let notSolid = fixtures.path("not-solid.7z")
        try await Archive.create(at: notSolid, from: [fixtures.tree], methodProperties: ["s": "off"])

        func packedFiles(_ url: URL) async throws -> Int {
            try await Archive.open(url).entries.count {
                !$0.isDirectory && ($0.compressedSize?.uint64Value ?? 0) > 0
            }
        }
        let solidCount = try await packedFiles(solid)
        let separateCount = try await packedFiles(notSolid)
        XCTAssertGreaterThan(separateCount, solidCount)
    }
}
