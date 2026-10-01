//
//  WelcomeView.swift
//  7-Mac
//
//  The sheet the first launch opens with: two questions only the person can
//  answer — whether archives should open in 7-Mac, and whether to add its
//  menu to the Finder's right-click — each a click away from being skipped.
//

import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case defaultApp
        case finderMenu
    }

    @State private var step = Step.defaultApp
    @State private var isWorking = false
    /// Set when the system turned down part of the request.
    @State private var refusal: String?
    @State private var finderMenuEnabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .defaultApp: defaultApp
                case .finderMenu: finderMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()
            HStack {
                Text(step == .defaultApp ? "1 of 2" : "2 of 2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                buttons
            }
            .padding(16)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finderMenuEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }

    // MARK: - Steps

    private var defaultApp: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Open archives with 7-Mac?")
                    .font(.title2.bold())
                Text("Double-clicking a .zip, .7z, .rar or any other archive 7-Mac can read will open it here. Disc images keep opening as they do now.")
                Text("You can change this later in Settings, or for a single type in the Finder’s Get Info window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finderMenu: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "contextualmenu.and.cursorarrow")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Add 7-Mac to the Finder’s menu?")
                    .font(.title2.bold())
                Text("Right-click files in the Finder to extract, open, test or compress them with 7-Mac.")
                Text("macOS asks you to allow this yourself: in System Settings, under Login Items & Extensions, turn on 7-Mac’s Finder extension, then come back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(finderMenuEnabled ? "Turned on" : "Not turned on yet",
                      systemImage: finderMenuEnabled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(finderMenuEnabled ? .green : .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch step {
        case .defaultApp:
            if refusal != nil {
                Button("Continue") { step = .finderMenu }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { step = .finderMenu }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Use 7-Mac") { makeDefault() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        case .finderMenu:
            if finderMenuEnabled {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { finish() }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func makeDefault() {
        isWorking = true
        Task {
            let refused = await DefaultArchiveApp.makeDefault()
            isWorking = false
            if refused.isEmpty {
                step = .finderMenu
            } else {
                let names = refused.map { $0.preferredFilenameExtension.map { ".\($0)" } ?? $0.identifier }
                refusal = String(localized: "macOS did not let 7-Mac open these: \(names.formatted(.list(type: .and))). Try again from Settings › Opening.")
            }
        }
    }

    private func finish() {
        model.preferences.hasShownWelcome = true
        dismiss()
    }
}
