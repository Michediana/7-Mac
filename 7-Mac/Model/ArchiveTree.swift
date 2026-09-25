//
//  ArchiveTree.swift
//  7-Mac
//
//  An archive's flat entry list, as the folder tree a person expects to see.
//
//  Archives do not store a tree. They store paths — `a/b/c.txt` — and very
//  often not the folders along the way: a zip made by a script may hold
//  `a/b/c.txt` without ever mentioning `a` or `a/b`. So the folders here are
//  partly the archive's and partly ours, and the difference matters when
//  extracting: a synthesised folder has no entry index to hand the engine,
//  only the entries under it.
//

import Foundation
import SevenZipKit
import UniformTypeIdentifiers

/// The part of an `SZKArchiveEntry` the tree needs, as a value.
///
/// A plain struct so the tree can be built off the main actor, and so tests
/// can describe an archive without having to write one.
nonisolated struct EntryRecord: Sendable {
    var index: Int
    var path: String
    var isDirectory = false
    var isSymbolicLink = false
    var isEncrypted = false
    var size: UInt64?
    var packedSize: UInt64?
    var checksum: UInt32?
    var modified: Date?
    var posixPermissions: UInt16?
    var method = ""

    init(index: Int, path: String, isDirectory: Bool = false, isSymbolicLink: Bool = false,
         isEncrypted: Bool = false, size: UInt64? = nil, packedSize: UInt64? = nil,
         checksum: UInt32? = nil, modified: Date? = nil, posixPermissions: UInt16? = nil,
         method: String = "") {
        self.index = index
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isEncrypted = isEncrypted
        self.size = size
        self.packedSize = packedSize
        self.checksum = checksum
        self.modified = modified
        self.posixPermissions = posixPermissions
        self.method = method
    }

    init(_ entry: SZKArchiveEntry) {
        index = Int(entry.index)
        path = entry.path
        isDirectory = entry.isDirectory
        isSymbolicLink = entry.isSymbolicLink
        isEncrypted = entry.isEncrypted
        size = entry.uncompressedSize?.uint64Value
        packedSize = entry.compressedSize?.uint64Value
        checksum = entry.checksum?.uint32Value
        modified = entry.modificationDate
        posixPermissions = entry.posixPermissions?.uint16Value
        method = entry.method
    }
}

/// One row of the browser: an entry, or a folder the archive implies.
///
/// A class, because a table row needs a stable identity and a folder needs
/// to point at its children without copying them. Everything but `children`
/// is fixed at build time; `children` is only reordered, and only on the main
/// actor, by `ArchiveTree.sort`.
nonisolated final class ArchiveNode: Identifiable, @unchecked Sendable {
    /// Unique within one tree, and nothing more.
    let id: Int
    let name: String
    /// '/'-joined path from the archive root, normalised: no `./`, no empty
    /// components. What the browser shows in search results.
    let path: String
    let isDirectory: Bool
    /// The archive's own entry. `nil` for a folder only implied by the paths
    /// under it.
    let record: EntryRecord?
    fileprivate(set) var children: [ArchiveNode] = []

    /// A folder's figures cover everything beneath it.
    fileprivate(set) var size: UInt64?
    fileprivate(set) var packedSize: UInt64?
    /// Files beneath a folder, recursively; 1 for a file.
    fileprivate(set) var fileCount = 0

    fileprivate init(id: Int, name: String, path: String, isDirectory: Bool, record: EntryRecord?) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.record = record
    }

    var isEncrypted: Bool { record?.isEncrypted ?? false }
    var isSymbolicLink: Bool { record?.isSymbolicLink ?? false }
    var modified: Date? { record?.modified }
    var method: String { record?.method ?? "" }
    var checksum: UInt32? { record?.checksum }
    var posixPermissions: UInt16? { record?.posixPermissions }

    /// `packed / size`; `nil` when either is unknown or the node is empty.
    var ratio: Double? {
        guard let size, let packedSize, size > 0 else { return nil }
        return Double(packedSize) / Double(size)
    }

    /// What `Table`'s outline asks for: `nil` makes a leaf, `[]` an empty
    /// folder with a disclosure triangle.
    var outlineChildren: [ArchiveNode]? { isDirectory ? children : nil }

    /// The node and everything below it, depth first.
    var subtree: [ArchiveNode] {
        var result: [ArchiveNode] = [self]
        var index = 0
        while index < result.count {
            result.append(contentsOf: result[index].children)
            index += 1
        }
        return result
    }

    // MARK: Sort keys
    //
    // Table sorts through key paths to Comparable values, and Optional is
    // not one. Unknown sorts before every known value.

    var sortSize: UInt64 { size ?? 0 }
    var sortPackedSize: UInt64 { packedSize ?? 0 }
    var sortRatio: Double { ratio ?? -1 }
    var sortModified: Date { modified ?? .distantPast }
    var sortChecksum: UInt32 { checksum ?? 0 }
    var sortPermissions: UInt16 { posixPermissions ?? 0 }
}

