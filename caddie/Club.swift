//
//  Club.swift
//  caddie
//
//  Golf club taxonomy, per-club scratch-player statistical distributions, the
//  playing-surface enum, and the player profile that suggests a club from a
//  remaining distance. Ported from the golf-gen project.
//

import Foundation

/// Playing surface the ball rests on. Only `green` currently changes behaviour
/// (it forces the putter in club suggestion); the rest are recorded for future
/// lie-aware logic.
nonisolated enum Surface: String, Codable, CaseIterable {
    case tee
    case fairway
    case rough
    case bunker
    case green
    case water
    case trees
    case offCourse
}

enum Club: String, CaseIterable, Codable, Identifiable {
    case driver = "Driver"
    case threeWood = "3W"
    case fiveWood = "5W"
    case hybrid = "Hybrid"
    case iron4 = "4i"
    case iron5 = "5i"
    case iron6 = "6i"
    case iron7 = "7i"
    case iron8 = "8i"
    case iron9 = "9i"
    case pitchingWedge = "PW"
    case gapWedge = "50"
    case sandWedge = "54"
    case lobWedge = "58"
    case putter = "Putter"

    var id: String { rawValue }
}

/// Mean + stdev of plausible values for a scratch RH player, metric units.
struct ClubStats {
    var meanCarry_m: Double
    var carryStd_m: Double
    var sideStd_m: Double            // dispersion at target (lateral)

    var ballSpeedMean: Double        // m/s
    var ballSpeedStd: Double
    var smashFactorMean: Double
    var smashFactorStd: Double       // clamped to valid band

    var launchAngleMean: Double      // deg
    var launchAngleStd: Double
    var spinRateMean: Double         // rpm
    var spinRateStd: Double
    var attackAngleMean: Double      // deg (positive = up, negative = down)
    var attackAngleStd: Double
    var dynamicLoftMean: Double      // deg
    var dynamicLoftStd: Double
    var spinLoftMean: Double         // deg
    var spinLoftStd: Double

    var landingAngleMean: Double     // deg
    var landingAngleStd: Double
    var maxHeightMean: Double        // m
    var maxHeightStd: Double

    /// Typical rollout factor applied to Carry (Total = Carry * (1 + rolloutFactor)).
    var rolloutFactor: Double

    /// Smash factor hard clamp.
    var smashFactorRange: ClosedRange<Double>
}

