//
//  PermissionsView.swift
//  7-Mac
//
//  The sheet behind Settings › Check Permissions…: what the system currently
//  allows, and what to do about anything that is not right.
//

import AppKit
import FinderSync
import SwiftUI

struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var finder: [PermissionCheck] = []
    @State private var folders: [PermissionCheck] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Finder") {
                    ForEach(finder) { row($0) }
                }
                Section {
                    ForEach(folders) { row($0) }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Folders protected by macOS itself, such as the Photos library, stay closed to every app whatever you allow here. 7-Mac skips them and says so.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Allow a Folder…") { allowFolder() }
                Button("Forget All Folders") {
                    FolderAccess.shared.forgetEverything()
                    refresh()
                }
                .disabled(FolderAccess.shared.grantedFolders.isEmpty)
                Spacer()
                Button("Check Again") { refresh() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func row(_ check: PermissionCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(check.status))
                .foregroundStyle(tint(check.status))
                .accessibilityLabel(label(check.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch check.action {
            case .manageFinderExtension:
                Button(check.status == .ok ? "Manage…" : "Turn On…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            case .forget(let folder):
                Button("Remove") {
                    FolderAccess.shared.forget(folder)
                    refresh()
                }
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        finder = PermissionReport.finderChecks()
        folders = PermissionReport.folderChecks()
    }

    private func allowFolder() {
        Task {
            _ = await model.askWritableFolder(
                message: String(localized: "Choose a folder 7-Mac may use without asking. Everything inside it is included: your home folder covers almost everything."),
                suggesting: PermissionReport.realHome)
            refresh()
        }
    }

    private func symbol(_ status: PermissionCheck.Status) -> String {
        switch status {
        case .ok:      "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private func tint(_ status: PermissionCheck.Status) -> Color {
        switch status {
        case .ok:      .green
        case .warning: .orange
        case .problem: .red
        }
    }

    private func label(_ status: PermissionCheck.Status) -> String {
        switch status {
        case .ok:      String(localized: "OK")
        case .warning: String(localized: "Needs attention")
        case .problem: String(localized: "Not working")
        }
    }
}