/// Narrows the browser to one kind of file.
nonisolated enum EntryFilter: String, CaseIterable, Identifiable, Sendable {
    case everything
    case images
    case movies
    case audio
    case documents
    case sourceCode
    case archives
    case encrypted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: String(localized: "Everything")
        case .images:     String(localized: "Images")
        case .movies:     String(localized: "Movies")
        case .audio:      String(localized: "Audio")
        case .documents:  String(localized: "Documents")
        case .sourceCode: String(localized: "Source Code")
        case .archives:   String(localized: "Archives")
        case .encrypted:  String(localized: "Encrypted")
        }
    }

    var systemImage: String {
        switch self {
        case .everything: "square.grid.2x2"
        case .images:     "photo"
        case .movies:     "film"
        case .audio:      "waveform"
        case .documents:  "doc.text"
        case .sourceCode: "chevron.left.forwardslash.chevron.right"
        case .archives:   "archivebox"
        case .encrypted:  "lock"
        }
    }

    /// Whether a file node belongs. Folders never do: a filtered view is a
    /// flat list of matching files, since a folder "being an image" means
    /// nothing. Nor does a symlink to a kind: what it holds is a path.
    func admits(_ node: ArchiveNode) -> Bool {
        guard !node.isDirectory else { return false }
        if self == .everything { return true }
        if self == .encrypted { return node.isEncrypted }
        guard !node.isSymbolicLink else { return false }

        let ext = (node.name as NSString).pathExtension
        if self == .archives {
            return ArchiveNaming.droppedArchiveExtensions.contains(ext.lowercased())
        }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        switch self {
        case .images:     return type.conforms(to: .image)
        case .movies:     return type.conforms(to: .movie)
        case .audio:      return type.conforms(to: .audio)
        case .sourceCode: return type.conforms(to: .sourceCode) || type.conforms(to: .script)
        case .documents:
            return type.conforms(to: .text) && !type.conforms(to: .sourceCode)
                || type.conforms(to: .pdf)
                || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet)
                || type.conforms(to: .rtf)
        case .everything, .encrypted, .archives:
            return true
        }
    }
}

