//
//  BrowserView.swift
//  7-Mac
//
//  The archive browser: every entry, what it is, and what it cost to store.
//

import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// What a browser window is opened on. Carries its own id so that opening
/// the same archive twice gives two windows rather than bringing back one
/// that may be deep inside a nested archive.
nonisolated struct BrowserTarget: Codable, Hashable, Sendable {
    var id = UUID()
    var url: URL
}

struct BrowserWindow: View {
    @State private var browser: ArchiveBrowser

    init(target: BrowserTarget, model: AppModel) {
        _browser = State(initialValue: ArchiveBrowser(url: target.url,
                                                      preferences: model.preferences,
                                                      queue: model.queue))
    }

    var body: some View {
        @Bindable var browser = browser

        Group {
            switch browser.phase {
            case .opening:
                ProgressView("Opening “\(browser.url.lastPathComponent)”…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                ContentUnavailableView {
                    Label("Could not open “\(browser.url.lastPathComponent)”",
                          systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Try Again") { Task { await browser.open() } }
                }
            case .ready:
                BrowserContent(browser: browser)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle(browser.current?.title ?? browser.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .sheet(item: $browser.passwordPrompt) { PasswordSheet(prompt: $0) }
        .alert("Something went wrong",
               isPresented: Binding(get: { browser.problem != nil },
                                    set: { if !$0 { browser.problem = nil } })) {
            Button("OK", role: .cancel) { browser.problem = nil }
        } message: {
            Text(browser.problem ?? "")
        }
        .task { await browser.open() }
        .onDisappear { browser.close() }
    }

    private var subtitle: String {
        guard let level = browser.current else { return "" }
        let tree = level.tree
        var parts = [level.archive.formatName,
                     Display.count(UInt64(tree.fileCount), "file", "files"),
                     Display.bytes(tree.totalSize)]
        if let packed = tree.totalPackedSize, tree.totalSize > 0, packed > 0 {
            parts.append("\(Display.bytes(packed)) packed")
        }
        return parts.joined(separator: " · ")
    }
}

private struct BrowserContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: ArchiveBrowser
    @SceneStorage("BrowserColumns") private var columns = TableColumnCustomization<ArchiveNode>()

    var body: some View {
        VStack(spacing: 0) {
            if browser.levels.count > 1 {
                PathBar(browser: browser)
                Divider()
            }
            table
            Divider()
            StatusBar(browser: browser)
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search names")
        .quickLookPreview($browser.previewURL)
        .toolbar { toolbar }
    }

    private var table: some View {
        Table(of: ArchiveNode.self, selection: $browser.selection,
              sortOrder: $browser.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { node in
                NameCell(node: node, showsPath: browser.isShowingMatches)
            }
            .width(min: 180, ideal: 300)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Size", value: \.sortSize) { node in
                NumberCell(text: node.size.map(Display.bytes) ?? "")
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("size")

            TableColumn("Packed", value: \.sortPackedSize) { node in
                NumberCell(text: node.packedSize.map(Display.bytes) ?? "")
            }
            .width(min: 60, ideal: 80)
            .alignment(.trailing)
            .customizationID("packed")

            TableColumn("Ratio", value: \.sortRatio) { node in
                NumberCell(text: node.ratioDescription)
            }
            .width(min: 44, ideal: 52)
            .alignment(.trailing)
            .customizationID("ratio")

            TableColumn("Method", value: \.method, comparator: .localizedStandard) { node in
                Text(node.method).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            .customizationID("method")

            TableColumn("Modified", value: \.sortModified) { node in
                Text(node.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
            .customizationID("modified")

            TableColumn("CRC", value: \.sortChecksum) { node in
                NumberCell(text: node.checksumDescription, monospaced: true)
            }
            .width(min: 70, ideal: 80)
            .customizationID("crc")
            .defaultVisibility(.hidden)

            TableColumn("Permissions", value: \.sortPermissions) { node in
                NumberCell(text: node.permissionsDescription, monospaced: true)
            }
            .width(min: 80, ideal: 90)
            .customizationID("permissions")
            .defaultVisibility(.hidden)
        } rows: {
            if browser.isShowingMatches {
                ForEach(browser.matches) { TableRow($0) }
            } else {
                OutlineGroup(browser.roots, children: \.outlineChildren) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
        .onKeyPress(.space) {
            if browser.previewURL != nil {
                browser.previewURL = nil
                return .handled
            }
            guard let node = browser.previewableSelection else { return .ignored }
            Task { await browser.preview(node) }
            return .handled
        }
        .overlay {
            if browser.isShowingMatches, browser.matches.isEmpty {
                ContentUnavailableView.search(text: browser.searchText)
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<ArchiveNode.ID>) -> some View {
        let nodes = ids.compactMap { browser.current?.tree.node($0) }
        if nodes.count == 1, let node = nodes.first, !node.isDirectory {
            Button("Quick Look") { Task { await browser.preview(node) } }
            Button("Open as Archive") { Task { await browser.descend(into: node) } }
            Divider()
        }
        if !nodes.isEmpty {
            Button("Extract…") {
                browser.selection = ids
                chooseDestinationAndExtract()
            }
            Button("Extract Here") {
                browser.selection = ids
                Task { await browser.extract(to: browser.defaultDestination) }
            }
        }
        if nodes.count == 1, let node = nodes.first {
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
    }

    /// Double-click: into a nested archive, or a look at a file. A folder
    /// opens with its disclosure triangle, which the outline already has.
    private func open(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first, let node = browser.current?.tree.node(id),
              !node.isDirectory
        else { return }
        Task {
            if browser.looksLikeArchive(node) {
                await browser.descend(into: node)
            } else {
                await browser.preview(node)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { browser.goUp() }
                .disabled(browser.levels.count < 2 || browser.activity != nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Back to the archive this one is inside")
        }
        ToolbarItemGroup {
            Picker("Show", selection: $browser.filter) {
                ForEach(EntryFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .help("Show only one kind of file")

            Button("Quick Look", systemImage: "eye") {
                if let node = browser.previewableSelection { Task { await browser.preview(node) } }
            }
            .disabled(browser.previewableSelection == nil || browser.activity != nil)
            .help("Preview the selected file")

            Button("Extract…", systemImage: "arrow.down.document") {
                chooseDestinationAndExtract()
            }
            .help(browser.extractionSummary)
        }
    }

    private func chooseDestinationAndExtract() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = browser.defaultDestination
        panel.message = "Extract \(browser.extractionSummary.lowercasedFirst) into:"
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        FolderAccess.shared.grant(folder)
        Task { await browser.extract(to: folder) }
    }
}

// MARK: - Pieces

private struct NameCell: View {
    let node: ArchiveNode
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: node))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPath, node.path != node.name {
                    Text((node.path as NSString).deletingLastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if node.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Encrypted")
            }
            if node.isSymbolicLink {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Symbolic link")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = node.isDirectory ? "Folder \(node.name)" : node.name
        if node.isEncrypted { label += ", encrypted" }
        if showsPath { label += ", in \((node.path as NSString).deletingLastPathComponent)" }
        return label
    }
}

private struct NumberCell: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .monospacedDigit()
            .font(monospaced ? .body.monospaced() : .body)
            .foregroundStyle(.secondary)
    }
}

/// Finder icons by kind, looked up once per extension.
@MainActor
private enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: ArchiveNode) -> NSImage {
        if node.isDirectory { return cached("/folder") { NSWorkspace.shared.icon(for: .folder) } }
        let ext = (node.name as NSString).pathExtension.lowercased()
        return cached(ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }
}

/// `outer.7z › inner.tar`, each one a way back.
private struct PathBar: View {
    let browser: ArchiveBrowser

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.levels.enumerated()), id: \.element.id) { position, level in
                if position > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    browser.goBack(to: level.id)
                } label: {
                    Label(level.title, systemImage: position == 0 ? "archivebox" : "shippingbox")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .disabled(position == browser.levels.count - 1 || browser.activity != nil)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct StatusBar: View {
    let browser: ArchiveBrowser

    var body: some View {
        HStack(spacing: 10) {
            if let activity = browser.activity {
                ProgressView(value: activity.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(activity.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if activity.totalBytes > 0 {
                    Text("\(Display.bytes(activity.completedBytes)) of \(Display.bytes(activity.totalBytes))")
                        .monospacedDigit()
                }
                Button("Stop", systemImage: "xmark.circle.fill") { activity.cancel() }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            } else {
                Text(selectionLine)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let level = browser.current {
                if level.archive.hasEncryptedHeader {
                    Label("Encrypted list", systemImage: "lock")
                }
                if browser.levels.count > 1 {
                    Text(level.isInPlace ? "Read in place" : "Unpacked to a temporary file")
                        .help(level.isInPlace
                              ? "Read straight out of the archive around it"
                              : "The archive around it compresses its contents, so this one was unpacked first")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var selectionLine: String {
        guard let tree = browser.current?.tree else { return "" }
        if browser.selection.isEmpty {
            if browser.isShowingMatches {
                return Display.count(UInt64(browser.matches.count), "match", "matches")
            }
            return "\(Display.count(UInt64(tree.fileCount), "file", "files")), "
                + "\(Display.count(UInt64(tree.folderCount), "folder", "folders"))"
        }
        return "\(browser.selection.count) selected — \(browser.extractionSummary)"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
