//
//  DefaultApp.swift
//  7-Mac
//
//  Whether double-clicking an archive in the Finder opens 7-Mac, and making
//  it so. Asked once on the first launch, and again from Settings › Opening.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum DefaultArchiveApp {
    /// Every type Info.plist declares under `CFBundleDocumentTypes`, except
    /// disc images: an `.iso` double-clicked in the Finder should still mount.
    static var contentTypes: [UTType] {
        let documentTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
            as? [[String: Any]] ?? []
        return documentTypes
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .compactMap(UTType.init)
            .filter { !$0.conforms(to: .diskImage) }
    }

    /// True only when 7-Mac opens every one of them.
    static var isDefault: Bool {
        contentTypes.allSatisfy(opensWithUs)
    }

    /// Hands every type to 7-Mac. Returns the types the system refused;
    /// empty means it all went through.
    @discardableResult
    static func makeDefault() async -> [UTType] {
        let app = Bundle.main.bundleURL
        var refused: [UTType] = []
        for type in contentTypes where !opensWithUs(type) {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            } catch {
                refused.append(type)
            }
        }
        return refused
    }

    private static func opensWithUs(_ type: UTType) -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
