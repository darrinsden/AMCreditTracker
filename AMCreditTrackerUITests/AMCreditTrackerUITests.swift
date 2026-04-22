//
//  AMCreditTrackerUITests.swift
//  AMCreditTrackerUITests
//
//  Created by Darrin horn on 4/18/26.
//

import XCTest

final class AMCreditTrackerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Launch-time smoke test: the app reaches one of its known top-level
    // screens without crashing. The exact screen depends on whether a
    // roster is already cached and whether an AM is selected — all three
    // states are acceptable here; we're just pinning launch behavior.
    @MainActor
    func testAppReachesKnownTopLevelScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let loadingTitle = app.staticTexts["AM Credit Tracker"]
        let amPickerTitle = app.navigationBars["Who's using this device?"]
        let scanTab = app.tabBars.buttons["Scan"]

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(block: { _, _ in
                loadingTitle.exists || amPickerTitle.exists || scanTab.exists
            }),
            object: nil
        )
        wait(for: [expectation], timeout: 10)
    }

    // If the app is already past onboarding, the Scan / History / Settings
    // tabs should be present. This is a soft check — skipped on first-run
    // simulators that haven't synced a roster yet.
    @MainActor
    func testTabBarHasExpectedTabsIfPastOnboarding() throws {
        let app = XCUIApplication()
        app.launch()

        let scanTab = app.tabBars.buttons["Scan"]
        guard scanTab.waitForExistence(timeout: 5) else {
            throw XCTSkip("App is on onboarding — tab bar not present.")
        }

        XCTAssertTrue(app.tabBars.buttons["History"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
