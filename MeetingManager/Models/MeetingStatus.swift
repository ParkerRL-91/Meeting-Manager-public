import SwiftUI

enum MeetingStatus: String, Codable, CaseIterable {
    case scheduled
    case notified
    case recording
    case transcribing
    case summarizing
    case complete
    case cancelled

    var displayName: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .notified: return "Starting Soon"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .summarizing: return "Summarizing"
        case .complete: return "Complete"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .scheduled: return .blue
        case .notified: return .orange
        case .recording: return .red
        case .transcribing: return .purple
        case .summarizing: return .indigo
        case .complete: return .green
        case .cancelled: return .gray
        }
    }

    var icon: String {
        switch self {
        case .scheduled: return "calendar"
        case .notified: return "bell.fill"
        case .recording: return "record.circle"
        case .transcribing: return "text.word.spacing"
        case .summarizing: return "sparkles"
        case .complete: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var isActive: Bool {
        self == .recording || self == .transcribing || self == .summarizing
    }
}