nonisolated struct ArchiveTree: Sendable {
    /// The top level, in the current sort order.
    private(set) var roots: [ArchiveNode]
    /// Every node, depth first in build order. Search walks this.
    let allNodes: [ArchiveNode]

    let fileCount: Int
    let folderCount: Int
    let totalSize: UInt64
    let totalPackedSize: UInt64?

    private let nodesByID: [Int: ArchiveNode]
    private let foldersByPath: [String: ArchiveNode]

    init(entries: [SZKArchiveEntry]) {
        self.init(records: entries.map(EntryRecord.init))
    }

    init(records: [EntryRecord]) {
        var nextID = 0
        func makeID() -> Int { defer { nextID += 1 }; return nextID }

        // Folders by normalised path; "" is the root, which is never shown.
        let root = ArchiveNode(id: makeID(), name: "", path: "", isDirectory: true, record: nil)
        var folders: [String: ArchiveNode] = ["": root]
        // Folders we invented on the way to a path, which a later explicit
        // entry for the same folder should replace.
        var implied: Set<String> = []

        func folder(at components: ArraySlice<String>) -> ArchiveNode {
            let path = components.joined(separator: "/")
            if let existing = folders[path] { return existing }
            let parent = folder(at: components.dropLast())
            let node = ArchiveNode(id: makeID(), name: components.last ?? "", path: path,
                                   isDirectory: true, record: nil)
            parent.children.append(node)
            folders[path] = node
            implied.insert(path)
            return node
        }

        for record in records {
            var components = Self.components(of: record.path)
            if components.isEmpty {
                // A gzip with no stored name, say. It still has contents.
                guard !record.isDirectory else { continue }
                components = [String(localized: "(unnamed)")]
            }
            let path = components.joined(separator: "/")
            let parent = folder(at: components.dropLast())

            if record.isDirectory {
                if folders[path] != nil, !implied.contains(path) {
                    // The same folder listed twice. The first one stands.
                    continue
                }
                let node = ArchiveNode(id: makeID(), name: components.last!, path: path,
                                       isDirectory: true, record: record)
                if let placeholder = folders[path] {
                    // We invented this folder for an earlier child; the
                    // archive has now named it. Keep the children, take the
                    // entry.
                    node.children = placeholder.children
                    parent.children.removeAll { $0 === placeholder }
                    implied.remove(path)
                }
                parent.children.append(node)
                folders[path] = node
            } else {
                // Files are never merged. A tar can hold the same path twice,
                // and both are real: extracting one or the other differs.
                let node = ArchiveNode(id: makeID(), name: components.last!, path: path,
                                       isDirectory: false, record: record)
                node.size = record.size
                node.packedSize = record.packedSize
                node.fileCount = 1
                parent.children.append(node)
            }
        }

        // Folder totals, bottom up. A folder's packed size is only known if
        // every file under it reports one: a partial sum would be a lie.
        func total(_ node: ArchiveNode) {
            guard node.isDirectory else { return }
            var size: UInt64 = 0
            var packed: UInt64? = 0
            var files = 0
            for child in node.children {
                total(child)
                size += child.size ?? 0
                // An empty folder totals 0, not nil, so it does not spoil this.
                packed = packed.flatMap { sum in child.packedSize.map { sum + $0 } }
                files += child.fileCount
            }
            node.size = size
            node.packedSize = packed
            node.fileCount = files
        }
        total(root)

        let everything = Array(root.subtree.dropFirst())
        allNodes = everything
        roots = root.children
        nodesByID = Dictionary(uniqueKeysWithValues: everything.map { ($0.id, $0) })
        folders[""] = nil
        foldersByPath = folders
        fileCount = root.fileCount
        folderCount = everything.count(where: \.isDirectory)
        totalSize = root.size ?? 0
        totalPackedSize = root.packedSize
    }

    /// `./a//b/` → `["a", "b"]`. Backslashes are left alone: on a Mac they
    /// are a legal character in a name, and 7-Zip has already turned Windows
    /// separators into slashes where the format says they are separators.
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }

    func node(_ id: ArchiveNode.ID) -> ArchiveNode? { nodesByID[id] }

    /// The folder at a normalised path, as `ArchiveNode.path` spells it.
    func folder(at path: String) -> ArchiveNode? { foldersByPath[path] }

    // MARK: - Sorting

    /// Reorders every level in place. Folders stay above files whatever the
    /// column, the way the Finder's list view keeps them when asked to.
    mutating func sort(using comparators: [KeyPathComparator<ArchiveNode>]) {
        func ordered(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
            let sorted = comparators.isEmpty
                ? nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                : nodes.sorted(using: comparators)
            return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
        }
        for node in allNodes where node.isDirectory {
            node.children = ordered(node.children)
        }
        roots = ordered(roots)
    }

    // MARK: - Searching

    /// Files and folders whose name contains `query`, ignoring case and
    /// accents, that also pass `filter`. A flat list in `comparators` order:
    /// a match deep in the tree is no use if you have to go and find it.
    func matches(_ query: String, filter: EntryFilter,
                 comparators: [KeyPathComparator<ArchiveNode>]) -> [ArchiveNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let found = allNodes.filter { node in
            if filter != .everything, !filter.admits(node) { return false }
            guard !query.isEmpty else { return true }
            return node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return comparators.isEmpty
            ? found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            : found.sorted(using: comparators)
    }

    // MARK: - Selection

    /// The entry indexes a selection stands for: each node's own entry, and
    /// every entry beneath a selected folder. The engine extracts by index
    /// and nothing else, so selecting a folder has to mean its contents.
    func entryIndexes(for selection: some Sequence<ArchiveNode.ID>) -> IndexSet {
        var indexes = IndexSet()
        for id in selection {
            guard let node = nodesByID[id] else { continue }
            for member in node.subtree {
                if let index = member.record?.index { indexes.insert(index) }
            }
        }
        return indexes
    }

    /// Files and folders a selection covers, counting a folder's contents
    /// once even when the folder and something inside it are both selected.
    func summary(of selection: Set<ArchiveNode.ID>) -> (files: Int, bytes: UInt64) {
        var seen = Set<Int>()
        var files = 0
        var bytes: UInt64 = 0
        for id in selection {
            guard let node = nodesByID[id] else { continue }
            for member in node.subtree where !member.isDirectory && seen.insert(member.id).inserted {
                files += 1
                bytes += member.size ?? 0
            }
        }
        return (files, bytes)
    }
}

// MARK: - Display

nonisolated extension ArchiveNode {
    /// `rwxr-xr-x`, prefixed `d` or `l` like `ls -l`.
    var permissionsDescription: String {
        guard let mode = posixPermissions else { return "" }
        let kind = isDirectory ? "d" : (isSymbolicLink ? "l" : "-")
        let symbols: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return kind + String(symbols.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    /// CRC32 as 7-Zip prints it: eight uppercase hex digits.
    var checksumDescription: String {
        guard let checksum else { return "" }
        return String(format: "%08X", checksum)
    }

    var ratioDescription: String {
        guard let ratio else { return "" }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}
