//
//  Updater.swift
//  7-Mac
//
//  Sparkle, reading the appcast that Scripts/release.sh attaches to each
//  GitHub release.
//

import Foundation
import Observation
import Sparkle

@Observable
final class Updater {
    static let shared = Updater()

    /// False while a check is already running, and always false in a build
    /// that cannot verify an update -- see `init`.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        // A build from source has no public key, and Sparkle refuses to
        // install what it cannot verify. Better no menu item than one that
        // only ever ends in an error.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
