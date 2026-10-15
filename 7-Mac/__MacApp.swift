//
//  __MacApp.swift
//  7-Mac
//
//  Created by Michele Diana on 21/09/2026.
//

import SwiftUI

@main
struct __MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // One main window, opened by hand: an archive opened from the
        // Finder to browse should bring up its browser and nothing else.
        // No window is restored either -- see the app delegate.
        Window("7-Mac", id: WindowID.main) {
            ContentView()
                .environment(model)
        }
        // Files from the Finder go to the app delegate, which decides.
        // Left to itself SwiftUI would open this window for each one.
        .handlesExternalEvents(matching: [])
        .commands { SevenMacCommands(model: model) }

        WindowGroup("Archive", id: WindowID.browser, for: BrowserTarget.self) { $target in
            if let target {
                BrowserWindow(target: target, model: model)
                    .environment(model)
            }
        }
        .defaultSize(width: 920, height: 580)
        .handlesExternalEvents(matching: [])

        WindowGroup("Checksums", id: WindowID.checksums, for: ChecksumTarget.self) { $target in
            if let target {
                ChecksumWindow(target: target)
            }
        }
        .defaultSize(width: 820, height: 420)
        .handlesExternalEvents(matching: [])

        Window("About 7-Mac", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        Window("7-Zip Engine", id: WindowID.engine) {
            EngineInfoView()
        }
        .defaultSize(width: 640, height: 480)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let about = "about"
    static let engine = "engine"
    static let browser = "browser"
    static let checksums = "checksums"
}

struct SevenMacCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = model.install(openWindow)
        // The standard panel has no room for the licences 7-Zip asks to be
        // shown with it.
        CommandGroup(replacing: .appInfo) {
            Button("About 7-Mac") { openWindow(id: WindowID.about) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.chooseArchivesToBrowse() }
                .keyboardShortcut("o")
            Button("Extract…") { model.chooseArchivesToExtract() }
                .keyboardShortcut("e")
            Button("Compress…") { model.chooseItemsToCompress() }
                .keyboardShortcut("n")
            Divider()
            Button("Test Archive…") { model.chooseArchivesToTest() }
                .keyboardShortcut("t")
            Button("Checksums…") { model.chooseItemsForChecksums() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Cancel All Jobs") { model.queue.cancelAll() }
                .disabled(!model.queue.isBusy)
            Button("Clear Finished Jobs") { model.queue.clearFinished() }
                .disabled(!model.queue.hasFinishedJobs)
        }
        CommandGroup(replacing: .help) {
            Button("7-Zip Engine") { openWindow(id: WindowID.engine) }
            Button("Licences") { openWindow(id: WindowID.about) }
        }
    }
}
