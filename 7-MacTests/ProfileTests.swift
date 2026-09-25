//
//  ProfileTests.swift
//  7-MacTests
//
//  Compression profiles: what they ask the engine for, what they say it will
//  cost, and that a saved one comes back the way it was saved.
//

import XCTest
import SevenZipKit
@testable import __Mac

@MainActor
final class ProfileTests: XCTestCase {
    private var fixtures: Fixtures!
    private var suiteName: String!
    private var suite: UserDefaults!
    private var preferences: Preferences!

    override func setUpWithError() throws {
        fixtures = try Fixtures()
        suiteName = "7-MacTests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = Preferences(defaults: suite)
        preferences.revealWhenDone = false
    }

    override func tearDown() {
        fixtures?.destroy()
        if let suiteName {
            suite?.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
        }
    }

    // MARK: - What a profile asks for

    func testTheBuiltInProfilesOnlySetALevel() {
        for profile in CompressionProfile.builtIn {
            XCTAssertEqual(profile.methodProperties, [:], profile.name)
        }
        XCTAssertEqual(CompressionProfile.maximum.compressionLevel, .ultra)
    }

    func testEveryChoiceBecomesAnEngineProperty() {
        var profile = CompressionProfile(name: "Text", format: "7z", level: 7, method: .ppmd,
                                         dictionary: 16 << 20, solid: .off, threads: 2)
        XCTAssertEqual(profile.methodProperties, ["m": "PPMd", "mem": "16384k", "s": "off", "mt": "2"])

        profile.method = .lzma2
        profile.solid = .blockSize(256 << 20)
        XCTAssertEqual(profile.methodProperties["d"], "16384k")
        XCTAssertEqual(profile.methodProperties["s"], "256m")
    }

    func testAMethodTheFormatLacksIsNotPassedOn() {
        // LZMA2 is 7z's; zip has LZMA but not LZMA2. Solid is 7z-only too.
        let profile = CompressionProfile(name: "x", format: "zip", level: 5, method: .lzma2,
                                         dictionary: 1 << 20, solid: .off)
        XCTAssertNil(profile.methodProperties["m"])
        XCTAssertNil(profile.methodProperties["s"])
        XCTAssertEqual(profile.effectiveMethod, .deflate)
        XCTAssertNil(profile.methodProperties["d"], "Deflate has no dictionary to choose")
    }

    func testDefaultDictionariesFollowTheEngine() {
        // LzmaEnc.c: 2^(2L+16) up to level 4, 2^(L+20) up to 8, 256 MB at 9.
        func dictionary(_ level: Int) -> UInt64? {
            CompressionProfile(name: "", format: "7z", level: level).effectiveDictionary
        }
        XCTAssertEqual(dictionary(1), 256 << 10)
        XCTAssertEqual(dictionary(3), 4 << 20)
        XCTAssertEqual(dictionary(5), 32 << 20)
        XCTAssertEqual(dictionary(7), 128 << 20)
        XCTAssertEqual(dictionary(9), 256 << 20)
    }

    // MARK: - Memory

    func testMemoryGrowsWithTheDictionaryAndTheThreads() throws {
        var profile = CompressionProfile(name: "", format: "7z", level: 5, threads: 1)
        let small = try XCTUnwrap(MemoryEstimate(profile))
        profile.dictionary = 256 << 20
        let big = try XCTUnwrap(MemoryEstimate(profile))
        XCTAssertGreaterThan(big.compress, small.compress)
        XCTAssertEqual(big.decompress, (256 << 20) + (2 << 20), "decoding needs the dictionary and 2 MB")

        profile.threads = 8
        let threaded = try XCTUnwrap(MemoryEstimate(profile))
        XCTAssertGreaterThan(threaded.compress, big.compress)
        XCTAssertEqual(threaded.decompress, big.decompress, "threads do not change decoding")
    }

    func testTheLzma2FormulaMatches7Zip() throws {
        // One thread, level 5, 32 MB dictionary, worked by hand through
        // CompressDialog.cpp: hash 16 MB·4, dictionary 32 MB·4 twice, 2 MB,
        // plus a block of dict + 64 KB, grown by half.
        let profile = CompressionProfile(name: "", format: "zip", level: 5, method: .lzma,
                                         dictionary: 32 << 20, threads: 1)
        let estimate = try XCTUnwrap(MemoryEstimate(profile))
        let hash: UInt64 = (16 << 20) * 4
        let perThread = hash + (32 << 20) * 8 + (2 << 20)
        var block: UInt64 = (32 << 20) + (1 << 16)
        block += block >> 1
        XCTAssertEqual(estimate.compress, perThread + block)
        XCTAssertEqual(MemoryEstimate.lzma2ChunkSize(32 << 20), 128 << 20)
    }

