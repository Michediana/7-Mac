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
        handler(reply, nil)
    }
}