extension Club {
    /// Scratch RH player distributions. Seeded off a sample driver shot and common tour-ish averages.
    var stats: ClubStats {
        switch self {
        case .driver:
            return ClubStats(
                meanCarry_m: 240, carryStd_m: 8, sideStd_m: 10,
                ballSpeedMean: 74, ballSpeedStd: 1.5,
                smashFactorMean: 1.48, smashFactorStd: 0.01,
                launchAngleMean: 13.5, launchAngleStd: 1.2,
                spinRateMean: 2500, spinRateStd: 250,
                attackAngleMean: 2.0, attackAngleStd: 1.0,
                dynamicLoftMean: 14.0, dynamicLoftStd: 1.0,
                spinLoftMean: 12.0, spinLoftStd: 1.0,
                landingAngleMean: 38, landingAngleStd: 3,
                maxHeightMean: 32, maxHeightStd: 3,
                rolloutFactor: 0.08,
                smashFactorRange: 1.42...1.51
            )
        case .threeWood:
            return ClubStats(
                meanCarry_m: 220, carryStd_m: 8, sideStd_m: 9,
                ballSpeedMean: 70, ballSpeedStd: 1.4,
                smashFactorMean: 1.47, smashFactorStd: 0.01,
                launchAngleMean: 12.5, launchAngleStd: 1.2,
                spinRateMean: 3200, spinRateStd: 300,
                attackAngleMean: -1.0, attackAngleStd: 1.0,
                dynamicLoftMean: 14.5, dynamicLoftStd: 1.0,
                spinLoftMean: 15.5, spinLoftStd: 1.0,
                landingAngleMean: 42, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.06,
                smashFactorRange: 1.40...1.50
            )
        case .fiveWood:
            return ClubStats(
                meanCarry_m: 205, carryStd_m: 7, sideStd_m: 9,
                ballSpeedMean: 66, ballSpeedStd: 1.3,
                smashFactorMean: 1.46, smashFactorStd: 0.01,
                launchAngleMean: 13.5, launchAngleStd: 1.2,
                spinRateMean: 3700, spinRateStd: 300,
                attackAngleMean: -2.0, attackAngleStd: 1.0,
                dynamicLoftMean: 15.5, dynamicLoftStd: 1.0,
                spinLoftMean: 17.5, spinLoftStd: 1.0,
                landingAngleMean: 44, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.05,
                smashFactorRange: 1.38...1.49
            )
        case .hybrid:
            return ClubStats(
                meanCarry_m: 195, carryStd_m: 7, sideStd_m: 8,
                ballSpeedMean: 63, ballSpeedStd: 1.2,
                smashFactorMean: 1.45, smashFactorStd: 0.01,
                launchAngleMean: 14.5, launchAngleStd: 1.2,
                spinRateMean: 4300, spinRateStd: 300,
                attackAngleMean: -2.5, attackAngleStd: 1.0,
                dynamicLoftMean: 17, dynamicLoftStd: 1.0,
                spinLoftMean: 19.5, spinLoftStd: 1.0,
                landingAngleMean: 46, landingAngleStd: 3,
                maxHeightMean: 29, maxHeightStd: 3,
                rolloutFactor: 0.04,
                smashFactorRange: 1.36...1.48
            )
        case .iron4:
            return ClubStats(
                meanCarry_m: 185, carryStd_m: 6, sideStd_m: 7,
                ballSpeedMean: 60, ballSpeedStd: 1.2,
                smashFactorMean: 1.42, smashFactorStd: 0.01,
                launchAngleMean: 14, launchAngleStd: 1.0,
                spinRateMean: 4800, spinRateStd: 300,
                attackAngleMean: -3.5, attackAngleStd: 1.0,
                dynamicLoftMean: 18, dynamicLoftStd: 1.0,
                spinLoftMean: 21.5, spinLoftStd: 1.0,
                landingAngleMean: 47, landingAngleStd: 3,
                maxHeightMean: 28, maxHeightStd: 3,
                rolloutFactor: 0.04,
                smashFactorRange: 1.34...1.46
            )
        case .iron5:
            return ClubStats(
                meanCarry_m: 175, carryStd_m: 6, sideStd_m: 6,
                ballSpeedMean: 57.5, ballSpeedStd: 1.1,
                smashFactorMean: 1.40, smashFactorStd: 0.01,
                launchAngleMean: 15, launchAngleStd: 1.0,
                spinRateMean: 5300, spinRateStd: 300,
                attackAngleMean: -3.8, attackAngleStd: 1.0,
                dynamicLoftMean: 20, dynamicLoftStd: 1.0,
                spinLoftMean: 23.8, spinLoftStd: 1.0,
                landingAngleMean: 48, landingAngleStd: 3,
                maxHeightMean: 28, maxHeightStd: 3,
                rolloutFactor: 0.03,
                smashFactorRange: 1.32...1.44
            )
        case .iron6:
            return ClubStats(
                meanCarry_m: 165, carryStd_m: 5, sideStd_m: 6,
                ballSpeedMean: 55, ballSpeedStd: 1.0,
                smashFactorMean: 1.38, smashFactorStd: 0.01,
                launchAngleMean: 16, launchAngleStd: 1.0,
                spinRateMean: 5800, spinRateStd: 300,
                attackAngleMean: -4.0, attackAngleStd: 1.0,
                dynamicLoftMean: 22, dynamicLoftStd: 1.0,
                spinLoftMean: 26, spinLoftStd: 1.0,
                landingAngleMean: 49, landingAngleStd: 3,
                maxHeightMean: 29, maxHeightStd: 3,
                rolloutFactor: 0.03,
                smashFactorRange: 1.30...1.42
            )
        case .iron7:
            return ClubStats(
                meanCarry_m: 155, carryStd_m: 5, sideStd_m: 5,
                ballSpeedMean: 52, ballSpeedStd: 1.0,
                smashFactorMean: 1.36, smashFactorStd: 0.01,
                launchAngleMean: 17, launchAngleStd: 1.0,
                spinRateMean: 6500, spinRateStd: 300,
                attackAngleMean: -4.2, attackAngleStd: 1.0,
                dynamicLoftMean: 24.5, dynamicLoftStd: 1.0,
                spinLoftMean: 28.7, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.02,
                smashFactorRange: 1.28...1.40
            )
        case .iron8:
            return ClubStats(
                meanCarry_m: 145, carryStd_m: 4, sideStd_m: 5,
                ballSpeedMean: 49, ballSpeedStd: 1.0,
                smashFactorMean: 1.33, smashFactorStd: 0.01,
                launchAngleMean: 19, launchAngleStd: 1.0,
                spinRateMean: 7300, spinRateStd: 300,
                attackAngleMean: -4.4, attackAngleStd: 1.0,
                dynamicLoftMean: 27, dynamicLoftStd: 1.0,
                spinLoftMean: 31.4, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.02,
                smashFactorRange: 1.26...1.37
            )
        case .iron9:
            return ClubStats(
                meanCarry_m: 135, carryStd_m: 4, sideStd_m: 4,
                ballSpeedMean: 45, ballSpeedStd: 1.0,
                smashFactorMean: 1.30, smashFactorStd: 0.01,
                launchAngleMean: 22, launchAngleStd: 1.0,
                spinRateMean: 8200, spinRateStd: 350,
                attackAngleMean: -4.6, attackAngleStd: 1.0,
                dynamicLoftMean: 30, dynamicLoftStd: 1.0,
                spinLoftMean: 34.6, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.015,
                smashFactorRange: 1.24...1.34
            )
        case .pitchingWedge:
            return ClubStats(
                meanCarry_m: 125, carryStd_m: 4, sideStd_m: 4,
                ballSpeedMean: 42, ballSpeedStd: 1.0,
                smashFactorMean: 1.27, smashFactorStd: 0.01,
                launchAngleMean: 24, launchAngleStd: 1.0,
                spinRateMean: 9100, spinRateStd: 400,
                attackAngleMean: -5.0, attackAngleStd: 1.0,
                dynamicLoftMean: 34, dynamicLoftStd: 1.0,
                spinLoftMean: 39, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 30, maxHeightStd: 3,
                rolloutFactor: 0.01,
                smashFactorRange: 1.20...1.31
            )
        case .gapWedge:
            return ClubStats(
                meanCarry_m: 105, carryStd_m: 4, sideStd_m: 4,
                ballSpeedMean: 37, ballSpeedStd: 1.0,
                smashFactorMean: 1.20, smashFactorStd: 0.01,
                launchAngleMean: 27, launchAngleStd: 1.0,
                spinRateMean: 9700, spinRateStd: 400,
                attackAngleMean: -5.5, attackAngleStd: 1.0,
                dynamicLoftMean: 40, dynamicLoftStd: 1.0,
                spinLoftMean: 45.5, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 28, maxHeightStd: 3,
                rolloutFactor: 0.01,
                smashFactorRange: 1.15...1.25
            )
        case .sandWedge:
            return ClubStats(
                meanCarry_m: 90, carryStd_m: 4, sideStd_m: 4,
                ballSpeedMean: 33, ballSpeedStd: 1.0,
                smashFactorMean: 1.15, smashFactorStd: 0.01,
                launchAngleMean: 30, launchAngleStd: 1.0,
                spinRateMean: 10200, spinRateStd: 400,
                attackAngleMean: -6.0, attackAngleStd: 1.0,
                dynamicLoftMean: 44, dynamicLoftStd: 1.0,
                spinLoftMean: 50, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 25, maxHeightStd: 3,
                rolloutFactor: 0.005,
                smashFactorRange: 1.10...1.20
            )
        case .lobWedge:
            return ClubStats(
                meanCarry_m: 75, carryStd_m: 4, sideStd_m: 4,
                ballSpeedMean: 28, ballSpeedStd: 1.0,
                smashFactorMean: 1.10, smashFactorStd: 0.01,
                launchAngleMean: 34, launchAngleStd: 1.0,
                spinRateMean: 10500, spinRateStd: 400,
                attackAngleMean: -6.5, attackAngleStd: 1.0,
                dynamicLoftMean: 48, dynamicLoftStd: 1.0,
                spinLoftMean: 54.5, spinLoftStd: 1.0,
                landingAngleMean: 50, landingAngleStd: 3,
                maxHeightMean: 22, maxHeightStd: 3,
                rolloutFactor: 0.005,
                smashFactorRange: 1.05...1.15
            )
        case .putter:
            return ClubStats(
                meanCarry_m: 8, carryStd_m: 3, sideStd_m: 1,
                ballSpeedMean: 4.0, ballSpeedStd: 1.0,
                smashFactorMean: 1.00, smashFactorStd: 0.0,
                launchAngleMean: 1.5, launchAngleStd: 0.5,
                spinRateMean: 60, spinRateStd: 30,
                attackAngleMean: 0.5, attackAngleStd: 0.5,
                dynamicLoftMean: 2.5, dynamicLoftStd: 0.5,
                spinLoftMean: 2, spinLoftStd: 0.5,
                landingAngleMean: 2, landingAngleStd: 1,
                maxHeightMean: 0.05, maxHeightStd: 0.02,
                rolloutFactor: 0.0,
                smashFactorRange: 0.95...1.05
            )
        }
    }
}

/// A player's handedness + name, plus club-selection logic. The app ships a
/// single scratch right-handed profile; the auto-suggested club drives shot
/// generation until a club picker exists.
struct PlayerProfile {
    var dexterity: String                        // "Right" | "Left"
    var name: String

    static let scratchRight = PlayerProfile(dexterity: "Right", name: "Scratch (RH)")

    /// Preferred club for a given remaining distance (meters) and surface.
    /// Off-green: pick club whose meanCarry is closest. On-green: putter.
    func suggestClub(forRemaining meters: Double, onGreen: Bool) -> Club {
        if onGreen { return .putter }
        return Club.allCases
            .filter { $0 != .putter }
            .min(by: { abs($0.stats.meanCarry_m - meters) < abs($1.stats.meanCarry_m - meters) })
            ?? .iron7
    }
}
