//
//  ChecksumView.swift
//  7-Mac
//
//  Checksums, one column per method, and a field to paste the one a
//  download page printed.
//

import AppKit
import SwiftUI

/// A window of its own, for files on disk.
struct ChecksumWindow: View {
    @State private var model: ChecksumModel

    init(target: ChecksumTarget) {
        _model = State(initialValue: ChecksumModel(source: .files(target.urls)))
    }

    var body: some View {
        ChecksumView(model: model)
            .frame(minWidth: 640, minHeight: 320)
            .navigationTitle(Text("Checksums — \(model.title)"))
    }
}

struct ChecksumView: View {
    @Bindable var model: ChecksumModel
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .task { if model.report == nil { model.run() } }
        .onChange(of: model.methods) { model.run() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ChecksumModel.availableMethods, id: \.self) { method in
                    Toggle(method, isOn: Binding(get: { model.methods.contains(method) },
                                                 set: { _ in model.toggle(method) }))
                }
            } label: {
                Label(model.methods.joined(separator: ", "), systemImage: "number")
            }
            .fixedSize()
            .help("Choose which checksums to compute")

            TextField("Paste a checksum to compare", text: $model.expected)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            comparison
        }
        .padding(10)
    }

    @ViewBuilder
    private var comparison: some View {
        if let matches = model.matches, let report = model.report {
            if let first = matches.first {
                let name = report.items.first { $0.id == first.item }?.path ?? ""
                Label("Matches \((name as NSString).lastPathComponent) (\(first.method))",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Label("No match", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let report = model.report {
            let files = report.items.filter { !$0.isDirectory }
            Table(files) {
                TableColumn("Name") { item in
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(item.path)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Size") { item in
                    Text(Display.bytes(item.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                .alignment(.trailing)
                TableColumnForEach(Array(report.methods.enumerated()), id: \.offset) { position, method in
                    TableColumn(method) { item in
                        DigestCell(digest: position < item.digests.count ? item.digests[position] : "",
                                   isMatch: model.isMatch(item, method: method))
                    }
                    .width(min: 80, ideal: method.hasPrefix("CRC") || method == "XXH64" ? 150 : 320)
                }
            }
            .contextMenu(forSelectionType: HashReport.Item.ID.self) { _ in
                Button("Copy All") { model.copyReport() }
            }
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No files", systemImage: "doc",
                                           description: Text("There was nothing to checksum."))
                }
            }
        } else if let problem = model.problem {
            ContentUnavailableView {
                Label("Could not compute checksums", systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem)
            } actions: {
                Button("Try Again") { model.run() }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView(value: model.fractionCompleted)
                    .frame(width: 240)
                    .accessibilityLabel(Text("Checksums — \(model.title)"))
                Group {
                    if model.totalBytes > 0 {
                        Text("\(Display.bytes(model.completedBytes)) of \(Display.bytes(model.totalBytes))")
                    } else {
                        Text("Reading…")
                    }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Stop") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let report = model.report {
                Text("\(Display.count(report.files, "file", "files")), \(Display.bytes(report.bytes))")
                if !report.failures.isEmpty {
                    Label("\(report.failures.count) could not be read", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(report.failures.map(\.archiveDescription).joined(separator: "\n"))
                }
                if report.files > 1, let sum = report.dataSums.first {
                    Text("Sum of data (\(report.methods.first ?? "")): \(sum)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("7-Zip's combined checksum of every file's contents")
                }
            }
            Spacer(minLength: 0)
            Button("Copy") { model.copyReport() }
                .disabled(model.report == nil)
            Button("Save…") { model.saveReport() }
                .disabled(model.report == nil)
            if let onClose {
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .padding(10)
    }
}

private struct DigestCell: View {
    let digest: String
    let isMatch: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(digest)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isMatch ? Color.green : Color.primary)
                .textSelection(.enabled)
            if isMatch {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Matches")
            }
        }
        .help(digest)
        .contextMenu {
            Button("Copy Checksum") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digest, forType: .string)
            }
        }
    }
}

/// An archive's health, entry by entry.
struct TestReportView: View {
    let report: TestReport
    let onClose: () -> Void
    @State private var showsOnlyProblems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.isHealthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(report.isHealthy ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.archiveName)
                        .font(.headline)
                    Text(report.summary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !report.isHealthy {
                    Toggle("Only problems", isOn: $showsOnlyProblems)
                        .toggleStyle(.checkbox)
                }
            }

            ForEach(report.generalProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Table(showsOnlyProblems ? report.rows.filter { $0.problem != nil } : report.rows) {
                TableColumn("") { row in
                    Image(systemName: row.problem == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(row.problem == nil ? Color.green : Color.red)
                        .accessibilityLabel(row.problem == nil ? Text("Intact") : Text("Damaged"))
                }
                .width(20)
                TableColumn("Name") { row in
                    Text(row.path).lineLimit(1).truncationMode(.head).help(row.path)
                }
                TableColumn("Size") { row in
                    Text(Display.bytes(row.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                .alignment(.trailing)
                TableColumn("CRC32 / Problem") { row in
                    if let problem = row.problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(row.checksum).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 160)
            }
            .frame(minHeight: 220)

            HStack {
                Text("Tested \(report.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save Report…") { report.save() }
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }
}
