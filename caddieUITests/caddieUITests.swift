//
//  caddieUITests.swift
//  caddieUITests
//
//  Created by Jeff Roberts on 7/1/26.
//

import XCTest

final class caddieUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testMainWindowAppears() throws {
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The app should present a main window on launch."
        )
    }

    @MainActor
    func testSearchFieldIsPresent() throws {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(
            search.waitForExistence(timeout: 10),
            "The sidebar should expose a course search field."
        )
    }

    @MainActor
    func testTypingInSearchFieldSurfacesResults() throws {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        search.click()
        search.typeText("Pebble Beach")

        // A network-backed search may take a moment; a matching course row should
        // eventually appear. Result rows carry ids of the form
        // "courseRow_result_<identifier>" (section-scoped so they can't be confused
        // with Favorites or Recents rows).
        let anyCourseRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_result_'")
        ).firstMatch
        XCTAssertTrue(
            anyCourseRow.waitForExistence(timeout: 15),
            "Typing a known course name should surface at least one result row."
        )
    }

    // MARK: - Helpers

    /// Searches for a well-known course, selects the first result row, and waits
    /// for the app to leave the empty state (the mode toggle only exists once a
    /// course is displayed). Returns once `modeToggleButton` is present.
    ///
    /// Network-backed, like the search tests, so it allows generous timeouts.
    @MainActor
    @discardableResult
    private func selectFirstCourse(
        query: String = "Pebble Beach",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 10) else {
            XCTFail("Course search field never appeared.", file: file, line: line)
            return false
        }

        search.click()
        search.typeText(query)

        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_result_'")
        ).firstMatch
        guard firstRow.waitForExistence(timeout: 15) else {
            XCTFail("Searching \"\(query)\" surfaced no course rows.", file: file, line: line)
            return false
        }

        firstRow.click()

        let modeToggle = app.buttons["modeToggleButton"]
        guard modeToggle.waitForExistence(timeout: 15) else {
            XCTFail(
                "Selecting a course should reveal the play/plan mode toggle.",
                file: file, line: line
            )
            return false
        }
        return true
    }

    // MARK: - Mode toggle

    @MainActor
    func testModeToggleShowsAndHidesPlayPane() throws {
        guard selectFirstCourse() else { return }

        let holeTitle = app.staticTexts["holeTitleLabel"]
        XCTAssertFalse(
            holeTitle.exists,
            "The Play detail pane should be hidden while in Plan mode."
        )

        let modeToggle = app.buttons["modeToggleButton"]
        modeToggle.click()
        XCTAssertTrue(
            holeTitle.waitForExistence(timeout: 10),
            "Toggling into Play mode should reveal the hole detail pane."
        )

        modeToggle.click()
        // Wait for the pane to tear down, then confirm it's gone.
        let disappeared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: holeTitle
        )
        wait(for: [disappeared], timeout: 10)
    }

    // MARK: - Hole navigation

    @MainActor
    func testHoleNavigationAdvancesAndClampsAtStart() throws {
        guard selectFirstCourse() else { return }

        app.buttons["modeToggleButton"].click()

        let holeTitle = app.staticTexts["holeTitleLabel"]
        XCTAssertTrue(
            holeTitle.waitForExistence(timeout: 10),
            "Entering Play mode should show the hole title."
        )

        // Holes load asynchronously from OSM; if this course has no parsed hole
        // geometry the title stays "No Holes" and there is nothing to navigate.
        let hasHoles = NSPredicate(format: "label BEGINSWITH 'Hole '")
        let holesReady = expectation(for: hasHoles, evaluatedWith: holeTitle)
        let outcome = XCTWaiter().wait(for: [holesReady], timeout: 15)
        try XCTSkipUnless(
            outcome == .completed,
            "Selected course has no OSM hole geometry; nothing to navigate."
        )

        let prevButton = app.buttons["holePrevButton"]
        let nextButton = app.buttons["holeNextButton"]
        XCTAssertTrue(prevButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))

        // On the first hole, "previous" must be disabled.
        XCTAssertFalse(
            prevButton.isEnabled,
            "The previous-hole button should be disabled on the first hole."
        )

        let firstTitle = holeTitle.label
        guard nextButton.isEnabled else {
            // Single-hole course: nothing further to assert.
            return
        }

        nextButton.click()
        let advanced = expectation(
            for: NSPredicate(format: "label != %@", firstTitle),
            evaluatedWith: holeTitle
        )
        wait(for: [advanced], timeout: 10)
        XCTAssertTrue(
            prevButton.isEnabled,
            "The previous-hole button should be enabled after advancing."
        )

        prevButton.click()
        let returned = expectation(
            for: NSPredicate(format: "label == %@", firstTitle),
            evaluatedWith: holeTitle
        )
        wait(for: [returned], timeout: 10)
    }
}
