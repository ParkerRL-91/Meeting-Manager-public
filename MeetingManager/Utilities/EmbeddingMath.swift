import Accelerate

/// Small vector helpers shared by the mel-spectrum voice-profile path and the
/// FluidAudio enrollment path.
enum EmbeddingMath {
    /// Cosine similarity. Unlike a bare dot product, this does NOT assume unit
    /// vectors — a cluster's mean of unit segment embeddings is not itself
    /// unit-length — so it divides by both norms. Returns 0 on a dimension
    /// mismatch or a zero-norm input (undefined cosine).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var na: Float = 0
        var nb: Float = 0
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
