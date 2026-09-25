//
//  CompressionProfile.swift
//  7-Mac
//
//  Everything that decides how an archive is compressed, as one value that
//  can be named, saved and picked again — and what it will cost in memory.
//
//  The three presets of M2 are profiles too, with only a level set: every
//  other choice left to the engine's own defaults, which are good ones.
//

import Foundation
import SevenZipKit

/// A compression method, as `-m` names it.
nonisolated enum CompressionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case lzma2 = "LZMA2"
    case lzma = "LZMA"
    case ppmd = "PPMd"
    case bzip2 = "BZip2"
    case deflate = "Deflate"
    case deflate64 = "Deflate64"
    case copy = "Copy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lzma2:     "LZMA2"
        case .lzma:      "LZMA"
        case .ppmd:      String(localized: "PPMd (text)")
        case .bzip2:     "BZip2"
        case .deflate:   "Deflate"
        case .deflate64: "Deflate64"
        case .copy:      String(localized: "None (store)")
        }
    }

    /// What `format` can hold, the default first. Formats not listed choose
    /// their method themselves (tar stores, gzip deflates, xz is LZMA2).
    static func offered(for format: String) -> [CompressionMethod] {
        switch format {
        case "7z":  [.lzma2, .lzma, .ppmd, .bzip2, .deflate, .copy]
        case "zip": [.deflate, .deflate64, .bzip2, .lzma, .ppmd, .copy]
        default:    []
        }
    }

    /// Whether the method has a dictionary (or, for PPMd, a model size) the
    /// person can choose.
    var hasDictionary: Bool {
        switch self {
        case .lzma2, .lzma, .ppmd: true
        default:                   false
        }
    }
}

/// How a 7z archive groups files into blocks. Bigger blocks compress
/// better; smaller ones let a single file come out without decoding the rest.
nonisolated enum SolidMode: Codable, Hashable, Sendable {
    case automatic
    case off
    case blockSize(UInt64)
    case wholeArchive

    /// `-ms` as the engine takes it; `nil` leaves the engine's choice.
    var property: String? {
        switch self {
        case .automatic:            nil
        case .off:                  "off"
        case .wholeArchive:         "on"
        case .blockSize(let bytes): "\(bytes >> 20)m"
        }
    }

    static let offered: [SolidMode] = [
        .automatic, .off, .blockSize(64 << 20), .blockSize(256 << 20),
        .blockSize(1 << 30), .blockSize(4 << 30), .wholeArchive,
    ]

    var title: String {
        switch self {
        case .automatic:            String(localized: "Automatic")
        case .off:                  String(localized: "Off — every file on its own")
        case .wholeArchive:         String(localized: "One block for everything")
        case .blockSize(let bytes): String(localized: "Blocks of \(Display.bytes(bytes))")
        }
    }
}

