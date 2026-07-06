import XCTest
import FluidAudio
@testable import MeetingManager

// Covers the measured-cosine enrollment matching added when FluidAudio enrollment
// moved onto the inline batch path: enrolledClusterMatches computes a real
// similarity per cluster (quality-gated mean vs the enrolled reference), and the
// shared EmbeddingMath.cosineSimilarity handles non-unit vectors.

final class EmbeddingMathTests: XCTestCase {

    func testCosineHandlesNonUnitVectors() {
        // Parallel but different magnitudes → 1.0 (bare dot product would give 15).
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([3, 0], [5, 0]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([2, 2], [5, 5]), 1.0, accuracy: 0.0001)
    }

    func testCosineGuards() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([], []), 0.0)              // empty
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2, 3], [1, 2]), 0.0)   // dim mismatch
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([0, 0], [1, 1]), 0.0)      // zero norm
    }
}

@MainActor
final class SpeakerEnrollmentMatchTests: XCTestCase {

    private let dim = SpeakerEnrollmentService.embeddingDimension   // 256

    /// A `dim`-length one-hot vector.
    private func vec(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[hot] = 1
        return v
    }

    private func segment(cluster: Int, rawId: String, quality: Float, embedding: [Float]) -> FluidDiarizationResult.Segment {
        FluidDiarizationResult.Segment(
            speakerId: cluster, rawSpeakerId: rawId,
            startTime: 0, endTime: 1, qualityScore: quality, embedding: embedding
        )
    }

    private func enrolled(id: String, name: String, embedding: [Float]) -> EnrolledSpeaker {
        EnrolledSpeaker(id: id, name: name, currentEmbedding: embedding, isPermanent: true)
    }

    func testIdenticalEmbeddingScoresNearOne() {
        let e = vec(0)
        let result = FluidDiarizationResult(
            segments: [segment(cluster: 1, rawId: "personA", quality: 0.9, embedding: e)],
            speakerCount: 1
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result, enrolledSpeakers: [enrolled(id: "personA", name: "Alice", embedding: e)]
        )
        XCTAssertEqual(matches["Speaker 1"]?.name, "Alice")
        XCTAssertEqual(matches["Speaker 1"]?.similarity ?? 0, 1.0, accuracy: 0.001)
    }

    func testOrthogonalEmbeddingScoresNearZero() {
        let result = FluidDiarizationResult(
            segments: [segment(cluster: 1, rawId: "personA", quality: 0.9, embedding: vec(1))],
            speakerCount: 1
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result, enrolledSpeakers: [enrolled(id: "personA", name: "Alice", embedding: vec(0))]
        )
        XCTAssertEqual(matches["Speaker 1"]?.similarity ?? 99, 0.0, accuracy: 0.001)
    }

    func testLowQualitySegmentsExcludedFromMean() {
        // Cluster 1: a high-quality segment matching the reference, and a
        // low-quality (< 0.5) orthogonal one. The low-quality segment must be
        // dropped from the mean, so the score stays ~1.0.
        let result = FluidDiarizationResult(
            segments: [
                segment(cluster: 1, rawId: "personA", quality: 0.9, embedding: vec(0)),
                segment(cluster: 1, rawId: "personA", quality: 0.3, embedding: vec(1)),
            ],
            speakerCount: 1
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result, enrolledSpeakers: [enrolled(id: "personA", name: "Alice", embedding: vec(0))]
        )
        XCTAssertEqual(matches["Speaker 1"]?.similarity ?? 0, 1.0, accuracy: 0.001)
    }

    func testMissingEmbeddingsYieldNilSimilarity() {
        // Matched by rawId, but the segment carries no usable (256-dim) embedding.
        let result = FluidDiarizationResult(
            segments: [segment(cluster: 1, rawId: "personA", quality: 0.9, embedding: [])],
            speakerCount: 1
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result, enrolledSpeakers: [enrolled(id: "personA", name: "Alice", embedding: vec(0))]
        )
        let match = matches["Speaker 1"]
        XCTAssertNotNil(match, "still matched to the person by rawId")
        XCTAssertNil(match?.similarity, "no measurable similarity → fixed-tier fallback downstream")
    }

    func testTwoClustersResolveIndependently() {
        let result = FluidDiarizationResult(
            segments: [
                segment(cluster: 1, rawId: "personA", quality: 0.9, embedding: vec(0)),
                segment(cluster: 2, rawId: "personB", quality: 0.9, embedding: vec(1)),
            ],
            speakerCount: 2
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result,
            enrolledSpeakers: [
                enrolled(id: "personA", name: "Alice", embedding: vec(0)),
                enrolled(id: "personB", name: "Bob", embedding: vec(1)),
            ]
        )
        XCTAssertEqual(matches["Speaker 1"]?.name, "Alice")
        XCTAssertEqual(matches["Speaker 2"]?.name, "Bob")
        XCTAssertEqual(matches["Speaker 1"]?.similarity ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(matches["Speaker 2"]?.similarity ?? 0, 1.0, accuracy: 0.001)
    }

    func testUnenrolledClusterHasNoMatch() {
        let result = FluidDiarizationResult(
            segments: [segment(cluster: 1, rawId: "spk0", quality: 0.9, embedding: vec(0))],
            speakerCount: 1
        )
        let matches = SpeakerEnrollmentService.shared.enrolledClusterMatches(
            result: result, enrolledSpeakers: [enrolled(id: "personA", name: "Alice", embedding: vec(0))]
        )
        XCTAssertTrue(matches.isEmpty, "cluster whose raw id isn't an enrolled Person.id is not matched")
    }
}
