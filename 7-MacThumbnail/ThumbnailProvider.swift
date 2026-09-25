//
//  ThumbnailProvider.swift
//  7-MacThumbnail
//
//  The Finder's icon for an archive, drawn as a page listing what is in it —
//  the way a text file's thumbnail shows its first lines.
//

import AppKit
import QuickLookThumbnailing
import SevenZipKit

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // A page, a little taller than wide, as the Finder draws documents.
        let height = request.maximumSize.height
        let size = CGSize(width: (height * 0.78).rounded(), height: height)
        let listing = ThumbnailListing(url: request.fileURL)

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            listing.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}

/// What the page shows: a few names and the format.
struct ThumbnailListing {
    let names: [String]
    let format: String
    let isLocked: Bool

    init(url: URL) {
        if let archive = try? SZKArchive(at: url, passwordProvider: nil) {
            // The top two levels, indented: one folder at the top says little
            // on its own, what is in it says what the archive is.
            let lines = archive.entries.compactMap { entry -> (String, String)? in
                let components = entry.path.split(separator: "/").filter { $0 != "." }
                guard let last = components.last, components.count <= 2 else { return nil }
                let indent = String(repeating: "  ", count: components.count - 1)
                return (entry.path, indent + last + (entry.isDirectory ? "/" : ""))
            }
            names = lines.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                .prefix(14).map(\.1)
            format = archive.formatName.uppercased()
            isLocked = archive.entries.contains(where: \.isEncrypted)
        } else {
            names = []
            format = url.pathExtension.uppercased()
            isLocked = true
        }
    }

    func draw(in bounds: CGRect) {
        let page = bounds.insetBy(dx: bounds.width * 0.04, dy: bounds.height * 0.02)
        let corner = page.width * 0.04
        NSColor.white.setFill()
        let path = NSBezierPath(roundedRect: page, xRadius: corner, yRadius: corner)
        path.fill()
        NSColor(white: 0, alpha: 0.18).setStroke()
        path.lineWidth = max(1, page.width / 256)
        path.stroke()

        let margin = page.width * 0.09
        let fontSize = max(4, page.height / 22)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(white: 0.25, alpha: 1),
        ]
        var y = page.maxY - margin - fontSize
        let lines = names.isEmpty ? (isLocked ? ["🔒"] : []) : names
        for name in lines {
            guard y > page.minY + margin + fontSize * 2.5 else { break }
            let text = NSAttributedString(string: name, attributes: attributes)
            text.draw(with: CGRect(x: page.minX + margin, y: y,
                                   width: page.width - margin * 2, height: fontSize * 1.3),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y -= fontSize * 1.35
        }

        // The format as a band along the bottom, like the Finder's labels on
        // document icons.
        let badgeHeight = fontSize * 2
        let badge = CGRect(x: page.minX, y: page.minY + page.height * 0.06,
                           width: page.width, height: badgeHeight)
        NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 1).setFill()
        badge.fill()
        let label = NSAttributedString(string: isLocked ? "\(format) 🔒" : format, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize * 1.2, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let labelSize = label.size()
        label.draw(at: CGPoint(x: badge.midX - labelSize.width / 2,
                               y: badge.midY - labelSize.height / 2))
    }
}
