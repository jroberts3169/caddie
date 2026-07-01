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
        // eventually appear. Rows carry ids of the form "courseRow_<identifier>".
        let anyCourseRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'courseRow_'")
        ).firstMatch
        XCTAssertTrue(
            anyCourseRow.waitForExistence(timeout: 15),
            "Typing a known course name should surface at least one result row."
        )
    }
}
