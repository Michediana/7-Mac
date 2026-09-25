//
//  Preferences.swift
//  7-Mac
//
//  The handful of preferences M2 needs, backed by UserDefaults.
//

import Foundation
import Observation
import SevenZipKit

nonisolated enum CompressionPreset: String, CaseIterable, Identifiable, Sendable {
    case fast, normal, maximum

    var id: String { rawValue }

    /// 7-Zip's own `-mx` scale. `maximum` is 9, the level 7-Zip itself calls
    /// Ultra: when an app offers three choices, the top one should be the top
    /// one.
    var level: SZKCompressionLevel {
        switch self {
        case .fast:    .fast      // -mx3
        case .normal:  .normal    // -mx5
        case .maximum: .ultra     // -mx9
        }
    }

    var title: String {
        switch self {
        case .fast:    "Fast"
        case .normal:  "Normal"
        case .maximum: "Maximum"
        }
    }

    var detail: String {
        switch self {
        case .fast:    "Quickest, largest file"
        case .normal:  "The usual balance"
        case .maximum: "Smallest file, slowest, needs the most memory"
        }
    }
}

/// Where extracted files go.
nonisolated enum DestinationPolicy: String, CaseIterable, Identifiable, Sendable {
    /// A folder alongside the archive.
    case besideArchive
    /// One folder for everything, chosen once.
    case fixedFolder
    /// Ask every time.
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideArchive: "Next to the archive"
        case .fixedFolder:   "A folder I choose"
        case .ask:           "Ask each time"
        }
    }
}

/// What opening an archive from the Finder does.
nonisolated enum OpenAction: String, CaseIterable, Identifiable, Sendable {
    case extract
    case browse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extract: "Extract it"
        case .browse:  "Show its contents"
        }
    }
}

@MainActor @Observable
final class Preferences {
    /// Injectable so tests get their own suite instead of editing the
    /// person's actual preferences.
    private let defaults: UserDefaults

    var destinationPolicy: DestinationPolicy {
        didSet { defaults.set(destinationPolicy.rawValue, forKey: "DestinationPolicy") }
    }

    /// Only meaningful for `.fixedFolder`.
    var fixedDestination: URL? {
        didSet { defaults.set(fixedDestination?.path(percentEncoded: false), forKey: "FixedDestination") }
    }

    /// What to do when an extracted file's name is already taken.
    ///
    /// `.ask` is deliberately not offered: a per-file modal in the middle of a
    /// forty-thousand-entry archive is not a feature. Renaming is the default
    /// because it is the only choice that cannot lose data.
    var overwritePolicy: SZKOverwritePolicy {
        didSet { defaults.set(overwritePolicy.rawValue, forKey: "OverwritePolicy") }
    }

    var preset: CompressionPreset {
        didSet { defaults.set(preset.rawValue, forKey: "CompressionPreset") }
    }

    var defaultFormat: String {
        didSet { defaults.set(defaultFormat, forKey: "DefaultFormat") }
    }

    /// Whether the password prompt offers to remember the password at all.
    var offersKeychain: Bool {
        didSet { defaults.set(offersKeychain, forKey: "OffersKeychain") }
    }

    /// Double-click in the Finder: unpack at once, or open a browser. A drop
    /// on the window always extracts — that gesture already says what it
    /// wants.
    var openAction: OpenAction {
        didSet { defaults.set(openAction.rawValue, forKey: "OpenAction") }
    }

    /// Adding a file whose name an archive already has: replace the entry
    /// only when the file on disk is newer. Off means the file always wins.
    var onlyReplaceOlder: Bool {
        didSet { defaults.set(onlyReplaceOlder, forKey: "OnlyReplaceOlder") }
    }

    /// Show the extraction or the new archive in the Finder when a job ends.
    var revealWhenDone: Bool {
        didSet { defaults.set(revealWhenDone, forKey: "RevealWhenDone") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "DestinationPolicy": DestinationPolicy.besideArchive.rawValue,
            "OverwritePolicy": SZKOverwritePolicy.autoRename.rawValue,
            "CompressionPreset": CompressionPreset.normal.rawValue,
            "DefaultFormat": "7z",
            "OffersKeychain": true,
            "RevealWhenDone": true,
            "OpenAction": OpenAction.extract.rawValue,
            "OnlyReplaceOlder": false,
        ])
        destinationPolicy = DestinationPolicy(
            rawValue: defaults.string(forKey: "DestinationPolicy") ?? "") ?? .besideArchive
        fixedDestination = defaults.string(forKey: "FixedDestination").map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        overwritePolicy = SZKOverwritePolicy(
            rawValue: defaults.integer(forKey: "OverwritePolicy")) ?? .autoRename
        preset = CompressionPreset(
            rawValue: defaults.string(forKey: "CompressionPreset") ?? "") ?? .normal
        defaultFormat = defaults.string(forKey: "DefaultFormat") ?? "7z"
        offersKeychain = defaults.bool(forKey: "OffersKeychain")
        revealWhenDone = defaults.bool(forKey: "RevealWhenDone")
        openAction = OpenAction(rawValue: defaults.string(forKey: "OpenAction") ?? "") ?? .extract
        onlyReplaceOlder = defaults.bool(forKey: "OnlyReplaceOlder")
    }
}

nonisolated extension SZKOverwritePolicy {
    var title: String {
        switch self {
        case .autoRename:     "Keep both"
        case .overwrite:      "Replace"
        case .skip:           "Skip"
        case .renameExisting: "Rename what is there"
        case .ask:            "Ask"
        @unknown default:     "Keep both"
        }
    }

    /// The policies the UI offers. `.ask` needs a handler we do not install.
    static var offered: [SZKOverwritePolicy] { [.autoRename, .skip, .overwrite] }
}
