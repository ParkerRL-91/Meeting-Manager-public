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
    private let delegate = UpdateDelegate()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
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

    /// The date of the last successful update check, or nil if never checked.
    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }
}

// MARK: - Update Delegate

/// Clears ephemeral caches before Sparkle relaunches the app after installing an update.
private final class UpdateDelegate: NSObject, SPUUpdaterDelegate {

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        clearCaches()
    }

    private func clearCaches() {
        let fm = FileManager.default
        let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.meetingmanager.app")
        if let url = cacheURL, fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        let tempURL = fm.temporaryDirectory.appendingPathComponent("MeetingManager")
        if fm.fileExists(atPath: tempURL.path) {
            try? fm.removeItem(at: tempURL)
        }
    }
}
