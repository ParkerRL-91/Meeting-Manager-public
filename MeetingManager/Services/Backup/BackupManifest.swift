import Foundation

/// Describes a backup folder's contents and provenance (PRJ-017 F5). Written as
/// `manifest.json` at the backup root; read back to validate a restore.
struct BackupManifest: Codable, Equatable {
    /// App marketing version that wrote the backup (Info.plist CFBundleShortVersionString).
    var appVersion: String
    /// The migration ids the source DB had applied. A restore is refused if this
    /// contains an id the current binary doesn't know (i.e. a backup from a newer
    /// app) — older backups are fine, the migrator upgrades them.
    var migrationIds: [String]
    var includesMedia: Bool
    var includesMarkdown: Bool
    var meetingCount: Int
    var transcriptCount: Int
    var decisionCount: Int
    var taskCount: Int
    /// Seconds since 1970 (Date is fine in Codable, but an explicit epoch keeps
    /// the JSON stable and timezone-free).
    var createdAt: Double
    var lastRunAt: Double

    static let fileName = "manifest.json"
    static let backupFolderName = "MeetingManagerBackup"
}
