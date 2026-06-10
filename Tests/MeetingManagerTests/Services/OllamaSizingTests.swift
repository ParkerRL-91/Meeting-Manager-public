import XCTest
@testable import MeetingManager

/// Pins the ADR-015 RAM-aware context policy: the physical-memory banding,
/// the bucket-then-clamp window sizing with its half-window output guard,
/// and the head/tail prompt truncation used when a capped window can't fit
/// the full input.
@MainActor
final class OllamaSizingTests: XCTestCase {

    private func gib(_ n: UInt64) -> UInt64 { n * 1_073_741_824 }

    // MARK: - Physical-memory banding

    func testContextCapBands() {
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(8)), 16_384)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(16)), 16_384,
                       "16 GB M4 baseline: 16K ctx ≈ 2.3 GB KV — the largest window that leaves room for weights + WhisperKit + macOS")
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(18)), 16_384)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(24)), 32_768)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(32)), 65_536)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(36)), 65_536)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(48)), 131_072)
        XCTAssertEqual(OllamaService.contextCap(forPhysicalMemoryBytes: gib(128)), 131_072)
    }

    // MARK: - Window sizing

    func testSmallRequestUsesSmallestBucketWithNoTruncation() {
        let sizing = OllamaService.resolveSizing(inputTokens: 1_000, requestedPredict: 2_048, cap: 131_072)
        XCTAssertEqual(sizing.numCtx, 8_192)
        XCTAssertNil(sizing.inputTokenBudget)
    }

    func testBucketRoundsUpToFitInputPlusOutput() {
        let sizing = OllamaService.resolveSizing(inputTokens: 10_000, requestedPredict: 6_144, cap: 131_072)
        XCTAssertEqual(sizing.numCtx, 16_384)
        XCTAssertNil(sizing.inputTokenBudget)
    }

    func testMarathonInputUsesTopRungWhenCapAllows() {
        // resolveSizing is pure — the cap argument is already
        // min(ramContextCap, modelContextLimit) at the call sites. With an
        // unconstrained cap, 70K input tokens get the 131 072 rung instead
        // of the old 65 536 ceiling that silently let Ollama drop the
        // prompt start server-side.
        let sizing = OllamaService.resolveSizing(inputTokens: 70_000, requestedPredict: 8_192, cap: 131_072)
        XCTAssertEqual(sizing.numCtx, 131_072)
        XCTAssertNil(sizing.inputTokenBudget)
    }

    // MARK: - Trained-window limits

    func testModelContextLimitsReflectTrainedWindows() {
        // Qwen3's "128K" is YaRN-extended and not enabled in Ollama's default
        // tags — the trained window is 40 960, and exceeding it degrades
        // attention silently rather than erroring.
        XCTAssertEqual(OllamaService.modelContextLimit(for: "qwen3:8b"), 40_960)
        XCTAssertEqual(OllamaService.modelContextLimit(for: "qwen3:4b"), 40_960)
        XCTAssertEqual(OllamaService.modelContextLimit(for: "llama3.1:8b"), 65_536)
        XCTAssertEqual(OllamaService.modelContextLimit(for: "llama3.2:3b"), 65_536)
        XCTAssertEqual(OllamaService.modelContextLimit(for: "qwen2.5:7b-instruct"), 32_768)
        XCTAssertEqual(OllamaService.modelContextLimit(for: "mistral:7b"), 32_768,
                       "Unknown models get a conservative middle ground")
    }

    func testQwen3WindowBindsBeforeRamOnBigMachines() {
        // A 64 GB machine's RAM band is 131 072, but qwen3:8b must still be
        // clamped to its 40 960 trained window.
        let cap = min(
            OllamaService.contextCap(forPhysicalMemoryBytes: gib(64)),
            OllamaService.modelContextLimit(for: "qwen3:8b")
        )
        let sizing = OllamaService.resolveSizing(inputTokens: 70_000, requestedPredict: 8_192, cap: cap)
        XCTAssertEqual(sizing.numCtx, 40_960)
        XCTAssertEqual(sizing.inputTokenBudget, 40_960 - 8_192)
    }

    func testCapClampsWindowAndTruncatesInput() {
        // Two-hour meeting on the 16 GB baseline: window pins to the cap and
        // the input budget is whatever the output reserve leaves behind.
        let sizing = OllamaService.resolveSizing(inputTokens: 30_000, requestedPredict: 8_192, cap: 16_384)
        XCTAssertEqual(sizing.numCtx, 16_384)
        XCTAssertEqual(sizing.inputTokenBudget, 8_192)
    }

    func testOversizedPredictKeepsAtMostHalfTheWindow() {
        // Outline path (16 384 output + 4 096 thinking) on a 16 GB machine:
        // the output reserve may not squeeze the input budget below half.
        let sizing = OllamaService.resolveSizing(inputTokens: 5_000, requestedPredict: 20_480, cap: 16_384)
        XCTAssertEqual(sizing.numCtx, 16_384)
        XCTAssertEqual(sizing.inputTokenBudget, 8_192)
    }

    func testBeyondNativeMaxTruncatesEvenUncapped() {
        let sizing = OllamaService.resolveSizing(inputTokens: 150_000, requestedPredict: 8_192, cap: 131_072)
        XCTAssertEqual(sizing.numCtx, 131_072)
        XCTAssertEqual(sizing.inputTokenBudget, 122_880)
    }

    // MARK: - Head/tail truncation

    func testShortPromptPassesThroughUnchanged() {
        let prompt = "short transcript"
        XCTAssertEqual(OllamaService.truncatedUserPrompt(prompt, maxUserChars: 40_000), prompt)
    }

    func testLongPromptKeepsHeadAndTailWithNotice() {
        let head = String(repeating: "A", count: 10_000)
        let tail = String(repeating: "Z", count: 10_000)
        let prompt = head + String(repeating: "M", count: 80_000) + tail
        let result = OllamaService.truncatedUserPrompt(prompt, maxUserChars: 40_000)

        XCTAssertLessThanOrEqual(result.count, 40_000)
        XCTAssertTrue(result.contains("[... transcript truncated for length ...]"))
        XCTAssertTrue(result.hasPrefix("AAAA"), "Intro/agenda (head 10%) must survive")
        XCTAssertTrue(result.hasSuffix("ZZZZ"), "Decisions/actions (tail 90%) must survive")
    }

    func testDegenerateBudgetsReturnPromptUnchanged() {
        let prompt = String(repeating: "x", count: 1_000)
        XCTAssertEqual(OllamaService.truncatedUserPrompt(prompt, maxUserChars: 0), prompt)
        XCTAssertEqual(OllamaService.truncatedUserPrompt(prompt, maxUserChars: -50), prompt)
        // keepEnd goes non-positive below ~112 chars — refuse to emit a
        // notice-only prompt and pass through instead.
        XCTAssertEqual(OllamaService.truncatedUserPrompt(prompt, maxUserChars: 50), prompt)
    }
}
