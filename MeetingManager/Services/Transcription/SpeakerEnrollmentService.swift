import Foundation
import FluidAudio
import os

/// Cross-meeting voice identity via FluidAudio speaker enrollment (Phase 2).
///
/// Replaces the in-app mel-spectrum matching in `VoiceProfileService`: instead
/// of extracting embeddings and comparing them ourselves, we persist a per-Person
/// 256-dim wespeaker reference (`VoiceReference`) and hand it to FluidAudio's
/// clusterer before diarizing a meeting. FluidAudio matches clusters against the
/// enrolled references internally and returns the reference's id on matching
/// segments. Because we set each `Speaker.id` to the `Person.id`, a matched
/// cluster maps straight back to a person — and thus a name.
///
/// Flow per meeting (FluidAudio path only):
///   1. `enrolledSpeakers(for:)` — for each RSVP-accepted attendee with a stored
///      reference, build a `Speaker(id: personId, name: canonicalName, ...)`.
///   2. Pass them to `FluidAudioDiarizationService.diarize(..., enrolledSpeakers:)`.
///   3. `enrolledClusterMatches(result:)` — map clusters whose raw id is a known
///      `Person.id` back to that person plus a measured cosine similarity
///      (highest, audio-grounded signal).
///   4. After a confirmed attribution, `rebuildReference(...)` aggregates that
///      person's highest-confidence segment embeddings into a new reference.
/// FluidAudio's enrolled-voice type. Aliased so call sites (e.g. AppState) can
/// hold the value without importing FluidAudio, whose module also vends a same-
/// named `FluidAudio` struct that shadows member lookup of `FluidAudio.Speaker`.
typealias EnrolledSpeaker = Speaker

/// One FluidAudio enrollment hit: a diarization cluster ("Speaker N") matched an
/// enrolled person. `similarity` is the measured cosine between the cluster's
/// mean quality-gated segment embedding and the person's stored `VoiceReference`;
/// `nil` when no usable segment embeddings were available, in which case callers
/// fall back to the fixed legacy confidence tier.
struct EnrollmentMatch: Sendable, Equatable {
    let personId: String
    let name: String
    let similarity: Float?
}

