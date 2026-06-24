import Foundation

/// The single source of truth for which AI is active. Exactly one provider can
/// be selected at a time — this makes "two providers active at once"
/// unrepresentable rather than merely discouraged. Resolution reads only this.
enum AIProvider: String, Codable, CaseIterable, Sendable {
    case none
    case local
    case claude
    case gemini
}
