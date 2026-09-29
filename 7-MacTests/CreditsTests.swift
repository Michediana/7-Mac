//
//  CreditsTests.swift
//  7-MacTests
//
//  The licences the About window shows are there, and are the real ones.
//

import XCTest
@testable import __Mac

@MainActor
final class CreditsTests: XCTestCase {
    func testEveryLicenceShipsWithTheApp() throws {
        for document in CreditDocument.allCases {
            let text = try XCTUnwrap(document.text, "\(document) is missing from the bundle")
            XCTAssertGreaterThan(text.count, 500, "\(document) looks truncated")
            XCTAssertFalse(text.contains("\r"), "\(document) keeps Windows line endings")
        }
    }

    func testTheAppLicenceIsTheRepositorysOwn() throws {
        // A copy has to be bundled; this is what keeps it from drifting.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = try String(contentsOf: repository.appending(component: "LICENSE"), encoding: .utf8)
        XCTAssertEqual(CreditDocument.app.text, original)
    }

    func testTheUnRARRestrictionIsShownWordForWord() throws {
        let unRAR = try XCTUnwrap(CreditDocument.unRAR.text)
        XCTAssertTrue(unRAR.contains("cannot be used\n      to re-create the RAR compression algorithm"))
        XCTAssertTrue(try XCTUnwrap(CreditDocument.lgpl.text).contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(try XCTUnwrap(CreditDocument.sevenZip.text).contains("Igor Pavlov"))
    }
}
