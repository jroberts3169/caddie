//
//  TrackmanShot.swift
//  caddie
//
//  Trackman Measurement record ported from the golf-gen project. All units metric:
//    distances: meters
//    speeds:    m/s
//    angles:    degrees
//    spin:      rpm
//    time:      seconds
//
//  This is the physics-backed shot model that replaces caddie's earlier
//  coordinate-only `Shot`. The two fields the on-map arc renderer consumes are
//  `MaxHeight` (apex, metres) and `Curve` (lateral shape, metres).
//

import Foundation

nonisolated struct TrackmanShot: Codable, Equatable, Hashable {
    var Kind: String = "Measurement"
    var TeePosition: [Double]            // [x, y, z] meters, radar-local frame
    var PlayerDexterity: String          // "Right" | "Left"

    var DynamicLie: Double
    var ImpactOffset: Double
    var ImpactHeight: Double
    var AttackAngle: Double
    var LaunchDirection: Double
    var BallSpeed: Double
    var ClubPath: Double
    var ClubSpeed: Double
    var DynamicLoft: Double
    var FaceAngle: Double
    var FaceToPath: Double
    var LaunchAngle: Double
    var SmashFactor: Double
    var SpinAxis: Double
    var SpinLoft: Double
    var SpinRate: Double
    var SwingDirection: Double
    var SwingPlane: Double
    var SwingRadius: Double
    var DPlaneTilt: Double
    var LowPointDistance: Double
    var LowPointHeight: Double
    var LowPointSide: Double
    var MaxHeight: Double
    var Carry: Double
    var Total: Double
    var CarrySide: Double
    var TotalSide: Double
    var LandingAngle: Double
    var HangTime: Double
    var LastData: Double
    var Curve: Double

    /// An all-zero placeholder measurement. Used by the lightweight
    /// `Shot(coordinate:)` convenience initializer (tests, previews) where no
    /// generated physics is needed — the arc renderer simply draws a flat line
    /// for a zero-apex shot.
    static let zero = TrackmanShot(
        TeePosition: [0, 0, 0],
        PlayerDexterity: "Right",
        DynamicLie: 0, ImpactOffset: 0, ImpactHeight: 0, AttackAngle: 0,
        LaunchDirection: 0, BallSpeed: 0, ClubPath: 0, ClubSpeed: 0,
        DynamicLoft: 0, FaceAngle: 0, FaceToPath: 0, LaunchAngle: 0,
        SmashFactor: 0, SpinAxis: 0, SpinLoft: 0, SpinRate: 0,
        SwingDirection: 0, SwingPlane: 0, SwingRadius: 0, DPlaneTilt: 0,
        LowPointDistance: 0, LowPointHeight: 0, LowPointSide: 0, MaxHeight: 0,
        Carry: 0, Total: 0, CarrySide: 0, TotalSide: 0, LandingAngle: 0,
        HangTime: 0, LastData: 0, Curve: 0
    )
}
