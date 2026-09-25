//
//  CompressSheet.swift
//  7-Mac
//
//  Format, profile, destination, password — the whole of "make me an
//  archive". The advanced settings are there for whoever wants them and out
//  of the way for everyone else.
//

import SwiftUI

struct CompressSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: CompressionDraft
    @State private var showsAdvanced = false
    @State private var isNamingProfile = false
    @State private var newProfileName = ""

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

                profilePicker

                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    AdvancedSettings(draft: draft)
                }

                MemoryLine(estimate: draft.memory)

                Picker("Split into volumes", selection: $draft.volumeSize) {
                    ForEach(VolumeSize.offered, id: \.bytes) { size in
                        Text(size.title).tag(size.bytes)
                    }
                }

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
        .frame(width: 520)
        .frame(maxHeight: 720)
        .alert("Save Preset", isPresented: $isNamingProfile) {
            TextField("Name", text: $newProfileName)
            Button("Save") {
                let name = newProfileName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { draft.saveProfile(named: name) }
            }
            .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Format, level, method, dictionary, solid blocks and threads are saved. A preset with the same name is replaced.")
        }
    }

    private var profilePicker: some View {
        LabeledContent("Preset") {
            HStack(spacing: 8) {
                Picker("Preset", selection: Binding(get: { draft.profileID },
                                                    set: { draft.choose($0) })) {
                    ForEach(CompressionProfile.builtIn) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                    let saved = model.preferences.profiles.filter { !$0.isBuiltIn }
                    if !saved.isEmpty {
                        Divider()
                        ForEach(saved) { profile in
                            Text("\(profile.name) (\(profile.format))").tag(profile.id)
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()

                if draft.isModified {
                    Text("modified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Save as Preset…") {
                        let current = model.preferences.profile(withID: draft.profileID)
                        newProfileName = current.isBuiltIn ? "" : current.name
                        isNamingProfile = true
                    }
                    Button("Delete Preset", role: .destructive) {
                        model.preferences.deleteProfile(draft.profileID)
                        draft.choose(CompressionProfile.normal.id)
                    }
                    .disabled(model.preferences.profile(withID: draft.profileID).isBuiltIn)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Preset actions")
            }
        }
    }

    private var summary: String {
        draft.sources.count == 1
            ? "“\(draft.sources[0].lastPathComponent)”"
            : Display.count(UInt64(draft.sources.count), "item", "items")
    }
}

/// Level, method, dictionary, solid blocks, threads.
private struct AdvancedSettings: View {
    @Bindable var draft: CompressionDraft

    var body: some View {
        Picker("Level", selection: $draft.profile.level) {
            ForEach(Self.levels, id: \.0) { level, title in
                Text(title).tag(level)
            }
        }

        if !draft.availableMethods.isEmpty {
            Picker("Method", selection: methodBinding) {
                ForEach(draft.availableMethods) { method in
                    Text(method.title).tag(method)
                }
            }
        }

        if let method = draft.profile.effectiveMethod, method.hasDictionary,
           !draft.availableMethods.isEmpty {
            Picker(selection: $draft.profile.dictionary) {
                Text("Default (\(Display.bytes(defaultDictionary ?? 0)))").tag(UInt64?.none)
                ForEach(CompressionProfile.dictionaries(for: method), id: \.self) { size in
                    Text(Display.bytes(size)).tag(UInt64?.some(size))
                }
            } label: {
                method == .ppmd ? Text("Model size") : Text("Dictionary")
            }
        }

        if draft.formatName == "7z" {
            Picker("Solid blocks", selection: $draft.profile.solid) {
                ForEach(SolidMode.offered, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }

        Picker("Threads", selection: $draft.profile.threads) {
            Text("Automatic (\(ProcessInfo.processInfo.activeProcessorCount))").tag(Int?.none)
            ForEach(1...max(1, ProcessInfo.processInfo.activeProcessorCount), id: \.self) { count in
                Text("\(count)").tag(Int?.some(count))
            }
        }
    }

    /// Choosing a method resets the dictionary: sizes do not carry over
    /// between LZMA and PPMd.
    private var methodBinding: Binding<CompressionMethod> {
        Binding(get: { draft.profile.effectiveMethod ?? draft.availableMethods[0] },
                set: { method in
                    if method != draft.profile.effectiveMethod { draft.profile.dictionary = nil }
                    draft.profile.method = method
                })
    }

    private var defaultDictionary: UInt64? {
        var probe = draft.profile
        probe.dictionary = nil
        return probe.effectiveDictionary
    }

    static let levels: [(Int, String)] = [
        (0, String(localized: "Store — no compression")), (1, String(localized: "Fastest")),
        (3, String(localized: "Fast")), (5, String(localized: "Normal")),
        (7, String(localized: "Maximum")), (9, String(localized: "Ultra")),
    ]
}

/// "About 1.2 GB to compress, 66 MB to open", and a warning when that is
/// more than the machine comfortably has.
private struct MemoryLine: View {
    let estimate: MemoryEstimate?

    var body: some View {
        if let estimate {
            let excessive = estimate.isExcessive()
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let threads = estimate.threads {
                        Text("About \(Display.bytes(estimate.compress)) of memory to compress with \(Display.count(UInt64(threads), "thread", "threads")), \(Display.bytes(estimate.decompress)) to extract.")
                    } else {
                        Text("About \(Display.bytes(estimate.compress)) of memory to compress, \(Display.bytes(estimate.decompress)) to extract.")
                    }
                    if excessive {
                        Text("That is more than this Mac can spare. Choose a smaller dictionary or fewer threads.")
                            .foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(systemName: excessive ? "exclamationmark.triangle.fill" : "memorychip")
                    .foregroundStyle(excessive ? Color.orange : Color.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Volume sizes people actually need: media that still exists, and the
/// FAT32 file size limit that still bites.
nonisolated struct VolumeSize: Sendable {
    let bytes: UInt64
    let title: String

    static let offered: [VolumeSize] = [
        VolumeSize(bytes: 0, title: String(localized: "No — one file")),
        VolumeSize(bytes: 10 << 20, title: "10 MB"),
        VolumeSize(bytes: 100 << 20, title: "100 MB"),
        VolumeSize(bytes: 650 << 20, title: "650 MB (CD)"),
        VolumeSize(bytes: 700 << 20, title: "700 MB (CD)"),
        VolumeSize(bytes: 1 << 30, title: "1 GB"),
        VolumeSize(bytes: 4095 << 20, title: "4 GB (FAT32 limit)"),
        VolumeSize(bytes: 4_480 << 20, title: "4.7 GB (DVD)"),
    ]
}
