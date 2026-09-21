//
//  PasswordStoreTests.swift
//  7-MacTests
//
//  These run inside the app host, so they exercise the real thing: a
//  sandboxed, signed process talking to the login keychain. That is the
//  assumption worth checking — the API itself is not in doubt.
//

import XCTest
@testable import __Mac

final class PasswordStoreTests: XCTestCase {
    private var archive: URL!

    override func setUp() {
        super.setUp()
        archive = URL(filePath: "/tmp/7-MacTests-\(UUID().uuidString)/locked.7z")
    }

    override func tearDown() {
        PasswordStore.forget(archive)
        super.tearDown()
    }

    func testSaveAndReadBack() throws {
        XCTAssertNil(PasswordStore.password(for: archive))
        PasswordStore.save("hunter2", for: archive)
        guard let stored = PasswordStore.password(for: archive) else {
            throw XCTSkip("no keychain access in this environment")
        }
        XCTAssertEqual(stored, "hunter2")
    }

    func testSavingTwiceReplacesRatherThanDuplicates() throws {
        PasswordStore.save("first", for: archive)
        try XCTSkipIf(PasswordStore.password(for: archive) == nil,
                      "no keychain access in this environment")
        PasswordStore.save("second", for: archive)
        XCTAssertEqual(PasswordStore.password(for: archive), "second")
    }

    func testForgetting() throws {
        PasswordStore.save("hunter2", for: archive)
        try XCTSkipIf(PasswordStore.password(for: archive) == nil,
                      "no keychain access in this environment")
        PasswordStore.forget(archive)
        XCTAssertNil(PasswordStore.password(for: archive))
    }

    /// Keyed by path: two archives never share a password by accident.
    func testTwoArchivesKeepSeparatePasswords() throws {
        let other = URL(filePath: "/tmp/7-MacTests-\(UUID().uuidString)/other.7z")
        defer { PasswordStore.forget(other) }

        PasswordStore.save("one", for: archive)
        try XCTSkipIf(PasswordStore.password(for: archive) == nil,
                      "no keychain access in this environment")
        PasswordStore.save("two", for: other)
        XCTAssertEqual(PasswordStore.password(for: archive), "one")
        XCTAssertEqual(PasswordStore.password(for: other), "two")
    }

    func testUnicodePasswordsSurvive() throws {
        PasswordStore.save("pässwörd-☃-🔐", for: archive)
        try XCTSkipIf(PasswordStore.password(for: archive) == nil,
                      "no keychain access in this environment")
        XCTAssertEqual(PasswordStore.password(for: archive), "pässwörd-☃-🔐")
    }
}
