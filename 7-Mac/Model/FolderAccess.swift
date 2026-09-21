//
//  FolderAccess.swift
//  7-Mac
//
//  Write access to folders, under App Sandbox.
//
//  Dropping a file on a sandboxed app grants access to *that file*, not to the
//  folder around it — so "extract next to the archive" is not something the
//  app can simply do. It has to be granted, once, through an open panel, and
//  then remembered as an app-scoped bookmark.
//
//  This is why the destination flow asks instead of failing: the first
//  extraction into a folder costs one panel, and none after that.
//

import Foundation
import OSLog

@MainActor
final class FolderAccess {
    static let shared = FolderAccess()

    private let defaultsKey = "GrantedFolderBookmarks"
    private let log = Logger(subsystem: "eu.dgnet.7-Mac", category: "sandbox")

    /// path → bookmark, as persisted.
    private var bookmarks: [String: Data]
    /// Folders whose security scope this process has opened. Held for the
    /// lifetime of the app: balancing every start with a stop would mean
    /// reference-counting overlapping jobs for no gain.
    private var opened: Set<String> = []

    private init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// Makes `folder` writable if we can, and says whether it worked.
    ///
    /// Tries, in order: the folder as it stands (a folder the user picked this
    /// session, or one outside the sandbox's reach in the first place), then a
    /// stored bookmark for it or for a folder above it.
    @discardableResult
    func prepare(_ folder: URL) -> Bool {
        let path = folder.standardized.path(percentEncoded: false)
        if isWritable(path) { return true }

        for candidate in selfAndAncestors(of: folder) {
            guard let bookmark = bookmarks[candidate] else { continue }
            guard let resolved = resolve(bookmark, for: candidate) else { continue }
            if resolved.startAccessingSecurityScopedResource() {
                opened.insert(candidate)
            }
            if isWritable(path) { return true }
        }
        return false
    }

    /// Records a folder the user just handed us through a panel, so the next
    /// job into it does not ask again.
    func grant(_ folder: URL) {
        let path = folder.standardized.path(percentEncoded: false)
        do {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            bookmarks[path] = bookmark
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        } catch {
            // Not fatal: access lasts for this launch either way.
            log.error("could not bookmark \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        if folder.startAccessingSecurityScopedResource() {
            opened.insert(path)
        }
    }

    func forgetEverything() {
        bookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: -

    private func isWritable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        // access(2) goes through the sandbox, so this answers the real question.
        return FileManager.default.isWritableFile(atPath: path)
    }

    private func selfAndAncestors(of folder: URL) -> [String] {
        var result: [String] = []
        var current = folder.standardized
        while current.pathComponents.count > 1 {
            result.append(current.path(percentEncoded: false))
            current = current.deletingLastPathComponent()
        }
        return result
    }

    private func resolve(_ bookmark: Data, for path: String) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else {
            bookmarks[path] = nil
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
            return nil
        }
        if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
            bookmarks[path] = refreshed
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        }
        return url
    }
}
