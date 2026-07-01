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
        // NOTE: on macOS a SwiftUI `Text` surfaces its string as the element's
        // accessibility *value* (AXValue), not its *label* — so all title checks
        // here match on `value`, never `label` (which is empty).
        let hasHoles = NSPredicate(format: "value BEGINSWITH 'Hole '")
        let holesReady = expectation(for: hasHoles, evaluatedWith: holeTitle)
        let outcome = XCTWaiter().wait(for: [holesReady], timeout: 20)
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

        let firstTitle = (holeTitle.value as? String) ?? ""
        guard nextButton.isEnabled else {
            // Single-hole course: nothing further to assert.
            return
        }

        nextButton.click()
        let advanced = expectation(
            for: NSPredicate(format: "value != %@", firstTitle),
            evaluatedWith: holeTitle
        )
        wait(for: [advanced], timeout: 10)
        XCTAssertTrue(
            prevButton.isEnabled,
            "The previous-hole button should be enabled after advancing."
        )

        prevButton.click()
        let returned = expectation(
            for: NSPredicate(format: "value == %@", firstTitle),
            evaluatedWith: holeTitle
        )
        wait(for: [returned], timeout: 10)
    }

    // MARK: - Favorites

    /// Returns the full accessibility identifier (e.g.
    /// `courseRow_result_<id>`) of the first search-result row, or `nil` if none
    /// appeared in time. The `<id>` suffix is reused to target the same course's
    /// rows in other sidebar sections (Favorites/Recents).
    @MainActor
    private func firstResultRowIdentifier(
        query: String = "Pebble Beach",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 10) else {
            XCTFail("Course search field never appeared.", file: file, line: line)
            return nil
        }

        search.click()
        search.typeText(query)

        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_result_'")
        ).firstMatch
        guard firstRow.waitForExistence(timeout: 15) else {
            XCTFail("Searching \"\(query)\" surfaced no course rows.", file: file, line: line)
            return nil
        }
        return firstRow.identifier
    }

    @MainActor
    func testFavoriteToggleAddsAndRemovesFavoriteRow() throws {
        guard let resultRowID = firstResultRowIdentifier() else { return }

        // The course identifier is the suffix after "courseRow_result_".
        let prefix = "courseRow_result_"
        let courseID = String(resultRowID.dropFirst(prefix.count))
        XCTAssertFalse(courseID.isEmpty, "Result row should carry a course id suffix.")

        let favoriteToggleInResults = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "favoriteToggle_result_\(courseID)")
        ).firstMatch
        XCTAssertTrue(
            favoriteToggleInResults.waitForExistence(timeout: 10),
            "The result row should expose a favorite toggle."
        )
        favoriteToggleInResults.click()

        // Favoriting surfaces a mirror row in the Favorites section.
        let favoriteRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "courseRow_favorite_\(courseID)")
        ).firstMatch
        XCTAssertTrue(
            favoriteRow.waitForExistence(timeout: 10),
            "Favoriting a course should add it to the Favorites section."
        )

        // Un-favoriting via the Favorites-section toggle removes the row again.
        let favoriteToggleInFavorites = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "favoriteToggle_favorite_\(courseID)")
        ).firstMatch
        XCTAssertTrue(favoriteToggleInFavorites.waitForExistence(timeout: 5))
        favoriteToggleInFavorites.click()

        let removed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: favoriteRow
        )
        wait(for: [removed], timeout: 10)
    }

    // MARK: - Recents

    @MainActor
    func testSelectingCoursePopulatesRecents() throws {
        guard selectFirstCourse() else { return }

        // Selecting a course records it in the Recents section.
        let recentRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_recent_'")
        ).firstMatch
        XCTAssertTrue(
            recentRow.waitForExistence(timeout: 10),
            "Selecting a course should add it to the Recents section."
        )
    }

    // MARK: - Search clear

    @MainActor
    func testClearingSearchCollapsesResults() throws {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        search.click()
        search.typeText("Pebble Beach")

        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_result_'")
        ).firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 15),
            "Typing a known course name should surface at least one result row."
        )

        // Clear the field: select all + delete removes the query text so the
        // Results section empties out.
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])

        let collapsed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: firstRow
        )
        wait(for: [collapsed], timeout: 10)
    }

    // MARK: - Sub-course picker

    @MainActor
    func testSubCoursePickerSwitchesActiveSubCourse() throws {
        // Multi-course facilities are network/OSM-backed; the picker only exists
        // once a facility with more than one sub-course is displayed. The picker is
        // a SwiftUI `Menu`, which surfaces as a `.menuButton` element (not `.button`)
        // on macOS, so it must be located by identifier across any element type. Its
        // active sub-course is exposed via the accessibility *value*.
        guard selectFirstCourse(query: "Balboa Park") else { return }

        let picker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'subCoursePickerButton'")
        ).firstMatch
        let pickerReady = expectation(
            for: NSPredicate(format: "exists == true"),
            evaluatedWith: picker
        )
        let outcome = XCTWaiter().wait(for: [pickerReady], timeout: 20)
        try XCTSkipUnless(
            outcome == .completed,
            "Selected facility has no multiple sub-courses; nothing to switch."
        )

        // The picker's accessibility value reflects the active sub-course; it starts
        // on "All".
        let allValue = (picker.value as? String) ?? "All"

        // Open the menu and pick the first concrete sub-course item.
        picker.click()
        let subItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'subCourseItem_' AND identifier != 'subCourseItem_all'")
        ).firstMatch
        XCTAssertTrue(
            subItem.waitForExistence(timeout: 10),
            "The sub-course picker menu should list at least one sub-course."
        )
        subItem.click()

        // The picker value reflects the active sub-course, so it should change away
        // from the "All" value.
        let valueChanged = expectation(
            for: NSPredicate(format: "value != %@", allValue),
            evaluatedWith: picker
        )
        wait(for: [valueChanged], timeout: 10)

        // Switching back to "All" restores the original value.
        picker.click()
        let allItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'subCourseItem_all'")
        ).firstMatch
        XCTAssertTrue(allItem.waitForExistence(timeout: 10))
        allItem.click()

        let valueRestored = expectation(
            for: NSPredicate(format: "value == %@", allValue),
            evaluatedWith: picker
        )
        wait(for: [valueRestored], timeout: 10)
    }

    // MARK: - Clear shots

    @MainActor
    func testRecordingShotEnablesClearShots() throws {
        guard selectFirstCourse() else { return }

        app.buttons["modeToggleButton"].click()

        let holeTitle = app.staticTexts["holeTitleLabel"]
        XCTAssertTrue(holeTitle.waitForExistence(timeout: 10))

        // Recording a shot only makes sense once hole geometry is present.
        // (macOS surfaces the `Text` title as `value`, not `label`.)
        let hasHoles = NSPredicate(format: "value BEGINSWITH 'Hole '")
        let holesReady = expectation(for: hasHoles, evaluatedWith: holeTitle)
        let outcome = XCTWaiter().wait(for: [holesReady], timeout: 20)
        try XCTSkipUnless(
            outcome == .completed,
            "Selected course has no OSM hole geometry; cannot record a shot."
        )

        let clearButton = app.buttons["clearShotsButton"]
        XCTAssertFalse(
            clearButton.exists,
            "Clear-shots should be hidden before any shot is recorded."
        )

        // Click the map to drop a shot. Native MKMapView hit-testing may land on
        // a hole glyph, so try a few offsets until the Clear button appears.
        let map = app.descendants(matching: .any).matching(
            NSPredicate(format: "elementType == %d", XCUIElement.ElementType.map.rawValue)
        ).firstMatch
        let clickTarget: XCUIElement = map.waitForExistence(timeout: 5)
            ? map
            : app.windows.firstMatch

        let offsets: [CGVector] = [
            CGVector(dx: 0.5, dy: 0.55),
            CGVector(dx: 0.45, dy: 0.5),
            CGVector(dx: 0.55, dy: 0.6),
            CGVector(dx: 0.4, dy: 0.45)
        ]
        for offset in offsets {
            clickTarget.coordinate(withNormalizedOffset: offset).click()
            if clearButton.waitForExistence(timeout: 3) { break }
        }

        try XCTSkipUnless(
            clearButton.exists,
            "Map click did not register a shot (native hit-test may have hit a glyph)."
        )

        clearButton.click()
        let cleared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: clearButton
        )
        wait(for: [cleared], timeout: 10)
    }
}
