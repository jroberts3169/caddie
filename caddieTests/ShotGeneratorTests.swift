//
//  ShotGeneratorTests.swift
//  caddieTests
//
//  Ported from golf-gen. Verifies the back-fit shot generator holds its physics
//  identities and picks sensible clubs.
//

import CoreLocation
import Foundation
import Testing
@testable import caddie

struct ShotGeneratorTests {
    @Test func invariantsHold() {
        var gen = ShotGenerator(profile: .scratchRight, seed: 42)
        let start = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3)
        let landing = Geo.destination(from: start, bearingDeg: 10, distance_m: 230)
        let out = gen.generate(.init(start: start, aimBearing: 0, landing: landing))

        let s = out.shot
        // Smash factor identity (within rounding tolerance).
        let smash = s.BallSpeed / s.ClubSpeed
        #expect(abs(smash - s.SmashFactor) < 0.01)

        // FaceToPath identity.
        #expect(abs((s.FaceAngle - s.ClubPath) - s.FaceToPath) < 0.01)

        // Carry is roughly the requested carry.
        #expect(abs(s.Carry - 230) < 1.0)

        // Total >= Carry.
        #expect(s.Total >= s.Carry - 0.001)

        // Smash factor inside club band.
        let band = out.club.stats.smashFactorRange
        #expect(smash >= band.lowerBound - 0.05 && smash <= band.upperBound + 0.05)
    }

    @Test func shortDistancePicksShortClub() {
        var gen = ShotGenerator(profile: .scratchRight, seed: 1)
        let start = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3)
        let landing = Geo.destination(from: start, bearingDeg: 0, distance_m: 70)
        let out = gen.generate(.init(start: start, aimBearing: 0, landing: landing))
        // Should pick a wedge-ish club.
        #expect([Club.sandWedge, .lobWedge, .gapWedge].contains(out.club))
    }

    @Test func longDistancePicksDriver() {
        var gen = ShotGenerator(profile: .scratchRight, seed: 1)
        let start = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3)
        let landing = Geo.destination(from: start, bearingDeg: 0, distance_m: 245)
        let out = gen.generate(.init(start: start, aimBearing: 0, landing: landing))
        #expect(out.club == .driver)
    }

    @Test func sideOffsetDirection() {
        var gen = ShotGenerator(profile: .scratchRight, seed: 7)
        let start = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3)
        // Aim due north; land north-east → right side (positive CarrySide expected).
        let landing = Geo.destination(from: start, bearingDeg: 5, distance_m: 200)
        let out = gen.generate(.init(start: start, aimBearing: 0, landing: landing))
        #expect(out.shot.CarrySide > 0)
    }

    @Test func seededGenerationIsDeterministic() {
        let start = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.3)
        let landing = Geo.destination(from: start, bearingDeg: 3, distance_m: 180)
        var a = ShotGenerator(seed: 99)
        var b = ShotGenerator(seed: 99)
        let outA = a.generate(.init(start: start, aimBearing: 0, landing: landing))
        let outB = b.generate(.init(start: start, aimBearing: 0, landing: landing))
        #expect(outA.shot == outB.shot)
        #expect(outA.club == outB.club)
    }
}
