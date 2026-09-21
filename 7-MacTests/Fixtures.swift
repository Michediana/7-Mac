//
//  Fixtures.swift
//  7-MacTests
//
//  A small directory tree the tests archive and read back.
//
//  Fixtures are built at run time rather than committed: an archive checked
//  into git tells you the reader still works, but says nothing about the
//  writer, and the interesting cases here (encrypted headers, split volumes)
//  are exactly the ones we want both halves of.
//

import Foundation

struct Fixtures {
    let root: URL
    let tree: URL

    /// The files the tree contains, with the bytes they should hold.
    static let files: [String: String] = [
        "hello.txt": "hello from 7-Mac\n",
        "sub/nested.txt": "nested file\n",
        "unicode-é☃.txt": "non-ASCII path\n",
    ]

    /// 300 KB of incompressible data, so compression levels and solid blocks
    /// have something real to chew on.
    static let blobSize = 300 * 1024

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("7-MacTests-\(UUID().uuidString)")
        tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        for (path, contents) in Self.files {
            try contents.write(to: tree.appendingPathComponent(path),
                               atomically: true, encoding: .utf8)
        }

        var blob = Data(count: Self.blobSize)
        blob.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        try blob.write(to: tree.appendingPathComponent("blob.bin"))

        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("link.txt"), withDestinationURL: URL(fileURLWithPath: "hello.txt"))
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A scratch path inside the fixture directory, for archives and output.
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// Compares an extracted copy of `tree` against the original, byte for
    /// byte, including whether symlinks came back as symlinks.
    static func differences(between original: URL, and extracted: URL) -> [String] {
        var problems: [String] = []
        let manager = FileManager.default

        for (path, expected) in files {
            let url = extracted.appendingPathComponent(path)
            guard let actual = try? String(contentsOf: url, encoding: .utf8) else {
                problems.append("missing: \(path)")
                continue
            }
            if actual != expected { problems.append("contents differ: \(path)") }
        }

        let blobOriginal = try? Data(contentsOf: original.appendingPathComponent("blob.bin"))
        let blobExtracted = try? Data(contentsOf: extracted.appendingPathComponent("blob.bin"))
        if blobOriginal == nil || blobOriginal != blobExtracted {
            problems.append("contents differ: blob.bin")
        }

        let link = extracted.appendingPathComponent("link.txt").path
        if let attributes = try? manager.attributesOfItem(atPath: link),
           attributes[.type] as? FileAttributeType != .typeSymbolicLink {
            problems.append("link.txt came back as a regular file, not a symlink")
        }

        return problems
    }
}
