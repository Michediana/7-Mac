//
//  Checksums.swift
//  7-Mac
//
//  Checksums of files or of archive entries, a comparison against the one a
//  download page printed, and the integrity report a test produces.
//

import AppKit
import Foundation
import Observation
import SevenZipKit

/// What to checksum.
nonisolated enum ChecksumSource: Sendable {
    case files([URL])
    /// Entries of an archive a browser has open.
    case entries(archive: Archive, indexes: IndexSet?, title: String, password: String?)
}

/// What a checksum window is opened on.
nonisolated struct ChecksumTarget: Codable, Hashable, Sendable {
    var id = UUID()
    var urls: [URL]
}

@MainActor @Observable
final class ChecksumModel {
    let source: ChecksumSource
    let title: String

    /// Which methods to compute. Remembered between windows.
    var methods: [String] {
        didSet { UserDefaults.standard.set(methods, forKey: Self.methodsKey) }
    }
    /// A checksum pasted from elsewhere, to find among the results.
    var expected = ""

    private(set) var report: HashReport?
    private(set) var isRunning = false
    private(set) var completedBytes: UInt64 = 0
    private(set) var totalBytes: UInt64 = 0
    private(set) var problem: String?
    private var task: Task<Void, Never>?

    init(source: ChecksumSource) {
        self.source = source
        switch source {
        case .files(let urls):
            title = urls.count == 1 ? urls[0].lastPathComponent : Display.count(UInt64(urls.count), "item", "items")
        case .entries(_, _, let title, _):
            self.title = title
        }
        let available = Set(SevenZip.hashMethods)
        methods = (UserDefaults.standard.stringArray(forKey: Self.methodsKey) ?? ["CRC32", "SHA256"])
            .filter(available.contains)
        if methods.isEmpty { methods = ["SHA256"] }
    }

    private static let methodsKey = "ChecksumMethods"

    /// Everything the engine offers, in the order people look for them.
    static var availableMethods: [String] {
        let preferred = ["CRC32", "CRC64", "MD5", "SHA1", "SHA256", "SHA384", "SHA512",
                         "SHA3-256", "XXH64", "BLAKE2sp"]
        let engine = SevenZip.hashMethods
        return preferred.filter(engine.contains) + engine.filter { !preferred.contains($0) }.sorted()
    }

    func toggle(_ method: String) {
        if let position = methods.firstIndex(of: method) {
            guard methods.count > 1 else { return }   // one at least
            methods.remove(at: position)
        } else {
            // Keep the display order, whatever order they were ticked in.
            let order = Self.availableMethods
            methods = (methods + [method]).sorted {
                (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max)
            }
        }
    }

    var fractionCompleted: Double? {
        totalBytes == 0 ? nil : min(1, Double(completedBytes) / Double(totalBytes))
    }

