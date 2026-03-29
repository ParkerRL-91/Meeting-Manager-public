import Foundation
import Sparkle
import os

/// Manages automatic app updates via the Sparkle framework.
///
/// Sparkle checks a remote appcast XML file for new versions and presents
/// a native update dialog when one is available. Updates are downloaded,
/// verified (via EdDSA signature), and installed automatically.
@MainActor
final class UpdateService: ObservableObject {

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,   // don't auto-check on launch; no valid feed URL yet
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Ensure automatic checks are off until the user opts in
        updaterController.updater.automaticallyChecksForUpdates = false
    }

    /// The underlying SPUUpdater for SwiftUI CheckForUpdatesView binding.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Manually trigger an update check.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Whether automatic update checks are enabled.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
}
