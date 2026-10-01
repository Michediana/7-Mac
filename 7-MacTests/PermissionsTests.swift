//
//  PermissionsTests.swift
//  7-MacTests
//
//  The permission list says what is true now: a menu the Finder has not
//  loaded since it restarted is a problem even when it is switched on, and a
//  folder shows up once it is granted and goes once it is forgotten.
//

import XCTest
@testable import __Mac

@MainActor
final class PermissionsTests: XCTestCase {
    private let finderStart = Date(timeIntervalSince1970: 1_800_000_000)

    func testAMenuLoadedSinceTheFinderStartedIsFine() {
        let (status, _) = PermissionReport.finderMenuLoad(lastBeat: finderStart.addingTimeInterval(2),
                                                          finderLaunched: finderStart)
        XCTAssertEqual(status, .ok)
    }

    func testAMenuNotLoadedSinceTheFinderRestartedIsAProblem() {
        // The case this check exists for: switched on, failed to launch, and
        // the Finder not trying again until it is relaunched.
        let (status, detail) = PermissionReport.finderMenuLoad(lastBeat: finderStart.addingTimeInterval(-600),
                                                               finderLaunched: finderStart)
        XCTAssertEqual(status, .problem)
        XCTAssertTrue(detail.contains("Relaunch"), detail)
    }

    func testAMenuNeverLoadedIsAProblem() {
        XCTAssertEqual(PermissionReport.finderMenuLoad(lastBeat: nil, finderLaunched: finderStart).0, .problem)
    }

    func testTheHeartbeatIsSeenByTheApp() throws {
        FinderMenuHeartbeat.beat(always: true)
        let beat = try XCTUnwrap(FinderMenuHeartbeat.lastBeat)
        XCTAssertLessThan(abs(beat.timeIntervalSinceNow), 5)
    }

    func testTheSharedContainerChecksOut() {
        let shared = PermissionReport.finderChecks().first { $0.id == "finder.group" }
        XCTAssertEqual(shared?.status, .ok)
    }

    func testAGrantedFolderIsListedAndCanBeForgotten() throws {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(component: "Granted-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        FolderAccess.shared.grant(folder)
        defer { FolderAccess.shared.forget(folder) }
        let listed = PermissionReport.folderChecks().first { $0.title.hasSuffix(folder.lastPathComponent) }
        XCTAssertEqual(listed?.status, .ok)

        FolderAccess.shared.forget(folder)
        XCTAssertFalse(PermissionReport.folderChecks().contains { $0.title.hasSuffix(folder.lastPathComponent) })
    }

    func testAFolderThatIsGoneNeedsAttention() throws {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(component: "Gone-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FolderAccess.shared.grant(folder)
        defer { FolderAccess.shared.forget(folder) }
        try FileManager.default.removeItem(at: folder)

        let listed = PermissionReport.folderChecks().first { $0.title.hasSuffix(folder.lastPathComponent) }
        XCTAssertEqual(listed?.status, .warning)
    }

    func testPathsUnderTheHomeFolderAreShortened() {
        let home = PermissionReport.realHome
        XCTAssertEqual(PermissionReport.displayPath(home), "~")
        XCTAssertEqual(PermissionReport.displayPath(home.appending(component: "Pictures")), "~/Pictures")
        XCTAssertEqual(PermissionReport.displayPath(URL(filePath: "/Volumes/Disk")), "/Volumes/Disk")
    }
}
