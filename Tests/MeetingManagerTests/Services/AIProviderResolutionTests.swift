import XCTest
@testable import MeetingManager

final class AIProviderResolutionTests: XCTestCase {
    func testComputedFlagsTrackProvider() {
        var s = AppSettings.default
        s.aiProvider = .local
        XCTAssertTrue(s.useLocalLLM)
        XCTAssertTrue(s.aiEnabled)
        s.aiProvider = .gemini
        XCTAssertFalse(s.useLocalLLM)
        XCTAssertTrue(s.aiEnabled)
        s.aiProvider = .none
        XCTAssertFalse(s.aiEnabled)
        XCTAssertFalse(s.useLocalLLM)
    }

    func testModelIdentifiers() {
        XCTAssertEqual(AIBackendChoice.gemini(model: "gemini-2.5-flash").modelIdentifier, "gemini/gemini-2.5-flash")
        XCTAssertEqual(AIBackendChoice.claude(model: "claude-sonnet-4-6").modelIdentifier, "claude-sonnet-4-6")
        XCTAssertEqual(AIBackendChoice.ollama(model: "qwen3:8b").modelIdentifier, "ollama/qwen3:8b")
    }
}
