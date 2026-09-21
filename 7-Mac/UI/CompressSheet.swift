//
//  CompressSheet.swift
//  7-Mac
//
//  Format, preset, destination, password — the whole of "make me an archive".
//

import SwiftUI

struct CompressSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: CompressionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compress \(summary)")
                .font(.headline)
                .padding(.bottom, 12)

            Form {
                Picker("Format", selection: $draft.formatName) {
                    ForEach(draft.availableFormats, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: draft.formatName) { draft.formatChanged() }

                Picker("Compression", selection: $draft.preset) {
                    ForEach(CompressionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text(draft.preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Save as") {
                    HStack(spacing: 8) {
                        Text(draft.output.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Change…") { draft.chooseOutput() }
                    }
                }
                Text(draft.output.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if draft.needsPermission {
                    Label("7-Mac will ask for permission to write here.",
                          systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draft.supportsPassword {
                    Section("Encryption") {
                        SecureField("Password", text: $draft.password)
                        if draft.supportsHeaderEncryption {
                            Toggle("Also hide the list of files", isOn: $draft.encryptsHeader)
                                .disabled(draft.password.isEmpty)
                            Text("The archive will not even open without the password.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(draft.formatName) archives cannot be encrypted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.compressionDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Compress") { model.startCompression(draft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var summary: String {
        draft.sources.count == 1
            ? "“\(draft.sources[0].lastPathComponent)”"
            : "\(draft.sources.count) items"
    }
}
