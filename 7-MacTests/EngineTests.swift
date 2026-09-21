//
//  EngineTests.swift
//  7-MacTests
//

import XCTest
import SevenZipKit
@testable import __Mac

final class EngineTests: XCTestCase {

    func testEngineReportsItsUpstreamVersion() {
        XCTAssertEqual(SevenZip.engineVersion, "26.03")
        XCTAssertEqual(SevenZip.engineDate, "2026-09-03")
    }

    /// The count is the canary for the `-force_load` flag: link the engine
    /// archive the ordinary way and every handler's global constructor is
    /// dropped, leaving a framework that loads cleanly and knows nothing.
    func testEveryFormatHandlerIsRegistered() {
        XCTAssertEqual(SevenZip.formats.count, 60)
    }

    func testExactlySevenFormatsAreWritable() {
        let writable = SevenZip.writableFormats.map(\.name).sorted()
        XCTAssertEqual(writable, ["7z", "bzip2", "gzip", "tar", "wim", "xz", "zip"])
    }

    /// An accepted limit, not a gap: zstd reads but never writes. The UI must
    /// not offer it as an output format.
    func testZstdIsReadOnly() throws {
        let zstd = try XCTUnwrap(SevenZip.format(named: "zstd"))
        XCTAssertFalse(zstd.isWritable)
    }

    func testFormatsCarryTheirExtensions() throws {
        let sevenZip = try XCTUnwrap(SevenZip.format(named: "7z"))
        XCTAssertEqual(sevenZip.fileExtensions, ["7z"])
        XCTAssertTrue(sevenZip.isWritable)
        XCTAssertFalse(sevenZip.signatures.isEmpty)
    }

    /// `.tgz` is gzip wrapping a tar, and the engine says so: this is what
    /// lets a browser show one tree instead of an archive inside an archive.
    func testGzipReportsTheExtensionItWraps() throws {
        let gzip = try XCTUnwrap(SevenZip.format(named: "gzip"))
        XCTAssertEqual(gzip.wrappedExtension(forFileExtension: "tgz"), "tar")
        XCTAssertNil(gzip.wrappedExtension(forFileExtension: "gz"))
    }

    func testLookupByExtensionIsCaseAndDotInsensitive() {
        XCTAssertEqual(SevenZip.formats(forFileExtension: ".7Z").map(\.name), ["7z"])
        XCTAssertEqual(SevenZip.formats(forFileExtension: "7z").map(\.name), ["7z"])
        XCTAssertTrue(SevenZip.formats(forFileExtension: "definitely-not-a-format").isEmpty)
    }
}
