//
//  PreviewProvider.swift
//  7-MacPreview
//
//  Space bar on an archive in the Finder: what is inside it, without
//  opening anything.
//
//  This is the extension the roadmap called possible only because of the
//  framework: an app extension cannot sensibly launch a command line tool,
//  but it can link SevenZipKit and read the entry list in-process.
//

import Foundation
import QuickLookUI
import SevenZipKit
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let html = ArchiveListing(url: request.fileURL).html()
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 720, height: 520)) { reply in
            reply.stringEncoding = .utf8
            reply.title = request.fileURL.lastPathComponent
            return Data(html.utf8)
        }
    }
}

/// An archive's contents as a page: a summary line and one row per entry.
struct ArchiveListing {
    let url: URL

    /// Enough to see what an archive is; a forty-thousand-row page helps
    /// nobody and costs the Finder a noticeable pause.
    static let maximumRows = 500

    func html() -> String {
        let name = escape(url.lastPathComponent)
        let archive: SZKArchive
        do {
            archive = try SZKArchive(at: url, passwordProvider: nil)
        } catch let error as NSError {
            let reason = error.domain == SZKErrorDomain && error.code == SZKError.Code.passwordRequired.rawValue
                ? String(localized: "The list of files is encrypted. Open the archive in 7-Mac to enter the password.")
                : error.localizedDescription
            return page(title: name, summary: escape(reason), rows: "")
        }

        let files = archive.entries.filter { !$0.isDirectory }
        let total = files.reduce(UInt64(0)) { $0 + ($1.uncompressedSize?.uint64Value ?? 0) }
        let count = files.count == 1 ? String(localized: "1 file")
                                     : String(localized: "\(files.count) files")
        var summary = "\(escape(archive.formatName)) · \(count) · \(bytes(total))"
        if let packed = archive.physicalSize?.uint64Value, total > 0 {
            summary += " · " + String(localized: "\(bytes(packed)) on disk")
        }
        if archive.entries.contains(where: \.isEncrypted) {
            summary += " · " + String(localized: "encrypted")
        }

        let sorted = archive.entries.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var rows = ""
        for entry in sorted.prefix(Self.maximumRows) {
            let depth = entry.path.split(separator: "/").count - 1
            let leaf = (entry.path as NSString).lastPathComponent
            let icon = entry.isDirectory ? "📁" : (entry.isEncrypted ? "🔒" : "📄")
            let size = entry.isDirectory ? "" : (entry.uncompressedSize.map { bytes($0.uint64Value) } ?? "")
            let date = entry.modificationDate.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? ""
            rows += """
                <tr><td class="name" style="padding-left:\(8 + depth * 16)px">\(icon) \(escape(leaf))</td>\
                <td class="num">\(size)</td><td class="date">\(escape(date))</td></tr>

                """
        }
        if sorted.count > Self.maximumRows {
            let more = String(localized: "and \(sorted.count - Self.maximumRows) more")
            rows += "<tr><td colspan=\"3\" class=\"more\">\(escape(more))</td></tr>"
        }
        return page(title: name, summary: summary, rows: rows)
    }

    private func page(title: String, summary: String, rows: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; --line: #0000001a; --dim: #6e6e73; }
          @media (prefers-color-scheme: dark) { :root { --line: #ffffff1f; --dim: #98989d; } }
          body { font: 13px -apple-system, sans-serif; margin: 0; padding: 16px 20px; }
          h1 { font-size: 17px; margin: 0 0 2px; font-weight: 600; }
          p.summary { color: var(--dim); margin: 0 0 12px; }
          table { width: 100%; border-collapse: collapse; }
          td { padding: 3px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
          td.name { overflow: hidden; text-overflow: ellipsis; max-width: 420px; }
          td.num, td.date { color: var(--dim); font-variant-numeric: tabular-nums; }
          td.num { text-align: right; }
          td.more { color: var(--dim); font-style: italic; border: none; }
        </style></head>
        <body><h1>\(title)</h1><p class="summary">\(summary)</p>
        <table>\(rows)</table></body></html>
        """
    }

    private func bytes(_ count: UInt64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
