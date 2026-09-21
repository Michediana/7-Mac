//
//  DroppedItems.swift
//  7-Mac
//
//  Turning a drag into file URLs.
//

import Foundation
import UniformTypeIdentifiers

/// Resolves a drag into file URLs, keeping the order they were dropped in and
/// quietly ignoring anything that is not a file.
///
/// Item providers rather than SwiftUI's `Transferable` route: a Finder drag
/// arrives as `public.file-url` carrying a sandbox extension per item, and
/// this is the path that hands both over intact.
nonisolated func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
        guard provider.canLoadObject(ofClass: URL.self) else { continue }
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        if let url, url.isFileURL { urls.append(url) }
    }
    return urls
}
