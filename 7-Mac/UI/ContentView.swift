//
//  ContentView.swift
//  7-Mac
//
//  The one window: a target to drop things on, and the queue underneath it.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            DropArea(isTargeted: isTargeted)
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
                Button("Extract…", systemImage: "arrow.down.document") {
                    model.chooseArchivesToExtract()
                }
                Button("Compress…", systemImage: "archivebox") {
                    model.chooseItemsToCompress()
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
    }
}

private struct DropArea: View {
    @Environment(AppModel.self) private var model
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(12)
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop archives here to extract them, or other files to compress them")
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
                }
            }
            .listStyle(.inset)
        }
    }
}
