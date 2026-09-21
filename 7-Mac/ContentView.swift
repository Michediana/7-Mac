//
//  ContentView.swift
//  7-Mac
//
//  M0 smoke screen: prove the embedded engine loads and answers.
//  M2 replaces this with the real app.
//

import SwiftUI
import SevenZipKit

/// A row in the format table. `SZKFormat` is an Objective-C class and cannot
/// be made `Identifiable` from here without a retroactive conformance, so the
/// view layer keeps its own value type.
// `nonisolated`: the project defaults to MainActor isolation, and these rows
// are built in a property initialiser, which is not.
private nonisolated struct FormatRow: Identifiable {
    let id: Int
    let name: String
    let extensions: String
    let writable: Bool
    let signatureCount: Int

    init(_ format: SZKFormat) {
        id = Int(format.index)
        name = format.name
        extensions = format.fileExtensions.isEmpty
            ? "—"
            : format.fileExtensions.joined(separator: " ")
        writable = format.isWritable
        signatureCount = format.signatures.count
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty
            || name.localizedCaseInsensitiveContains(query)
            || extensions.localizedCaseInsensitiveContains(query)
    }
}

struct ContentView: View {
    @State private var query = ""
    @State private var writableOnly = false

    private let rows = SZKEngine.formats.map(FormatRow.init)
    private let writableCount = SZKEngine.writableFormats.count

    private var visibleRows: [FormatRow] {
        rows.filter { (!writableOnly || $0.writable) && $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(visibleRows) {
                TableColumn("Format") { Text($0.name).font(.body.monospaced()) }
                TableColumn("Extensions") { row in
                    Text(row.extensions).foregroundStyle(.secondary)
                }
                TableColumn("Mode") { row in
                    Text(row.writable ? "read / write" : "read")
                        .foregroundStyle(row.writable ? .primary : .secondary)
                }
                .width(90)
                TableColumn("Signatures") { row in
                    Text(row.signatureCount == 0 ? "—" : "\(row.signatureCount)")
                        .foregroundStyle(.secondary)
                }
                .width(80)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .searchable(text: $query, prompt: "Filter formats")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("7-Zip \(SZKEngine.upstreamVersion) engine, embedded")
                .font(.headline)
            HStack(spacing: 12) {
                Text("\(rows.count) formats readable")
                Text("·")
                Text("\(writableCount) writable")
                Spacer()
                Toggle("Writable only", isOn: $writableOnly)
                    .toggleStyle(.checkbox)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

#Preview {
    ContentView()
}
