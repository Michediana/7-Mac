//
//  DragOut.swift
//  7-Mac
//
//  Dragging entries out of the browser into the Finder.
//
//  SwiftUI's own drags cannot do this. They carry item providers, and what a
//  drag out of an archive needs is a file promise: the Finder says where the
//  drop landed, and only then does the entry get unpacked — into a folder the
//  sandbox would otherwise never let us write to. `NSFilePromiseProvider` is
//  the AppKit way to make that promise, and it wants an AppKit drag.
//
//  So the table stays SwiftUI's, and the gesture is watched from the side: a
//  mouse-down on a row that turns into a drag starts an AppKit session from
//  the table view underneath. A click that stays a click passes through
//  untouched, as do double-clicks and clicks with modifier keys, which is
//  where selecting belongs.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Marks a row with the node it shows, so a mouse-down on the row can be
/// traced back to an entry. Sits in the name cell; draws nothing and is
/// invisible to clicks.
struct DragTag: NSViewRepresentable {
    let nodeID: ArchiveNode.ID

    func makeNSView(context: Context) -> DragTagView {
        let view = DragTagView()
        view.nodeID = nodeID
        return view
    }

    func updateNSView(_ view: DragTagView, context: Context) {
        // Rows are reused: the tag follows whatever the cell shows now.
        view.nodeID = nodeID
    }
}

final class DragTagView: NSView {
    var nodeID: ArchiveNode.ID = -1
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Installs the drag-out gesture on the window the browser's table is in.
struct ArchiveDragSource: NSViewRepresentable {
    let browser: ArchiveBrowser

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.controller.browser = browser
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.controller.browser = browser
    }
}

final class DragSourceView: NSView {
    let controller = DragOutController()
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.controller.dragIfNeeded(event, in: self.window) else { return event }
            // The drag has begun from this mouse-down; the table must not
            // also start tracking it as a click.
            return nil
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// What one promise stands for: the entry, and the level it was dragged from.
private struct DragPayload {
    let node: ArchiveNode
    let level: ArchiveBrowser.Level.ID
}

final class DragOutController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    weak var browser: ArchiveBrowser?

    /// Where promises are kept: off the main thread, which the unpacking
    /// they wait for needs.
    private nonisolated let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Watches `event` until it is either a click — `false`, deliver it as
    /// usual — or a drag of one or more rows, which this starts: `true`.
    func dragIfNeeded(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, event.window === window, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let browser, let level = browser.current,
              let table = tableView(under: event, in: window)
        else { return false }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, let rowView = table.rowView(atRow: row, makeIfNecessary: false),
              let clickedID = Self.tag(in: rowView),
              let clicked = level.tree.node(clickedID)
        else { return false }

        guard Self.becomesDrag(from: event) else { return false }

        // Dragging a selected row takes the whole selection, as in the
        // Finder; dragging any other row selects it and takes it alone.
        var nodes: [ArchiveNode]
        if browser.selection.contains(clickedID) {
            nodes = browser.selection.compactMap { level.tree.node($0) }
            // A folder brings what is inside it; its contents need no
            // promises of their own.
            let folders = nodes.filter(\.isDirectory).map { $0.path + "/" }
            nodes.removeAll { node in folders.contains { node.path.hasPrefix($0) } }
            nodes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            // The clicked row leads, so the drag image starts under the pointer.
            if let position = nodes.firstIndex(where: { $0 === clicked }) {
                nodes.insert(nodes.remove(at: position), at: 0)
            }
        } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            nodes = [clicked]
        }

        let cell = table.frameOfCell(atColumn: 0, row: row)
        let items = nodes.enumerated().map { position, node in
            let provider = NSFilePromiseProvider(fileType: Self.fileType(of: node), delegate: self)
            provider.userInfo = DragPayload(node: node, level: level.id)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let image = Self.dragImage(for: node)
            let origin = NSPoint(x: cell.minX, y: cell.minY + CGFloat(position) * table.rowHeight)
            item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
            return item
        }
        table.beginDraggingSession(with: items, event: event, source: self)
        return true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A copy, and only out of the app: nothing in 7-Mac takes promises,
        // and the entries stay in the archive whatever the drop.
        context == .outsideApplication ? .copy : []
    }

    // MARK: NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? DragPayload)?.node.name ?? "Untitled"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         writePromiseTo url: URL,
                                         completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        guard let payload = filePromiseProvider.userInfo as? DragPayload else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let node = payload.node
        let level = payload.level
        Task { @MainActor [weak self] in
            // A window closed before the drop, or an unpacking that did not
            // happen: the browser has already said why, if there was a why.
            guard let browser = self?.browser,
                  let source = await browser.fileForDrag(node, from: level)
            else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            let error = await Task.detached(priority: .userInitiated) { () -> (any Error)? in
                do {
                    try DragOutController.deliver(source, to: url)
                    return nil
                } catch {
                    return error
                }
            }.value
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    /// Copies what was unpacked to where the Finder asked for it. A clone on
    /// APFS when the two share a volume, so a large entry costs no space
    /// twice. The unpacked copy stays: a second drag reuses it.
    nonisolated static func deliver(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: Pieces

    /// The table view under the pointer, if the pointer is on one. SwiftUI's
    /// `Table` is an `NSTableView` (an `NSOutlineView` with an outline)
    /// underneath.
    private func tableView(under event: NSEvent, in window: NSWindow) -> NSTableView? {
        guard let content = window.contentView else { return nil }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }

    private static func tag(in view: NSView) -> ArchiveNode.ID? {
        if let tag = view as? DragTagView { return tag.nodeID }
        for subview in view.subviews {
            if let id = tag(in: subview) { return id }
        }
        return nil
    }

    /// Follows the button until it is let go — a click — or the pointer has
    /// moved far enough to mean a drag. Nothing is taken off the queue but
    /// the small moves on the way: the mouse-up of a click stays there for
    /// the table.
    private static func becomesDrag(from event: NSEvent) -> Bool {
        let start = event.locationInWindow
        while true {
            guard let next = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                             until: .distantFuture, inMode: .eventTracking,
                                             dequeue: false)
            else { return false }
            if next.type == .leftMouseUp { return false }
            _ = NSApp.nextEvent(matching: .leftMouseDragged, until: .distantFuture,
                                inMode: .eventTracking, dequeue: true)
            let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if moved >= 4 { return true }
        }
    }

    private static func fileType(of node: ArchiveNode) -> String {
        if node.isDirectory { return UTType.folder.identifier }
        let ext = (node.name as NSString).pathExtension
        return (UTType(filenameExtension: ext) ?? .data).identifier
    }

    /// Icon and name, as the Finder draws a dragged file.
    private static func dragImage(for node: ArchiveNode) -> NSImage {
        let icon = FileIcons.icon(for: node)
        let name = NSAttributedString(string: node.name, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = name.size()
        let size = NSSize(width: min(20 + ceil(textSize.width), 320), height: max(18, ceil(textSize.height)))
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: NSRect(x: 0, y: (rect.height - 16) / 2, width: 16, height: 16))
            name.draw(with: NSRect(x: 20, y: (rect.height - textSize.height) / 2,
                                   width: rect.width - 20, height: textSize.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}
