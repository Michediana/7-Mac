//
//  Permissions.swift
//  7-Mac
//
//  Everything the sandbox and the Finder decide for us, asked and listed in
//  one place: Settings › Permissions › Check Permissions….
//
//  Each answer comes from the system at the moment of asking, never from what
//  7-Mac remembers having been told, so the list is also how to tell a grant
//  that has quietly stopped working.
//

import AppKit
import FinderSync
import Foundation

struct PermissionCheck: Identifiable {
    enum Status {
        case ok
        case warning
        case problem
    }

    enum Action {
        case manageFinderExtension
        case forget(URL)
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
    var action: Action?
}

@MainActor
enum PermissionReport {
    static func finderChecks() -> [PermissionCheck] {
        let enabled = FIFinderSyncController.isExtensionEnabled
        var checks = [
            PermissionCheck(
                id: "finder.enabled",
                title: String(localized: "7-Mac menu in the Finder"),
                detail: enabled
                    ? String(localized: "Turned on in System Settings.")
                    : String(localized: "Turned off. Turn it on in System Settings, under Login Items & Extensions."),
                status: enabled ? .ok : .warning,
                action: .manageFinderExtension),
        ]
        if enabled {
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            let (status, detail) = finderMenuLoad(lastBeat: FinderMenuHeartbeat.lastBeat,
                                                  finderLaunched: finder?.launchDate)
            checks.append(PermissionCheck(id: "finder.loaded",
                                          title: String(localized: "Loaded by the Finder"),
                                          detail: detail, status: status))
        }
        // Created on the first request; asking should not fail just because
        // there has not been one yet.
        let shared = FinderHandoff.directory.map { directory in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return canWrite(directory)
        } ?? false
        checks.append(PermissionCheck(
            id: "finder.group",
            title: String(localized: "Shared with the Finder menu"),
            detail: shared
                ? String(localized: "The menu can hand its requests to the app.")
                : String(localized: "The container the menu and the app share cannot be written. The menu will do nothing; reinstalling 7-Mac should fix it."),
            status: shared ? .ok : .problem))
        return checks
    }

    /// Whether the extension has run since the Finder last started. Turned
    /// on is not the same as loaded: an extension that failed to launch stays
    /// switched on, and the Finder does not try it again until it restarts.
    nonisolated static func finderMenuLoad(lastBeat: Date?, finderLaunched: Date?)
        -> (PermissionCheck.Status, String)
    {
        let relaunch = String(localized: "Relaunch the Finder: hold Option, right-click its icon in the Dock and choose Relaunch.")
        guard let lastBeat else {
            return (.problem, String(localized: "The Finder has not loaded the menu yet.") + " " + relaunch)
        }
        let when = lastBeat.formatted(date: .abbreviated, time: .shortened)
        if let finderLaunched, lastBeat < finderLaunched {
            return (.problem, String(localized: "The Finder has not loaded the menu since it last started. Last loaded: \(when).") + " " + relaunch)
        }
        return (.ok, String(localized: "Last active: \(when)."))
    }

    static func folderChecks() -> [PermissionCheck] {
        var checks: [PermissionCheck] = []
        let downloads = realHome.appending(component: "Downloads", directoryHint: .isDirectory)
        let downloadsOK = canWrite(downloads)
        checks.append(PermissionCheck(
            id: "folder.downloads",
            title: String(localized: "Downloads"),
            detail: downloadsOK
                ? String(localized: "Always allowed: 7-Mac never asks for it.")
                : String(localized: "Not writable, although 7-Mac is entitled to it."),
            status: downloadsOK ? .ok : .problem))

        let granted = FolderAccess.shared.grantedFolders
        for folder in granted {
            let reachable = FolderAccess.shared.isReachable(folder)
            checks.append(PermissionCheck(
                id: "folder.\(folder.path)",
                title: displayPath(folder),
                detail: reachable
                    ? String(localized: "Allowed, with everything inside it.")
                    : String(localized: "No longer usable: the folder was moved or deleted, or the permission was withdrawn."),
                status: reachable ? .ok : .warning,
                action: .forget(folder)))
        }
        if granted.isEmpty {
            checks.append(PermissionCheck(
                id: "folder.none",
                title: String(localized: "No other folders yet"),
                detail: String(localized: "7-Mac asks the first time it needs a folder, and remembers it. Allowing your home folder covers everything in it."),
                status: .ok))
        }
        return checks
    }

    // MARK: -

    /// The home folder itself: inside the sandbox `NSHomeDirectory()` is the
    /// app's container.
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    /// `~/Pictures` rather than `/Users/name/Pictures`.
    static func displayPath(_ url: URL) -> String {
        let path = plainPath(url)
        let home = plainPath(realHome)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// A folder URL's path ends in "/"; for showing and comparing, it should not.
    private static func plainPath(_ url: URL) -> String {
        let path = url.standardized.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func canWrite(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = folder.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }
}
