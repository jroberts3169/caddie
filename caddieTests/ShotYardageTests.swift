//
//  ShotYardageTests.swift
//  caddieTests
//

import CoreLocation
import Testing
@testable import caddie

struct ShotYardageTests {

    // ~0.001° of latitude ≈ 111 m near the equator; convenient for round numbers.
    private let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    @Test func emptyShotsYieldEmptyResult() {
        let result = ShotYardage.yards(tee: origin, shots: [])
        #expect(result.isEmpty)
    }

    @Test func firstShotWithoutTeeIsNil() {
        let shot = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
        let result = ShotYardage.yards(tee: nil, shots: [shot])
        #expect(result.count == 1)
        #expect(result[0] == nil)
    }

    @Test func firstShotMeasuredFromTee() {
        let tee = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let shot = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
        let result = ShotYardage.yards(tee: tee, shots: [shot])

        // ~111.3 m of latitude → ~121.7 yd. Assert against the same formula the
        // production code uses so the test tracks any deliberate factor change.
        let meters = CLLocation(latitude: tee.latitude, longitude: tee.longitude)
            .distance(from: CLLocation(latitude: shot.latitude, longitude: shot.longitude))
        let expected = Int((meters * ShotYardage.yardsPerMeter).rounded())
        #expect(result[0] == expected)
        #expect(result[0]! > 100 && result[0]! < 150)
    }

    @Test func laterShotsMeasuredFromPreviousShot() {
        let tee = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let shot1 = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
        let shot2 = CLLocationCoordinate2D(latitude: 0.002, longitude: 0)
        let result = ShotYardage.yards(tee: tee, shots: [shot1, shot2])

        #expect(result.count == 2)
        // Equal-length legs (tee→shot1 and shot1→shot2) should be equal yardage.
        #expect(result[0] == result[1])
    }

    @Test func withoutTeeOnlyFirstShotIsNil() {
        let shot1 = CLLocationCoordinate2D(latitude: 0.001, longitude: 0)
        let shot2 = CLLocationCoordinate2D(latitude: 0.002, longitude: 0)
        let result = ShotYardage.yards(tee: nil, shots: [shot1, shot2])

        #expect(result.count == 2)
        #expect(result[0] == nil)          // no reference for shot 1
        #expect(result[1] != nil)          // shot 2 measured from shot 1
    }

    @Test func zeroDistanceShotIsZeroYards() {
        let tee = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let shot = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let result = ShotYardage.yards(tee: tee, shots: [shot])
        #expect(result[0] == 0)
    }
}
