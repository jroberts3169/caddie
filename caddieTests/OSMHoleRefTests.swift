//
//  OSMHoleRefTests.swift
//  caddieTests
//

import Testing
@testable import caddie

struct OSMHoleRefTests {

    @Test func plainNumberHasNoCourseName() {
        let parsed = OSMHole.parseRef("7")
        #expect(parsed.number == 7)
        #expect(parsed.courseName == nil)
    }

    @Test func parenthesizedCourseName() {
        let parsed = OSMHole.parseRef("1 (Canyon Course)")
        #expect(parsed.number == 1)
        #expect(parsed.courseName == "Canyon Course")
    }

    @Test func bareCourseName() {
        let parsed = OSMHole.parseRef("3 Vineyard Course")
        #expect(parsed.number == 3)
        #expect(parsed.courseName == "Vineyard Course")
    }

    @Test func multiDigitNumber() {
        let parsed = OSMHole.parseRef("18 Ranch Course")
        #expect(parsed.number == 18)
        #expect(parsed.courseName == "Ranch Course")
    }

    @Test func missingRefIsEmpty() {
        let parsed = OSMHole.parseRef(nil)
        #expect(parsed.number == nil)
        #expect(parsed.courseName == nil)
    }

    @Test func nonNumericRefKeepsNoNumber() {
        let parsed = OSMHole.parseRef("Practice")
        #expect(parsed.number == nil)
        #expect(parsed.courseName == "Practice")
    }

    @Test func displayGlyphPrefersParsedNumber() {
        let hole = OSMHole(
            osmIdentifier: 1,
            ref: "1 (Canyon Course)",
            par: 4,
            lengthMeters: nil,
            coordinates: [],
            tags: [:]
        )
        #expect(hole.displayGlyph == "1")
        #expect(hole.holeNumber == 1)
        #expect(hole.refCourseName == "Canyon Course")
    }

    @Test func displayGlyphFallsBackToRawRef() {
        let hole = OSMHole(
            osmIdentifier: 2,
            ref: "Practice",
            par: 3,
            lengthMeters: nil,
            coordinates: [],
            tags: [:]
        )
        #expect(hole.displayGlyph == "Practice")
    }
}
