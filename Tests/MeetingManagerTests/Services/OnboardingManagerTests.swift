import XCTest
@testable import MeetingManager

@MainActor
final class OnboardingManagerTests: XCTestCase {

    private var manager: OnboardingManager!

    override func setUp() {
        super.setUp()
        // Reset ALL persisted onboarding state for test isolation. currentStep and
        // aiChoice persist on every mutation, so without clearing the step key a
        // prior test could leak its step into the next manager's init.
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "onboardingCurrentStep")
        UserDefaults.standard.removeObject(forKey: "onboardingAIChoice")
        manager = OnboardingManager()
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "onboardingCurrentStep")
        UserDefaults.standard.removeObject(forKey: "onboardingAIChoice")
    }

    // MARK: - Initial State

    func testInitialCurrentStepIsWelcome() {
        XCTAssertEqual(manager.currentStep, .welcome)
    }

    // MARK: - Step Navigation
    // Flow (OnboardingManager.visibleSteps, which nextStep/previousStep walk):
    // welcome -> storage -> calendar -> localModel -> audioRetention
    //         -> knowledgeBase -> ready
    //
    // Note this is NOT allCases order: .localModel/.audioRetention/.storage
    // have legacy-pinned raw values and are placed by visibleSteps instead.

    func testNextStepFromWelcome() {
        manager.currentStep = .welcome
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .storage)
    }

    func testNextStepFromCalendar() {
        manager.currentStep = .calendar
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .localModel)
    }

    func testNextStepFromKnowledgeBase() {
        manager.currentStep = .knowledgeBase
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready)
    }

    func testNextStepFromReadyStaysAtReady() {
        manager.currentStep = .ready
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready, "Should not advance past the last step")
    }

    func testPreviousStepFromCalendar() {
        manager.currentStep = .calendar
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .storage)
    }

    func testPreviousStepFromKnowledgeBase() {
        manager.currentStep = .knowledgeBase
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .audioRetention)
    }

    func testPreviousStepFromReady() {
        manager.currentStep = .ready
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .knowledgeBase)
    }

    func testPreviousStepFromWelcomeStaysAtWelcome() {
        manager.currentStep = .welcome
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome, "Should not go before the first step")
    }

    // MARK: - Complete

    func testCompleteMarksAsCompleted() {
        XCTAssertFalse(manager.isCompleted)
        manager.complete()
        XCTAssertTrue(manager.isCompleted)
    }

    func testCompletePersistsToUserDefaults() {
        manager.complete()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "onboardingCompleted"))
    }

    // MARK: - Onboarding Step Enum

    func testAllStepsExist() {
        let allSteps = OnboardingManager.OnboardingStep.allCases
        XCTAssertEqual(allSteps.count, 7)
    }

    /// Navigation walks `visibleSteps`, so its order is the real contract —
    /// pin it, not `allCases` (whose order follows legacy raw values).
    func testVisibleStepsOrder() {
        XCTAssertEqual(manager.visibleSteps,
                       [.welcome, .storage, .calendar, .localModel,
                        .audioRetention, .knowledgeBase, .ready])
    }

    func testStepRawValues() {
        XCTAssertEqual(OnboardingManager.OnboardingStep.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingManager.OnboardingStep.calendar.rawValue, 1)
        XCTAssertEqual(OnboardingManager.OnboardingStep.knowledgeBase.rawValue, 2)
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.rawValue, 3)
        // Appended later; raw values are legacy-pinned because they persist.
        XCTAssertEqual(OnboardingManager.OnboardingStep.localModel.rawValue, 4)
        XCTAssertEqual(OnboardingManager.OnboardingStep.audioRetention.rawValue, 5)
        XCTAssertEqual(OnboardingManager.OnboardingStep.storage.rawValue, 6)
    }

    func testStepTitles() {
        XCTAssertEqual(OnboardingManager.OnboardingStep.welcome.title, "Welcome")
        XCTAssertEqual(OnboardingManager.OnboardingStep.calendar.title, "Calendar")
        XCTAssertEqual(OnboardingManager.OnboardingStep.knowledgeBase.title, "Knowledge Base")
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.title, "Ready")
        XCTAssertEqual(OnboardingManager.OnboardingStep.localModel.title, "On-Device AI")
        XCTAssertEqual(OnboardingManager.OnboardingStep.audioRetention.title, "Audio")
        XCTAssertEqual(OnboardingManager.OnboardingStep.storage.title, "Recordings")
    }

    // MARK: - Full Navigation Cycle

    func testFullForwardNavigationCycle() {
        XCTAssertEqual(manager.currentStep, .welcome)
        for expected in manager.visibleSteps.dropFirst() {
            manager.nextStep()
            XCTAssertEqual(manager.currentStep, expected)
        }
        XCTAssertEqual(manager.currentStep, .ready)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready, "Should not advance past the last step")
    }

    func testFullBackwardNavigationCycle() {
        manager.currentStep = .ready
        for expected in manager.visibleSteps.dropLast().reversed() {
            manager.previousStep()
            XCTAssertEqual(manager.currentStep, expected)
        }
        XCTAssertEqual(manager.currentStep, .welcome)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome, "Should not go before the first step")
    }
}
