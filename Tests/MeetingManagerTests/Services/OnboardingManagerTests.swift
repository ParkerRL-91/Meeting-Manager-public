import XCTest
@testable import MeetingManager

@MainActor
final class OnboardingManagerTests: XCTestCase {

    private var manager: OnboardingManager!

    override func setUp() {
        super.setUp()
        // Reset UserDefaults state for test isolation
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
        manager = OnboardingManager()
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "onboardingCompleted")
    }

    // MARK: - Initial State

    func testInitialCurrentStepIsWelcome() {
        XCTAssertEqual(manager.currentStep, .welcome)
    }

    // MARK: - Step Navigation

    func testNextStepFromWelcome() {
        manager.currentStep = .welcome
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .permissions)
    }

    func testNextStepFromPermissions() {
        manager.currentStep = .permissions
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .setup)
    }

    func testNextStepFromSetup() {
        manager.currentStep = .setup
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready)
    }

    func testNextStepFromReadyStaysAtReady() {
        manager.currentStep = .ready
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready, "Should not advance past the last step")
    }

    func testPreviousStepFromPermissions() {
        manager.currentStep = .permissions
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome)
    }

    func testPreviousStepFromSetup() {
        manager.currentStep = .setup
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .permissions)
    }

    func testPreviousStepFromReady() {
        manager.currentStep = .ready
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .setup)
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
        XCTAssertEqual(OnboardingManager.OnboardingStep.permissions.rawValue, 1)
        XCTAssertEqual(OnboardingManager.OnboardingStep.setup.rawValue, 2)
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.rawValue, 3)
    }

    func testStepTitles() {
        XCTAssertEqual(OnboardingManager.OnboardingStep.welcome.title, "Welcome")
        XCTAssertEqual(OnboardingManager.OnboardingStep.permissions.title, "Permissions")
        XCTAssertEqual(OnboardingManager.OnboardingStep.setup.title, "Setup")
        XCTAssertEqual(OnboardingManager.OnboardingStep.ready.title, "Ready")
    }

    // MARK: - Full Navigation Cycle

    func testFullForwardNavigationCycle() {
        XCTAssertEqual(manager.currentStep, .welcome)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .permissions)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .setup)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready)
        manager.nextStep()
        XCTAssertEqual(manager.currentStep, .ready) // Stays at ready
    }

    func testFullBackwardNavigationCycle() {
        manager.currentStep = .ready
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .setup)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .permissions)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome)
        manager.previousStep()
        XCTAssertEqual(manager.currentStep, .welcome) // Stays at welcome
    }
}