    func run() {
        task?.cancel()
        report = nil
        problem = nil
        completedBytes = 0
        totalBytes = 0
        isRunning = true
        let methods = methods
        let source = source
        let throttle = ProgressThrottle()
        let model = self
        let progress: ProgressObserver = { progress in
            guard throttle.allow() else { return }
            Task { @MainActor in
                model.completedBytes = progress.completedBytes
                model.totalBytes = progress.totalBytes
            }
        }
        task = Task {
            defer { isRunning = false }
            do {
                switch source {
                case .files(let urls):
                    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                    report = try await SevenZip.hash(urls, methods: methods, onProgress: progress)
                case .entries(let archive, let indexes, _, let password):
                    let provider: PasswordProvider? = password.map { value in { @Sendable in value } }
                    report = try await archive.hash(indexes, methods: methods,
                                                    password: provider, onProgress: progress)
                }
            } catch is CancellationError {
            } catch where error.sevenZipCode == .cancelled {
            } catch {
                problem = error.archiveDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    // MARK: - Comparing

    /// The pasted checksum without the decoration it tends to come with:
    /// spaces, a `sha256:` prefix, a trailing file name as `shasum` prints.
    nonisolated static func normalized(_ checksum: String) -> String {
        var text = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.split(whereSeparator: \.isWhitespace).first { text = String(first) }
        if let colon = text.lastIndex(of: ":") { text = String(text[text.index(after: colon)...]) }
        return text.lowercased()
    }

    /// Where the expected checksum turns up: item and method. `nil` while
    /// nothing is pasted; an empty list when it matches nothing.
    var matches: [(item: HashReport.Item.ID, method: String)]? {
        let wanted = Self.normalized(expected)
        guard !wanted.isEmpty, let report else { return nil }
        var found: [(HashReport.Item.ID, String)] = []
        for item in report.items {
            for (position, digest) in item.digests.enumerated() where digest.lowercased() == wanted {
                found.append((item.id, report.methods[position]))
            }
        }
        return found
    }

    func isMatch(_ item: HashReport.Item, method: String) -> Bool {
        matches?.contains { $0.item == item.id && $0.method == method } ?? false
    }

    // MARK: - Exporting

    /// The report as `shasum` and friends write it: one section per method,
    /// `digest  path` per file. Reads back with `shasum -c` for SHA methods.
    nonisolated static func text(of report: HashReport) -> String {
        var lines: [String] = []
        for (position, method) in report.methods.enumerated() {
            if report.methods.count > 1 { lines.append("# \(method)") }
            for item in report.items where !item.isDirectory && position < item.digests.count {
                lines.append("\(item.digests[position])  \(item.path)")
            }
            if report.methods.count > 1 { lines.append("") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text(of: report), forType: .string)
    }

    func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        let suffix = methods.count == 1 ? methods[0].lowercased().replacingOccurrences(of: "-", with: "") : "txt"
        panel.nameFieldStringValue = "\(title).\(suffix)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.text(of: report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Integrity

/// What testing an archive found, entry by entry.
nonisolated struct TestReport: Sendable, Identifiable {
    struct Row: Sendable, Identifiable {
        let id: Int
        let path: String
        let size: UInt64
        /// CRC32 as decoded; empty for a folder or an entry that failed.
        let checksum: String
        /// `nil` when the entry decoded and matched.
        let problem: String?
    }

    let id = UUID()
    let archiveName: String
    let date: Date
    let rows: [Row]
    /// Problems not tied to one entry — the archive's end missing, say.
    let generalProblems: [String]

    var failedCount: Int { rows.count(where: { $0.problem != nil }) + generalProblems.count }
    var fileCount: Int { rows.count }
    var byteCount: UInt64 { rows.reduce(0) { $0 + $1.size } }
    var isHealthy: Bool { failedCount == 0 }

    /// Built from a CRC32 pass over the archive.
    init(archiveName: String, report: HashReport, date: Date = .now) {
        self.archiveName = archiveName
        self.date = date
        var problems: [String: String] = [:]
        var general: [String] = []
        for failure in report.failures {
            let reason = failure.archiveDescription
            if let path = failure.userInfo[NSFilePathErrorKey] as? String {
                problems[path] = reason
            } else {
                general.append(reason)
            }
        }
        var rows: [Row] = []
        var seen = Set<String>()
        for item in report.items where !item.isDirectory {
            seen.insert(item.path)
            let problem = problems[item.path]
            rows.append(Row(id: rows.count, path: item.path, size: item.size,
                            checksum: problem == nil ? (item.digests.first ?? "") : "",
                            problem: problem))
        }
        // An entry that failed before it produced any data never reaches
        // the hash; it still belongs in the report.
        for (path, reason) in problems where !seen.contains(path) {
            rows.append(Row(id: rows.count, path: path, size: 0, checksum: "", problem: reason))
        }
        self.rows = rows
        generalProblems = general
    }

    var summary: String {
        if isHealthy {
            return String(localized: "All \(Display.count(UInt64(fileCount), "file", "files")) are intact (\(Display.bytes(byteCount))).")
        }
        return String(localized: "\(Display.count(UInt64(failedCount), "problem", "problems")) in \(Display.count(UInt64(fileCount), "file", "files")).")
    }

    /// Plain text, for saving next to the archive or pasting into a ticket.
    var text: String {
        var lines = [String(localized: "7-Mac integrity report"),
                     String(localized: "Archive: \(archiveName)"),
                     String(localized: "Tested: \(date.formatted(date: .long, time: .standard))"),
                     String(localized: "Result: \(summary)"), ""]
        lines += generalProblems.map { "ERROR  \($0)" }
        for row in rows {
            if let problem = row.problem {
                lines.append("ERROR  \(row.path) — \(problem)")
            } else {
                lines.append("OK     \(row.checksum)  \(row.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "\(archiveName) test report.txt")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
