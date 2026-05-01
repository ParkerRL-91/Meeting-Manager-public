import SwiftUI
import os

/// Self-contained "Reset App Permissions" button — single source of truth
/// shared by the permission gate, the onboarding permissions step, and
/// Settings → General → Troubleshooting.
///
/// Why three placements: macOS TCC ties grants to a code signature. With
/// self-signed builds (everything pre-Developer-ID), the binding can be
/// invalidated by an update — the toggle stays visible in System Settings
/// while macOS internally rejects the grant. Users hit this surface in
/// three distinct moments:
///
///   1. **Gate** — they see "permissions needed" right after launching an
///      updated build. Reset has to be on this screen or they're stuck.
///   2. **Onboarding** — first-run users following the setup flow. Same
///      reset path, in case macOS already had a stale entry from a prior
///      install.
///   3. **Settings → Troubleshooting** — discoverable later, after the
///      user has dismissed the gate (e.g. partial grants).
///
/// Same button, same tccutil reset, same caption — guaranteed identical
/// behaviour across the three surfaces.
struct PermissionResetButton: View {

    /// Visual variant. Use `.prominent` on full-page surfaces (gate,
    /// onboarding) where the button is the primary recovery action.
    /// Use `.compact` inline in Settings.
    enum Style { case prominent, compact }

    /// Style variant.
    var style: Style = .prominent

    /// Optional caller hook — fires after a successful reset so the host
    /// view can refresh its UI (e.g. re-poll auth state).
    var onResetComplete: (() -> Void)?

    @State private var resetMessage: String?
    @State private var isResetting = false

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app", category: "ui")

    var body: some View {
        VStack(spacing: 8) {
            Text("Stuck? If System Settings shows permissions as granted but Meeting Manager still asks for them, click below to reset. macOS will re-prompt fresh.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

            // Two button variants instead of a runtime-picked style — Swift's
            // ButtonStyle erasure is fiddly enough that an `if`/`else` is the
            // cleaner way to apply `.borderedProminent` vs `.bordered`.
            if style == .prominent {
                Button {
                    runReset()
                } label: {
                    resetButtonLabel
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.regular)
                .disabled(isResetting)
            } else {
                Button {
                    runReset()
                } label: {
                    resetButtonLabel
                }
                .buttonStyle(.bordered)
                .tint(Color.appAccent)
                .controlSize(.small)
                .disabled(isResetting)
            }

            if let resetMessage {
                Text(resetMessage)
                    .font(.caption)
                    .foregroundStyle(resetMessage.starts(with: "✓") ? Color.appSuccess : Color.appWarning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Run `tccutil reset` for every TCC service this app uses. Bundle-ID
    /// scoped so it only affects Meeting Manager's grants. No admin needed.
    private func runReset() {
        Self.logger.info("[PermissionResetButton] reset invoked")
        isResetting = true
        let services = ["Microphone", "Calendar", "Reminders", "ScreenCapture"]
        Task { @MainActor in
            var failed: [String] = []
            for service in services {
                let task = Process()
                task.launchPath = "/usr/bin/tccutil"
                task.arguments = ["reset", service, "com.meetingmanager.app"]
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus != 0 {
                        failed.append(service)
                        Self.logger.warning("[PermissionResetButton] tccutil reset \(service, privacy: .public) exited \(task.terminationStatus)")
                    } else {
                        Self.logger.info("[PermissionResetButton] tccutil reset \(service, privacy: .public) ok")
                    }
                } catch {
                    failed.append(service)
                    Self.logger.error("[PermissionResetButton] tccutil reset \(service, privacy: .public) threw: \(error.localizedDescription, privacy: .public)")
                }
            }
            if failed.isEmpty {
                resetMessage = "✓ Permissions cleared. Use the Grant / Open Settings buttons above to re-grant."
            } else {
                resetMessage = "Reset failed for: \(failed.joined(separator: ", ")). Try the System Settings fallback."
            }
            isResetting = false
            onResetComplete?()
            // Auto-clear the message after 8s so it doesn't linger.
            try? await Task.sleep(for: .seconds(8))
            resetMessage = nil
        }
    }
}

extension PermissionResetButton {
    /// The label content shared between the prominent and compact button
    /// variants. Pulled into its own view so we don't duplicate the
    /// HStack + spinner-or-icon switch in two places.
    @ViewBuilder
    fileprivate var resetButtonLabel: some View {
        HStack(spacing: 6) {
            if isResetting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.counterclockwise.circle")
            }
            Text("Reset App Permissions")
        }
    }
}
