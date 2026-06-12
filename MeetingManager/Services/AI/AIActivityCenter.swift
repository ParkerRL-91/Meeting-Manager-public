import Foundation
import os

/// Every long-running AI activity, visible in one place (TASK-073). The
/// task queue shows durable work; this registry shows the EPHEMERAL kind —
/// chat answers, daily briefs, prep enrichment, embeddings, cloud calls —
/// so "why is this slow" always has an answer in the Activities list.
/// Entries auto-remove on completion: a long chat session leaves nothing
/// behind (the user's explicit ask), and failures surface through their
/// own paths (the queue, chat bubbles, banners).
@MainActor
@Observable
final class AIActivityCenter {
    static let shared = AIActivityCenter()
    private init() {}

    struct Activity: Identifiable {
        let id: UUID
        let label: String
        let startedAt: Date
    }

    private(set) var activities: [Activity] = []

    @discardableResult
    func begin(_ label: String) -> UUID {
        let id = UUID()
        activities.append(Activity(id: id, label: label, startedAt: Date()))
        return id
    }

    func end(_ id: UUID) {
        activities.removeAll { $0.id == id }
    }
}