nonisolated struct CompressionProfile: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var format: String
    /// 7-Zip's 0…9 scale.
    var level: Int
    /// `nil` for the format's own default.
    var method: CompressionMethod?
    /// Bytes; `nil` for the level's default. For PPMd, the model size.
    var dictionary: UInt64?
    var solid: SolidMode = .automatic
    /// `nil` for as many as the machine has.
    var threads: Int?

    /// The built-in three, which cannot be edited or deleted.
    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    /// The name to show: the built-in ones are translated, a saved one is
    /// what the person typed.
    var displayName: String {
        switch id {
        case Self.fast.id:    String(localized: "Fast")
        case Self.normal.id:  String(localized: "Normal")
        case Self.maximum.id: String(localized: "Maximum")
        default:              name
        }
    }

    static let fast = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000F457")!,
        name: "Fast", format: "7z", level: 3)
    static let normal = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        name: "Normal", format: "7z", level: 5)
    static let maximum = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A9")!,
        name: "Maximum", format: "7z", level: 9)
    static let builtIn = [fast, normal, maximum]

    /// The method that will actually be used.
    var effectiveMethod: CompressionMethod? {
        let offered = CompressionMethod.offered(for: format)
        if let method, offered.contains(method) { return method }
        if let first = offered.first { return first }
        switch format {
        case "xz":    return .lzma2
        case "gzip":  return .deflate
        case "bzip2": return .bzip2
        default:      return nil
        }
    }

    /// The dictionary that will actually be asked for: the chosen one, or
    /// the one the engine picks for this level (LzmaEnc.c, PpmdEncoder.cpp).
    /// The engine may still shrink it to fit a small input.
    var effectiveDictionary: UInt64? {
        guard let method = effectiveMethod else { return nil }
        switch method {
        case .lzma2, .lzma:
            if let dictionary { return dictionary }
            let level = UInt64(max(0, min(9, self.level)))
            if level <= 4 { return 1 << (level * 2 + 16) }
            if level <= 8 { return 1 << (level + 20) }
            return 1 << 28
        case .ppmd:
            return dictionary ?? (1 << UInt64(max(0, min(9, level)) + 19))
        case .deflate:   return 32 << 10
        case .deflate64: return 64 << 10
        case .bzip2:     return 900 << 10
        case .copy:      return nil
        }
    }

    /// `-m` properties for the engine. Only what differs from its defaults.
    var methodProperties: [String: String] {
        var properties: [String: String] = [:]
        if let method, CompressionMethod.offered(for: format).contains(method) {
            properties["m"] = method.rawValue
        }
        if let dictionary, effectiveMethod?.hasDictionary == true {
            // PPMd calls it `mem`; LZMA and LZMA2 call it `d`.
            properties[effectiveMethod == .ppmd ? "mem" : "d"] = "\(dictionary >> 10)k"
        }
        if format == "7z", let solid = solid.property {
            properties["s"] = solid
        }
        if let threads {
            properties["mt"] = "\(threads)"
        }
        return properties
    }

    var compressionLevel: SZKCompressionLevel {
        SZKCompressionLevel(rawValue: max(0, min(9, level))) ?? .normal
    }

    /// Dictionary sizes worth offering for `method`.
    static func dictionaries(for method: CompressionMethod) -> [UInt64] {
        switch method {
        case .lzma2, .lzma:
            [64 << 10, 1 << 20, 4 << 20, 16 << 20, 32 << 20, 64 << 20,
             128 << 20, 256 << 20, 512 << 20, 1 << 30]
        case .ppmd:
            [1 << 20, 4 << 20, 16 << 20, 64 << 20, 256 << 20, 1 << 30]
        default:
            []
        }
    }
}

// MARK: - Memory

