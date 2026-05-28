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
    // Flow: welcome -> calendar -> knowledgeBase -> ready

    func testNextStepFromWelcome() {
        manager.currentStep = .welcome
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .calendar)
    }

    func testNextStepFromCalendar() {
        manager.currentStep = .calendar
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .knowledgeBase)
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
        XCTAssertEqual(manager.currentStep, .welcome)
    }

    func testPreviousStepFromKnowledgeBase() {
        manager.currentStep = .knowledgeBase
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .calendar)
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
        XCTAssertEqual(allSteps.count, 4)
    }

    func testStepRawValues() {
        XCTAssertEqual(OnboardingManager.OnboardingStep.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingManager.OnboardingStep.calendar.rawValue, 1)
        XCTAssertEqual(OnboardingManager.OnboardingStep.knowledgeBase.rawValue, 2)
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.rawValue, 3)
    }

    func testStepTitles() {
        XCTAssertEqual(OnboardingManager.OnboardingStep.welcome.title, "Welcome")
        XCTAssertEqual(OnboardingManager.OnboardingStep.calendar.title, "Calendar")
        XCTAssertEqual(OnboardingManager.OnboardingStep.knowledgeBase.title, "Knowledge Base")
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.title, "Ready")
    }

    // MARK: - Full Navigation Cycle

    func testFullForwardNavigationCycle() {
        XCTAssertEqual(manager.currentStep, .welcome)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .calendar)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .knowledgeBase)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready) // Stays at ready
    }

    func testFullBackwardNavigationCycle() {
        manager.currentStep = .ready
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .knowledgeBase)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .calendar)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome) // Stays at welcome
    }
}
