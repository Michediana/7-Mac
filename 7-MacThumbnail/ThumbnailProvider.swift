//
//  ThumbnailProvider.swift
//  7-MacThumbnail
//
//  The Finder's icon for an archive: a page in its format's colour, with
//  the format's name across it.
//

import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // A page, a little taller than wide, as the Finder draws documents.
        let height = request.maximumSize.height
        let size = CGSize(width: (height * 0.78).rounded(), height: height)
        let icon = ArchiveIcon(fileName: request.fileURL.lastPathComponent)

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            icon.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        // Our drawing is already the whole icon: ask for the plain flavour so
        // the Finder shows it on a transparent ground instead of framing it
        // on a white page. The setter is not public, hence the guard.
        if reply.responds(to: NSSelectorFromString("setIconFlavor:")) {
            reply.setValue(0, forKey: "iconFlavor")
        }
        handler(reply, nil)
    }
}