/// What compressing and decompressing will take, by the same arithmetic as
/// 7-Zip's own compress dialog (UI/GUI/CompressDialog.cpp,
/// GetMemoryUsage_Threads_Dict_DecompMem). An estimate — the engine may use
/// less for a small input — but the one 7-Zip itself shows.
nonisolated struct MemoryEstimate: Equatable, Sendable {
    let compress: UInt64
    let decompress: UInt64
    /// Threads the engine will really run: for "automatic" LZMA2 it drops
    /// threads until the estimate fits 80% of the RAM, and so do we.
    var threads: Int?

    init(compress: UInt64, decompress: UInt64, threads: Int? = nil) {
        self.compress = compress
        self.decompress = decompress
        self.threads = threads
    }

    init?(_ profile: CompressionProfile,
          processors: Int = ProcessInfo.processInfo.activeProcessorCount,
          physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let level = max(0, min(9, profile.level))
        guard let method = profile.effectiveMethod else { return nil }
        if level == 0 || method == .copy {
            self.init(compress: 1 << 20, decompress: 1 << 20)
            return
        }
        let threads = UInt64(max(1, profile.threads ?? processors))
        let dictionary = profile.effectiveDictionary ?? 0

        var size: UInt64 = 0
        // 7z's strongest levels add a BCJ2 filter for executables.
        if profile.format == "7z" && level >= 9 {
            size += (12 << 20) * 2 + (5 << 20)
        }
        var zipThreads: UInt64 = 1
        if profile.format == "zip" {
            let subThreads: UInt64 = (method == .lzma && threads > 1 && level >= 5) ? 2 : 1
            zipThreads = threads / subThreads
            if zipThreads > 1 {
                size += zipThreads * (UInt64(MemoryLayout<Int>.size) << 23)
            } else {
                zipThreads = 1
            }
        }

        switch method {
        case .lzma, .lzma2:
            let dict = min(dictionary, UInt64(15) << 28)
            var hs = UInt32(truncatingIfNeeded: dict) &- 1
            hs |= hs >> 1; hs |= hs >> 2; hs |= hs >> 4; hs |= hs >> 8
            hs >>= 1
            if hs >= 1 << 24 { hs >>= 1 }
            hs |= (1 << 16) - 1
            if level < 5 { hs |= (256 << 10) - 1 }
            let hashSize = UInt64(hs) + 1

            var perThread = hashSize * 4 + dict * 4
            if level >= 5 { perThread += dict * 4 }
            perThread += 2 << 20
            var matchThreads: UInt64 = 1
            if threads > 1 && level >= 5 {
                perThread += (2 << 20) + (4 << 20)
                matchThreads = 2
            }
            var blockThreads = threads / matchThreads
            if blockThreads == 0 { blockThreads = 1 }

            if method == .lzma2 && blockThreads != 1 {
                let chunk = Self.lzma2ChunkSize(dict)
                func usage(_ blocks: UInt64) -> UInt64 {
                    var packChunks = blocks + blocks / 8 + 1
                    if chunk < 1 << 26 { packChunks += 1 }
                    if chunk < 1 << 24 { packChunks += 1 }
                    if chunk < 1 << 22 { packChunks += 1 }
                    return size + blocks * (perThread + chunk) + packChunks * chunk
                }
                // 7zHandlerOut.cpp: with threads left to the engine, block
                // threads are dropped until the total fits 80% of the RAM.
                if profile.threads == nil && (profile.format == "7z" || profile.format == "xz") {
                    let limit = physicalMemory / 100 * 80
                    while blockThreads > 1 && usage(blockThreads) > limit { blockThreads -= 1 }
                }
                if blockThreads > 1 {
                    self.init(compress: usage(blockThreads), decompress: dict + (2 << 20),
                              threads: Int(blockThreads * matchThreads))
                    return
                }
            }
            do {
                var block = dict + (1 << 16) + (matchThreads > 1 ? 1 << 20 : 0)
                block += block >> (block < 1 << 30 ? 1 : 2)
                block = min(block, UInt64(UInt32.max - (1 << 16) + 1))
                size += perThread + block
            }
            self.init(compress: size, decompress: dict + (2 << 20), threads: Int(matchThreads))

        case .ppmd:
            let decompress = dictionary + (2 << 20)
            // In zip every thread holds its own model; in 7z there is one.
            self.init(compress: size + decompress * (profile.format == "zip" ? threads : 1),
                      decompress: decompress)

        case .deflate, .deflate64:
            self.init(compress: size + ((3 << 20) + (1 << 20)) * zipThreads, decompress: 2 << 20)

        case .bzip2:
            self.init(compress: size + (10 << 20) * threads, decompress: 7 << 20)

        case .copy:
            self.init(compress: 1 << 20, decompress: 1 << 20)
        }
    }

    /// Get_Lzma2_ChunkSize in CompressDialog.cpp.
    static func lzma2ChunkSize(_ dictionary: UInt64) -> UInt64 {
        let minimum: UInt64 = 1 << 20
        var size = min(max(dictionary << 2, minimum), 1 << 28)
        size = max(size, dictionary)
        size += minimum - 1
        return size & ~(minimum - 1)
    }

    /// Whether compressing would crowd the machine: past the 80% of RAM the
    /// engine itself allows when it picks the threads. Only a dictionary or
    /// a thread count chosen by hand gets there.
    func isExcessive(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        compress > physicalMemory / 100 * 80
    }
}
