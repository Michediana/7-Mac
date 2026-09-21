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
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .commands { SevenMacCommands(model: model) }

        Window("7-Zip Engine", id: WindowID.engine) {
            EngineInfoView()
        }
        .defaultSize(width: 640, height: 480)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let engine = "engine"
}

struct SevenMacCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Extract…") { model.chooseArchivesToExtract() }
                .keyboardShortcut("e")
            Button("Compress…") { model.chooseItemsToCompress() }
                .keyboardShortcut("n")
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
        }
    }
}
