//
//  ContentView.swift
//  7-Mac
//
//  The one window: two targets to drop things on — one that acts at once,
//  one that gathers items into an archive — and the queue underneath them.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DropArea(isTargeted: isTargeted)
                StagingArea()
            }
            .frame(height: 190)
            Divider()
            QueueList()
        }
        .frame(minWidth: 520, minHeight: 420)
        // `onDrop` with item providers rather than `dropDestination(for:)`:
        // a Finder drag arrives as `public.file-url` plus a sandbox extension
        // for each item, and this is the path that hands both over intact.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { model.accept(await fileURLs(from: providers)) }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open…", systemImage: "folder") {
                    model.chooseArchivesToBrowse()
                }
                .help("Look inside an archive")
                Button("Extract…", systemImage: "arrow.down.document") {
                    model.chooseArchivesToExtract()
                }
                Button("Compress…", systemImage: "archivebox") {
                    model.chooseItemsToCompress()
                }
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Test Archive…") { model.chooseArchivesToTest() }
                    Button("Checksums…") { model.chooseItemsForChecksums() }
                }
            }
            ToolbarItem {
                Button("Clear Finished", systemImage: "xmark.circle") {
                    model.queue.clearFinished()
                }
                .disabled(!model.queue.hasFinishedJobs)
            }
        }
        .sheet(item: $model.passwordPrompt) { PasswordSheet(prompt: $0) }
        .sheet(item: $model.compressionDraft) { CompressSheet(draft: $0) }
        .sheet(item: $model.shownTestReport) { report in
            TestReportView(report: report) { model.shownTestReport = nil }
        }
    }
}

private struct DropArea: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isTargeted ? "archivebox.fill" : "archivebox")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("Drop archives to extract")
                .font(.headline)
            Text("Anything else gets compressed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DropOutline(isTargeted: isTargeted) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop archives here to extract them, or other files to compress them")
    }
}

/// Gathers files and folders, from as many drops as it takes, into one
/// archive — made when the person says so, not on the first drop.
private struct StagingArea: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    var body: some View {
        Group {
            if model.stagedItems.isEmpty {
                empty
            } else {
                gathered
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DropOutline(isTargeted: isTargeted) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        // Nested inside the window's own drop target, so a drop here is
        // gathered rather than extracted or sent straight to the sheet.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { model.stage(await fileURLs(from: providers)) }
            return true
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: isTargeted ? "plus.rectangle.on.folder.fill" : "plus.rectangle.on.folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("Drop files and folders to archive")
                .font(.headline)
            Text("Add as many as you like, then create the archive.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop files and folders here to gather them into a new archive")
    }

    private var gathered: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.stagedItems, id: \.self) { url in
                        StagedItemRow(url: url) { model.unstage(url) }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 8) {
                Text("^[\(model.stagedItems.count) item](inflect: true)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear") { model.clearStaged() }
                Button("Create Archive…") { model.compressStaged() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(12)
    }
}

private struct StagedItemRow: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 16, height: 16)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from the archive")
        }
        .padding(.horizontal, 4)
        .help(url.path(percentEncoded: false))
    }
}

private struct DropOutline: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .padding(12)
    }
}

private struct QueueList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.queue.jobs.isEmpty {
            ContentUnavailableView {
                Label("Nothing queued", systemImage: "tray")
            } description: {
                Text("Finished jobs stay here until you clear them.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(model.queue.jobs) { job in
                    JobRow(job: job)
                        .listRowSeparator(.visible)
                        .contextMenu {
                            if let report = job.testReport {
                                Button("Show Report") { model.shownTestReport = report }
                            }
                            if let archive = job.browsableArchive {
                                Button("Show Contents") { model.browse([archive]) }
                                if !job.isTest {
                                    Button("Test") { model.test([archive]) }
                                }
                            }
                            if let url = job.resultURL {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
    }
}