    func testAutomaticThreadsFitTheMachineTheWay7ZipDoes() throws {
        // Ultra, 256 MB dictionary, sixteen cores, 8 GB: at full width it
        // would want far more than the Mac has, so the engine drops block
        // threads until it fits 80% — and the estimate says so.
        let profile = CompressionProfile(name: "", format: "7z", level: 9)
        let fitted = try XCTUnwrap(MemoryEstimate(profile, processors: 16, physicalMemory: 8 << 30))
        XCTAssertLessThanOrEqual(fitted.compress, (8 << 30) / 100 * 80)
        XCTAssertLessThan(try XCTUnwrap(fitted.threads), 16)

        var forced = profile
        forced.threads = 16
        let wide = try XCTUnwrap(MemoryEstimate(forced, processors: 16, physicalMemory: 8 << 30))
        XCTAssertEqual(wide.threads, 16, "a number the person chose is not second-guessed")
        XCTAssertGreaterThan(wide.compress, fitted.compress)
        XCTAssertTrue(wide.isExcessive(physicalMemory: 8 << 30))
    }

    func testStoringCostsNothingToSpeakOf() throws {
        let estimate = try XCTUnwrap(MemoryEstimate(CompressionProfile(name: "", format: "7z", level: 0)))
        XCTAssertEqual(estimate, MemoryEstimate(compress: 1 << 20, decompress: 1 << 20))
    }

    func testAnEstimatePastTheEnginesOwnLimitIsFlagged() {
        let estimate = MemoryEstimate(compress: 7 << 30, decompress: 1 << 30)
        XCTAssertTrue(estimate.isExcessive(physicalMemory: 8 << 30))
        XCTAssertFalse(estimate.isExcessive(physicalMemory: 16 << 30))
    }

    // MARK: - Saving

    func testASavedProfileComesBackAfterARestart() {
        let profile = CompressionProfile(name: "", format: "zip", level: 9, method: .bzip2, threads: 4)
        let saved = preferences.save(profile, as: "Archive for Windows")
        preferences.profileID = saved.id

        let reloaded = Preferences(defaults: suite)
        XCTAssertEqual(reloaded.profiles.count, CompressionProfile.builtIn.count + 1)
        XCTAssertEqual(reloaded.profile(withID: saved.id), saved)
        XCTAssertEqual(reloaded.profileID, saved.id)

        reloaded.deleteProfile(saved.id)
        XCTAssertEqual(reloaded.profileID, CompressionProfile.normal.id, "back to Normal")
        XCTAssertEqual(Preferences(defaults: suite).profiles.count, CompressionProfile.builtIn.count)
    }

    func testSavingUnderAnExistingNameReplacesIt() {
        let first = preferences.save(CompressionProfile(name: "", format: "7z", level: 3), as: "Mine")
        let second = preferences.save(CompressionProfile(name: "", format: "7z", level: 9), as: "Mine")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(preferences.profile(withID: first.id).level, 9)
    }

    func testTheOldPresetCarriesOver() {
        suite.set("maximum", forKey: "CompressionPreset")
        XCTAssertEqual(Preferences(defaults: suite).profileID, CompressionProfile.maximum.id)
    }

    // MARK: - The sheet's model

    func testChoosingASavedProfileBringsItsFormat() {
        let saved = preferences.save(CompressionProfile(name: "", format: "zip", level: 7), as: "Zip it")
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: preferences)
        XCTAssertEqual(draft.formatName, "7z")

        draft.choose(saved.id)
        XCTAssertEqual(draft.formatName, "zip")
        XCTAssertEqual(draft.output.pathExtension, "zip")
        XCTAssertFalse(draft.isModified)

        draft.profile.level = 1
        XCTAssertTrue(draft.isModified)
    }

    func testChangingFormatDropsAMethodItCannotUse() {
        let draft = CompressionDraft(sources: [fixtures.tree], preferences: preferences)
        draft.profile.method = .ppmd
        draft.profile.dictionary = 64 << 20
        draft.formatName = "tar"
        draft.formatChanged()
        XCTAssertNil(draft.profile.method)
        XCTAssertNil(draft.profile.dictionary)
        XCTAssertTrue(draft.availableMethods.isEmpty)
    }

    // MARK: - All of it, through the queue

    func testACompressionJobHonoursTheProfileVolumesAndExclusions() async throws {
        try "junk".write(to: fixtures.tree.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        let queue = JobQueue(preferences: preferences)
        let output = fixtures.path("out/split.7z")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let request = CompressionRequest(
            sources: [fixtures.tree], output: output, formatName: "7z",
            profile: CompressionProfile(name: "", format: "7z", level: 5, method: .ppmd),
            password: nil, encryptsHeader: false,
            volumeSize: 100 << 10,   // the 300 KB blob needs several
            excludedNames: preferences.creationExclusions)

        let job = try XCTUnwrap(queue.enqueue([.compress(request)]).first)
        let deadline = Date().addingTimeInterval(60)
        while !job.isFinished && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(job.state, .finished, job.statusLine)

        let first = try XCTUnwrap(job.resultURL)
        XCTAssertEqual(first.lastPathComponent, "split.7z.001", "the first volume is the result")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathExtension("002").path(percentEncoded: false)))

        let archive = try await Archive.open(first)
        XCTAssertGreaterThan(archive.volumeCount, 1)
        XCTAssertFalse(archive.entries.contains { $0.path.hasSuffix(".DS_Store") })
        let method = archive.entries.first { $0.path == "tree/hello.txt" }?.method ?? ""
        XCTAssertTrue(method.uppercased().hasPrefix("PPMD"), method)
    }
}
