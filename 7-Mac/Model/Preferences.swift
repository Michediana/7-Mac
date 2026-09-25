//
//  Preferences.swift
//  7-Mac
//
//  The app's preferences, backed by UserDefaults.
//

import AppKit
import Foundation
import Observation
import SevenZipKit

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
        case .besideArchive: String(localized: "Next to the archive")
        case .fixedFolder:   String(localized: "A folder I choose")
        case .ask:           String(localized: "Ask each time")
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
        case .extract: String(localized: "Extract it")
        case .browse:  String(localized: "Show its contents")
        }
    }
}

/// Light, dark, or whatever the system is set to.
nonisolated enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Same as the system")
        case .light:  String(localized: "Light")
        case .dark:   String(localized: "Dark")
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

    /// The profile the compress sheet starts from: the one used last.
    var profileID: UUID {
        didSet { defaults.set(profileID.uuidString, forKey: "CompressionProfile") }
    }

    /// Profiles the person saved. The three built-in ones are not stored.
    private(set) var savedProfiles: [CompressionProfile] {
        didSet { defaults.set(try? JSONEncoder().encode(savedProfiles), forKey: "SavedProfiles") }
    }

    /// Leave out the files macOS scatters everywhere — `.DS_Store`, `._*`
    /// resource forks and the like — when compressing.
    var excludesSystemFiles: Bool {
        didSet { defaults.set(excludesSystemFiles, forKey: "ExcludesSystemFiles") }
    }

    /// The names that means, editable.
    var excludedNames: [String] {
        didSet { defaults.set(excludedNames, forKey: "ExcludedNames") }
    }

    /// Store symbolic links as links; off follows them and stores the target.
    var storesSymbolicLinks: Bool {
        didSet { defaults.set(storesSymbolicLinks, forKey: "StoresSymbolicLinks") }
    }

    /// Store further hard links to a file as links rather than copies.
    var storesHardLinks: Bool {
        didSet { defaults.set(storesHardLinks, forKey: "StoresHardLinks") }
    }

    static let defaultExcludedNames = [
        ".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", "Icon\r",
    ]

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

    var appearance: AppearanceChoice {
        didSet {
            defaults.set(appearance.rawValue, forKey: "Appearance")
            applyAppearance()
        }
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
            "ExcludesSystemFiles": true,
            "ExcludedNames": Self.defaultExcludedNames,
            "StoresSymbolicLinks": true,
            "StoresHardLinks": true,
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
        savedProfiles = defaults.data(forKey: "SavedProfiles")
            .flatMap { try? JSONDecoder().decode([CompressionProfile].self, from: $0) } ?? []
        // M2 stored a preset name; carry it over to the matching profile.
        let legacy: [String: UUID] = ["fast": CompressionProfile.fast.id,
                                      "normal": CompressionProfile.normal.id,
                                      "maximum": CompressionProfile.maximum.id]
        profileID = defaults.string(forKey: "CompressionProfile").flatMap(UUID.init(uuidString:))
            ?? defaults.string(forKey: "CompressionPreset").flatMap { legacy[$0] }
            ?? CompressionProfile.normal.id
        excludesSystemFiles = defaults.bool(forKey: "ExcludesSystemFiles")
        excludedNames = defaults.stringArray(forKey: "ExcludedNames") ?? Self.defaultExcludedNames
        storesSymbolicLinks = defaults.bool(forKey: "StoresSymbolicLinks")
        storesHardLinks = defaults.bool(forKey: "StoresHardLinks")
        defaultFormat = defaults.string(forKey: "DefaultFormat") ?? "7z"
        offersKeychain = defaults.bool(forKey: "OffersKeychain")
        revealWhenDone = defaults.bool(forKey: "RevealWhenDone")
        openAction = OpenAction(rawValue: defaults.string(forKey: "OpenAction") ?? "") ?? .extract
        onlyReplaceOlder = defaults.bool(forKey: "OnlyReplaceOlder")
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "Appearance") ?? "") ?? .system
    }
}

// MARK: - Appearance

extension Preferences {
    /// Sets every window's appearance. `nil` follows the system.
    func applyAppearance() {
        guard let app = NSApp else { return }
        switch appearance {
        case .system: app.appearance = nil
        case .light:  app.appearance = NSAppearance(named: .aqua)
        case .dark:   app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Profiles

extension Preferences {
    /// Built-in first, then the person's own, in the order they were saved.
    var profiles: [CompressionProfile] { CompressionProfile.builtIn + savedProfiles }

    func profile(withID id: UUID) -> CompressionProfile {
        profiles.first { $0.id == id } ?? .normal
    }

    /// Saves `profile` under `name`, replacing a saved one of the same name.
    @discardableResult
    func save(_ profile: CompressionProfile, as name: String) -> CompressionProfile {
        var saved = profile
        saved.name = name
        if let existing = savedProfiles.firstIndex(where: { $0.name == name }) {
            saved.id = savedProfiles[existing].id
            savedProfiles[existing] = saved
        } else {
            saved.id = UUID()
            savedProfiles.append(saved)
        }
        return saved
    }

    func deleteProfile(_ id: UUID) {
        savedProfiles.removeAll { $0.id == id }
        if profileID == id { profileID = CompressionProfile.normal.id }
    }

    /// What a new archive leaves out.
    var creationExclusions: [String] { excludesSystemFiles ? excludedNames : [] }
}

nonisolated extension SZKOverwritePolicy {
    var title: String {
        switch self {
        case .autoRename:     String(localized: "Keep both")
        case .overwrite:      String(localized: "Replace")
        case .skip:           String(localized: "Skip")
        case .renameExisting: String(localized: "Rename what is there")
        case .ask:            String(localized: "Ask")
        @unknown default:     String(localized: "Keep both")
        }
    }

    /// The policies the UI offers. `.ask` needs a handler we do not install.
    static var offered: [SZKOverwritePolicy] { [.autoRename, .skip, .overwrite] }
}
