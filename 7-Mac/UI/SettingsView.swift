//
//  SettingsView.swift
//  7-Mac
//

import SwiftUI
import SevenZipKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Opening") {
                Picker("Opening an archive from the Finder", selection: $preferences.openAction) {
                    ForEach(OpenAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Text("Dropping an archive on the 7-Mac window always extracts it. File › Open… always shows its contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Extracting") {
                Picker("Put files", selection: $preferences.destinationPolicy) {
                    ForEach(DestinationPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                if preferences.destinationPolicy == .fixedFolder {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(preferences.fixedDestination?.lastPathComponent ?? String(localized: "Not chosen"))
                                .foregroundStyle(preferences.fixedDestination == nil ? .secondary : .primary)
                            Spacer(minLength: 0)
                            Button("Choose…") { chooseFixedFolder() }
                        }
                    }
                }
                Picker("If a file is already there", selection: $preferences.overwritePolicy) {
                    ForEach(SZKOverwritePolicy.offered, id: \.rawValue) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Toggle("Show the result in the Finder", isOn: $preferences.revealWhenDone)
            }

            Section("Compressing") {
                Toggle("Leave out macOS system files", isOn: $preferences.excludesSystemFiles)
                if preferences.excludesSystemFiles {
                    TextField("Names", text: Binding(
                        get: { preferences.excludedNames.joined(separator: ", ").replacingOccurrences(of: "\r", with: "\\r") },
                        set: { preferences.excludedNames = Self.names(from: $0) }),
                              axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Text("Separate with commas. `*` and `?` work as in the Terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Defaults") {
                            preferences.excludedNames = Preferences.defaultExcludedNames
                        }
                        .controlSize(.small)
                    }
                }
                Toggle("Store symbolic links as links", isOn: $preferences.storesSymbolicLinks)
                (preferences.storesSymbolicLinks
                     ? Text("A link is stored as a link and comes back as one.")
                     : Text("A link is followed, and what it points to is stored in its place."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Store hard links as links", isOn: $preferences.storesHardLinks)
            }

            Section("Passwords") {
                Toggle("Offer to remember passwords in the keychain",
                       isOn: $preferences.offersKeychain)
                Text("A password is only ever saved when you tick the box in the prompt. Turning this off also stops 7-Mac using the ones it saved before. Saved passwords are keyed to the archive's path, so moving the file forgets it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folder permissions") {
                Text("The sandbox grants access to the files you drop, not to the folders around them. Folders you have allowed 7-Mac to write into are remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Forget Allowed Folders") { FolderAccess.shared.forgetEverything() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `a, b ,, c` → `["a", "b", "c"]`. `Icon\r`, the Finder's custom icon
    /// file, is written as `Icon\r` here and stored with its real carriage
    /// return.
    static func names(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\r", with: "\r") }
            .filter { !$0.isEmpty }
    }

    private func chooseFixedFolder() {
        Task {
            if let folder = await model.askWritableFolder(
                message: String(localized: "Choose the folder extractions should go into."), suggesting: nil) {
                model.preferences.fixedDestination = folder
            }
        }
    }
}