@MainActor
final class SpeakerEnrollmentService {
    static let shared = SpeakerEnrollmentService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager",
                                category: "SpeakerEnrollment")

    /// FluidAudio wespeaker embeddings are 256-dim. A reference must match or the
    /// clusterer rejects it.
    static let embeddingDimension = 256

    /// Minimum segment quality to contribute to a reference. Low-quality segments
    /// (overlap, noise) drift the embedding, so we only aggregate confident ones.
    private static let minSegmentQuality: Float = 0.5

    private init() {}

    // MARK: - Enrollment (before diarization)

    /// Build the enrolled `Speaker` list for a meeting's RSVP-accepted attendees
    /// that have a stored voice reference. Attendees without a reference are
    /// simply not enrolled (their clusters fall through to vocative/LLM as before).
    func enrolledSpeakers(
        for meeting: Meeting,
        personRepo: PersonRepository,
        referenceRepo: VoiceReferenceRepository
    ) async -> [Speaker] {
        let accepted = meeting.acceptedParticipantList
        guard !accepted.isEmpty else { return [] }

        // Resolve accepted attendee strings to Person ids (RSVP gate already
        // applied by acceptedParticipantList — declined attendees excluded).
        var personIds: [String: Person] = [:]
        for raw in accepted {
            if let person = try? await personRepo.find(for: raw) {
                personIds[person.id] = person
            }
        }
        guard !personIds.isEmpty else { return [] }

        let refs = (try? await referenceRepo.references(forPersonIds: Array(personIds.keys))) ?? [:]
        var speakers: [Speaker] = []
        for (personId, ref) in refs {
            let emb = ref.embedding
            guard emb.count == Self.embeddingDimension else { continue }
            let name = personIds[personId]?.canonicalName ?? ref.personName
            speakers.append(Speaker(
                id: personId,
                name: name,
                currentEmbedding: emb,
                isPermanent: true
            ))
        }
        if !speakers.isEmpty {
            logger.info("Enrolled \(speakers.count) known voice(s) for meeting \(meeting.id, privacy: .public)")
        }
        return speakers
    }

    // MARK: - Resolve enrolled matches (after diarization)

    /// Map normalized "Speaker N" cluster labels to enrolled-person matches where
    /// FluidAudio matched an enrolled reference. A segment whose raw FluidAudio id
    /// equals a known `Person.id` means that cluster matched that enrolled voice.
    ///
    /// For each matched cluster, the returned `EnrollmentMatch` carries a measured
    /// cosine similarity between the cluster's mean quality-gated segment embedding
    /// and the person's enrolled reference — so a weak match can surface for review
    /// instead of riding a fixed tier. Caller treats these as the highest
    /// non-manual attribution signal (audio-grounded, above vocative/LLM).
    func enrolledClusterMatches(
        result: FluidDiarizationResult,
        enrolledSpeakers: [Speaker]
    ) -> [String: EnrollmentMatch] {
        guard !enrolledSpeakers.isEmpty else { return [:] }
        let speakerForId = Dictionary(uniqueKeysWithValues: enrolledSpeakers.map { ($0.id, $0) })

        // Group segments by their normalized cluster id, keeping the raw id (only
        // an enrolled cluster carries a Person.id there).
        var segmentsByCluster: [Int: (rawId: String, segments: [FluidDiarizationResult.Segment])] = [:]
        for segment in result.segments {
            segmentsByCluster[segment.speakerId, default: (segment.rawSpeakerId, [])].segments.append(segment)
        }

        var matches: [String: EnrollmentMatch] = [:]
        for (clusterId, group) in segmentsByCluster {
            guard let enrolled = speakerForId[group.rawId] else { continue }

            // Prefer the quality-gated segments; fall back to any valid-dimension
            // embeddings; if none survive, leave similarity nil (fixed-tier fallback).
            let gated = group.segments
                .filter { $0.qualityScore >= Self.minSegmentQuality && $0.embedding.count == Self.embeddingDimension }
                .map { $0.embedding }
            let valid = group.segments
                .filter { $0.embedding.count == Self.embeddingDimension }
                .map { $0.embedding }
            let pool = gated.isEmpty ? valid : gated

            let similarity: Float?
            if pool.isEmpty {
                similarity = nil
            } else {
                similarity = EmbeddingMath.cosineSimilarity(Self.meanEmbedding(pool), enrolled.currentEmbedding)
            }

            let label = "Speaker \(clusterId)"
            matches[label] = EnrollmentMatch(personId: enrolled.id, name: enrolled.name, similarity: similarity)
            logger.info("Enrollment match \(label, privacy: .public) → \(enrolled.name, privacy: .public) (cosine \(similarity.map { String(format: "%.3f", $0) } ?? "n/a", privacy: .public))")
        }
        return matches
    }

    // MARK: - Reference (re)build (after confirmed attribution)

    /// Rebuild a person's voice reference from their highest-confidence segments
    /// in a just-diarized meeting. Aggregates the segment embeddings (mean of the
    /// quality-gated segments assigned to `clusterLabel`) into a single 256-dim
    /// vector and persists it keyed by `Person.id`.
    ///
    /// Called on a confirmed/high-confidence attribution so the reference reflects
    /// the latest audio and improves future matches.
    func rebuildReference(
        personName: String,
        clusterLabel: String,
        result: FluidDiarizationResult,
        personRepo: PersonRepository,
        referenceRepo: VoiceReferenceRepository
    ) async {
        // clusterLabel is "Speaker N" — pull its normalized int id.
        guard let clusterId = Self.clusterIdFromLabel(clusterLabel) else { return }

        let embeddings: [[Float]] = result.segments
            .filter { $0.speakerId == clusterId
                && $0.qualityScore >= Self.minSegmentQuality
                && $0.embedding.count == Self.embeddingDimension }
            .sorted { $0.qualityScore > $1.qualityScore }
            .prefix(Self.maxSegmentsPerReference)
            .map { $0.embedding }

        guard !embeddings.isEmpty else { return }

        let aggregate = Self.meanEmbedding(embeddings)
        guard aggregate.count == Self.embeddingDimension else { return }

        guard let person = try? await personRepo.findOrCreate(for: personName) else { return }

        // EMA-blend into the stored reference instead of wholesale replacing
        // it (mirrors VoiceProfileRepository.merge): one borderline meeting
        // must not overwrite a reference built from many confirmed segments.
        // α 0.3 — recent audio refines, history dominates. Re-normalized so
        // FluidAudio's cosine matching keeps unit-length semantics.
        var blended = aggregate
        if let existing = try? await referenceRepo.reference(forPersonId: person.id),
           existing.embedding.count == aggregate.count {
            let alpha: Float = 0.3
            blended = zip(existing.embedding, aggregate).map { old, new in
                old * (1 - alpha) + new * alpha
            }
        }
        let norm = sqrt(blended.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 0 {
            blended = blended.map { $0 / norm }
        }

        try? await referenceRepo.save(
            personId: person.id,
            personName: person.canonicalName,
            embedding: blended,
            segmentCount: embeddings.count
        )
        logger.info("Rebuilt voice reference for \(person.canonicalName, privacy: .public) from \(embeddings.count) segment(s) (EMA-blended)")
    }

    // MARK: - Private

    /// Cap the number of segments aggregated so one talkative meeting doesn't
    /// dominate; the highest-quality segments are kept (sorted before slicing).
    private static let maxSegmentsPerReference = 30

    private static func clusterIdFromLabel(_ label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("speaker ") else { return nil }
        return Int(trimmed.dropFirst("speaker ".count).trimmingCharacters(in: .whitespaces))
    }

    private static func meanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for emb in embeddings where emb.count == first.count {
            for i in 0..<emb.count { sum[i] += emb[i] }
        }
        let n = Float(embeddings.count)
        return sum.map { $0 / n }
    }
}
