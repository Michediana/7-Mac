//
//  FinderHandoffTests.swift
//  7-MacTests
//
//  The Finder menu's note to the app: found by the URL that names it, only
//  once, and never when it is old or the URL is not ours.
//

import XCTest
@testable import __Mac

@MainActor
final class FinderHandoffTests: XCTestCase {
    private let archive = URL(filePath: "/tmp/handoff/sample.7z")
    private let folder = URL(filePath: "/tmp/handoff/Folder/", directoryHint: .isDirectory)

    func testTheAppGroupContainerIsReachable() throws {
        let group = try XCTUnwrap(FinderHandoff.groupID)
        XCTAssertTrue(group.hasSuffix(".com.michediana.Seven-Mac"), group)
        XCTAssertNotNil(FinderHandoff.directory)
    }

    func testARequestIsFoundByItsURLAndOnlyOnce() throws {
        let url = try FinderHandoff.post(.browse, for: [archive, folder])
        XCTAssertEqual(url.scheme, "sevenmac")

        let request = try XCTUnwrap(FinderHandoff.take(url))
        XCTAssertEqual(request.action, .browse)
        XCTAssertEqual(request.urls.map(\.lastPathComponent), ["sample.7z", "Folder"])
        XCTAssertNil(FinderHandoff.take(url))
    }

    func testTwoRequestsDoNotOverwriteEachOther() throws {
        let first = try FinderHandoff.post(.extract, for: [archive])
        let second = try FinderHandoff.post(.compress, for: [folder])
        XCTAssertEqual(FinderHandoff.take(second)?.action, .compress)
        XCTAssertEqual(FinderHandoff.take(first)?.action, .extract)
    }

    func testAStaleRequestIsDroppedAndRemoved() throws {
        let then = Date.now.addingTimeInterval(-FinderHandoff.lifetime - 1)
        let url = try FinderHandoff.post(.extract, for: [archive], now: then)
        XCTAssertNil(FinderHandoff.take(url))
        let file = try XCTUnwrap(FinderHandoff.directory)
            .appending(component: "\(url.lastPathComponent).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnyOtherURLIsIgnored() {
        XCTAssertNil(FinderHandoff.take(URL(string: "sevenmac://finder/not-an-id")!))
        XCTAssertNil(FinderHandoff.take(URL(string: "sevenmac://elsewhere/\(UUID().uuidString)")!))
        XCTAssertNil(FinderHandoff.take(URL(string: "sevenmac://finder/\(UUID().uuidString)")!))
        XCTAssertNil(FinderHandoff.take(archive))
    }

    func testTheSchemeIsRegistered() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(FinderHandoff.scheme))
    }

    func testTheMenuAndADropAgreeOnWhatIsAnArchive() {
        // One list, two targets: this fails only if someone forks it again.
        XCTAssertEqual(ArchiveNaming.droppedArchiveExtensions, ArchiveExtensions.dropped)
    }
}
