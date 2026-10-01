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
}
