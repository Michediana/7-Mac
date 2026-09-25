//
//  AppDelegate.swift
//  7-Mac
//
//  The two ways into the app that SwiftUI does not cover: files opened from
//  the Finder, and the Services menu.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        // Whatever a browser window left behind when it could not clean up.
        ArchiveBrowser.sweepAbandonedScratch()
        // Without this the entries in Info.plist only appear after the system
        // has re-scanned the app on its own schedule.
        NSUpdateDynamicServices()
    }

    /// Double-clicking a `.7z`, or dropping one on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = AppModel.shared.queue
        guard queue.isBusy else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A job is still running."
        alert.informativeText = "Quitting now leaves a half-written folder or archive behind."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Going")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            queue.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}

/// Backs the Finder's Services menu. The selectors are named in Info.plist
/// under `NSServices` / `NSMessage`.
@MainActor
final class ServicesProvider: NSObject {
    @objc
    func extractArchives(_ pasteboard: NSPasteboard,
                         userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = fileURLs(on: pasteboard) else {
            error.pointee = "7-Mac did not receive any files."
            return
        }
        NSApp.activate()
        AppModel.shared.extract(urls)
    }

    @objc
    func compressItems(_ pasteboard: NSPasteboard,
                       userData: String?,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = fileURLs(on: pasteboard) else {
            error.pointee = "7-Mac did not receive any files."
            return
        }
        NSApp.activate()
        AppModel.shared.beginCompression(of: urls)
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: options) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }
}
