//
//  ArchiveNaming.swift
//  7-Mac
//
//  Where an extraction lands and what a new archive is called.
//

import Foundation
import SevenZipKit

nonisolated enum ArchiveNaming {
    /// Extensions a *drop* reads as "unpack me".
    ///
    /// Deliberately narrower than what the engine opens. The engine also
    /// claims `exe`, `swf`, `dat` and `bin` — it really can look inside a PE
    /// image — but someone dragging one of those onto an archiver means
    /// "compress this" far more often than "unpack this". The Extract command
    /// has no such filter: there, the engine decides.
    static let droppedArchiveExtensions: Set<String> = [
        "7z", "zip", "zipx", "jar", "war", "apk", "ipa",
        "rar", "cbr", "cbz", "cb7", "cbt",
        "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "lz", "lzh", "lha", "arj", "z", "taz",
        "cab", "cpio", "deb", "rpm", "xar", "wim", "swm", "esd",
        "iso", "udf", "squashfs", "sfs", "chm", "msi",
        "001",
    ]

    /// Everything the engine claims, asked rather than assumed.
    static let engineExtensions: Set<String> = Set(
        SevenZip.formats.flatMap(\.fileExtensions).map { $0.lowercased() })

    /// Whether a drop of this URL should extract rather than compress.
    static func looksLikeArchive(_ url: URL) -> Bool {
        guard !isDirectory(url) else { return false }
        return droppedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// `archive.tar.gz` → `archive`, `notes.2026.zip` → `notes.2026`.
    ///
    /// Two passes at most, and only over extensions the engine recognises, so
    /// a version number in the middle of a name survives.
    static func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        for _ in 0..<2 {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty,
                  droppedArchiveExtensions.contains(ext) || engineExtensions.contains(ext)
            else { break }
            let stripped = (name as NSString).deletingPathExtension
            guard !stripped.isEmpty else { break }
            name = stripped
        }
        return name
    }

    /// `url`, or `url 2`, `url 3`… — the first name nothing occupies.
    static func unique(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for suffix in 2...999 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let candidate = directory.appending(component: name)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return directory.appending(component: "\(base) \(UUID().uuidString)")
    }

    /// Where the contents of `archive` should go, given a writable `base`.
    ///
    /// An archive with a single top-level entry unpacks straight into `base`:
    /// wrapping `project/` in a folder called `project` is the "double folder"
    /// everyone complains about. Anything else gets a folder named after the
    /// archive, so a tarbomb cannot scatter forty files over the Desktop.
    ///
    /// The single-root shortcut is dropped when the name is already taken —
    /// merging into an existing tree is not something to do silently.
    static func extractionDestination(entries: [SZKArchiveEntry],
                                      archive: URL,
                                      in base: URL) -> URL {
        let roots = Set(entries.compactMap {
            $0.path.split(separator: "/").first.map(String.init)
        })
        if roots.count == 1, let root = roots.first {
            let occupied = FileManager.default.fileExists(
                atPath: base.appending(component: root).path(percentEncoded: false))
            if !occupied { return base }
        }
        return unique(base.appending(component: stem(of: archive)))
    }

    /// A suggested archive name for `sources`: the item's own name for one
    /// item, `Archive` for several.
    static func suggestedArchiveName(for sources: [URL]) -> String {
        guard let first = sources.first else { return String(localized: "Archive") }
        return sources.count == 1 ? stem(of: first) : String(localized: "Archive")
    }

    /// The folder new output should sit in: the deepest one every source is
    /// under, which for the usual case of a multiple selection in one window
    /// is simply that window's folder.
    static func commonParent(of urls: [URL]) -> URL? {
        guard var shared = urls.first?.deletingLastPathComponent().standardized.pathComponents
        else { return nil }

        for url in urls.dropFirst() {
            let other = url.deletingLastPathComponent().standardized.pathComponents
            let shorter = min(shared.count, other.count)
            var matching = 0
            while matching < shorter, shared[matching] == other[matching] { matching += 1 }
            shared = Array(shared.prefix(matching))
        }
        guard !shared.isEmpty else { return nil }
        return URL(filePath: NSString.path(withComponents: shared), directoryHint: .isDirectory)
    }
}
