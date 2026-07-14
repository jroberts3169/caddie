//
//  TrackmanShotTests.swift
//  caddieTests
//
//  Ported from golf-gen. Verifies the `TrackmanShot` model round-trips real
//  Trackman Measurement JSON.
//

import Foundation
import Testing
@testable import caddie

struct TrackmanShotTests {
    @Test func roundTripsSampleJSON() throws {
        let sample = """
        {
            "Kind": "Measurement",
            "TeePosition": [2.44919166, -0.1762578342, 0.01415258087],
            "PlayerDexterity": "Right",
            "DynamicLie": 1.2004803231952825,
            "ImpactOffset": -0.005427626535984319,
            "ImpactHeight": 0.010240938742791115,
            "AttackAngle": -2.4,
            "LaunchDirection": -0.253,
            "BallSpeed": 57.0697,
            "ClubPath": 2.2,
            "ClubSpeed": 41.28,
            "DynamicLoft": 20.554,
            "FaceAngle": -0.888,
            "FaceToPath": -3.088,
            "LaunchAngle": 16.173,
            "SmashFactor": 1.3825,
            "SpinAxis": -6.309,
            "SpinLoft": 23.354,
            "SpinRate": 5600.0,
            "SwingDirection": 0.944,
            "SwingPlane": 64.413,
            "SwingRadius": 0.962,
            "DPlaneTilt": -7.432,
            "LowPointDistance": 0.046,
            "LowPointHeight": -0.001,
            "LowPointSide": 0.001,
            "MaxHeight": 31.706,
            "Carry": 167.234,
            "Total": 174.832,
            "CarrySide": -11.448,
            "TotalSide": -12.289,
            "LandingAngle": 48.636361,
            "HangTime": 6.505467,
            "LastData": 4.117,
            "Curve": -10.711
        }
        """.data(using: .utf8)!
        let shot = try JSONDecoder().decode(TrackmanShot.self, from: sample)
        #expect(shot.Kind == "Measurement")
        #expect(shot.PlayerDexterity == "Right")
        #expect(shot.Carry == 167.234)
        #expect(shot.TeePosition.count == 3)

        let encoded = try JSONEncoder().encode(shot)
        let round = try JSONDecoder().decode(TrackmanShot.self, from: encoded)
        #expect(round == shot)
    }
}
