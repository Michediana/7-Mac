//
//  FinderMenu.swift
//  7-MacFinder
//
//  The 7-Mac submenu in the Finder's contextual menu.
//
//  This extension does no work of its own: it decides which items make sense
//  for the selection, and hands the choice to the app. The engine stays in the
//  app, where the queue, the password sheet and the folder grants already are.
//

import AppKit
import FinderSync
import OSLog

final class FinderMenu: FIFinderSync {
    /// The bundle that carries this extension: `7-Mac.app/Contents/PlugIns/…`.
    private let appURL = Bundle.main.bundleURL
        .deletingLastPathComponent()   // PlugIns
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent()   // 7-Mac.app

    override init() {
        super.init()
        // The whole file system, so the menu is there wherever the Finder is.
        // "/" alone stops at the boot volume; other disks are added as they
        // come and go.
        updateDirectories()
        FinderMenuHeartbeat.beat(always: true)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateDirectories()
            }
        }
    }

    private func updateDirectories() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                             options: [.skipHiddenVolumes]) ?? []
        FIFinderSyncController.default().directoryURLs = Set(volumes + [URL(filePath: "/")])
    }

    // MARK: - Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty
        else { return nil }
        FinderMenuHeartbeat.beat()

        let submenu = NSMenu(title: "7-Mac")
        if items.allSatisfy(Self.looksLikeArchive) {
            submenu.addItem(item(String(localized: "Extract"), "arrow.up.bin", #selector(extract)))
            submenu.addItem(item(String(localized: "Open Without Extracting"), "eye", #selector(browse)))
            submenu.addItem(item(String(localized: "Test Archive"), "checkmark.seal", #selector(test)))
            submenu.addItem(.separator())
        }
        submenu.addItem(item(String(localized: "Compress…"), "archivebox", #selector(compress)))
        submenu.addItem(item(String(localized: "Checksums…"), "number", #selector(checksums)))

        let root = NSMenuItem(title: "7-Mac", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        root.submenu = submenu
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return menu
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func extract(_ sender: NSMenuItem) { send(.extract) }
    @objc private func browse(_ sender: NSMenuItem) { send(.browse) }
    @objc private func test(_ sender: NSMenuItem) { send(.test) }
    @objc private func compress(_ sender: NSMenuItem) { send(.compress) }
    @objc private func checksums(_ sender: NSMenuItem) { send(.checksums) }

    // MARK: - Handing over

    private let log = Logger(subsystem: "eu.dgnet.7-Mac", category: "finder")

    private func send(_ action: FinderAction) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty
        else { return }
        let request: URL
        do {
            request = try FinderHandoff.post(action, for: items)
        } catch {
            log.error("could not leave the request for the app: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Not the files themselves: this process cannot read them, and Launch
        // Services will not pass on what the sender has no access to.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([request], withApplicationAt: appURL,
                                configuration: configuration) { [log] _, error in
            if let error {
                log.error("could not open 7-Mac: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The same rule the app applies to a drop, by extension only: the menu is
    /// built while the Finder waits, so nothing here may touch the file.
    static func looksLikeArchive(_ url: URL) -> Bool {
        !url.hasDirectoryPath && ArchiveExtensions.matches(url.lastPathComponent)
    }
}
