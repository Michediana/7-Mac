//
//  ArchiveExtensions.swift
//  7-Mac, 7-MacFinder
//
//  Which file names read as archives. Compiled into both targets, so the
//  Finder menu and a drop on the window never disagree.
//

import Foundation

nonisolated enum ArchiveExtensions {
    static let dropped: Set<String> = [
        "7z", "zip", "zipx", "jar", "war", "apk", "ipa",
        "rar", "cbr", "cbz", "cb7", "cbt",
        "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "lz", "lzh", "lha", "arj", "z", "taz",
        "cab", "cpio", "deb", "rpm", "xar", "wim", "swm", "esd",
        "iso", "udf", "squashfs", "sfs", "chm", "msi",
        "001",
    ]

    /// Whether a file of this name reads as an archive.
    static func matches(_ name: String) -> Bool {
        dropped.contains((name as NSString).pathExtension.lowercased())
            || joinedName(ofFirstSplitPiece: name) != nil
    }

    /// `site.tgz.aa` → `site.tgz`. What `split` leaves when it cuts a file
    /// up — `.aa`, `.ab`… — and the first piece stands for the set, as `.001`
    /// does for 7-Zip's own volumes; the engine finds the rest. Only after an
    /// archive extension: `notes.aa` is nobody's archive.
    static func joinedName(ofFirstSplitPiece name: String) -> String? {
        guard (name as NSString).pathExtension.lowercased() == "aa" else { return nil }
        let joined = (name as NSString).deletingPathExtension
        return dropped.contains((joined as NSString).pathExtension.lowercased()) ? joined : nil
    }
}
