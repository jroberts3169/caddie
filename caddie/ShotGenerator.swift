//
//  ShotGenerator.swift
//  caddie
//
//  Back-fits a plausible, internally-consistent Trackman measurement from a
//  start coord, aim bearing, and landing coord. Ported from the golf-gen
//  project. All distances are meters, speeds m/s, angles degrees, spin rpm,
//  time seconds.
//
//  Physics note: this does not simulate drag forward-flight. Instead it samples
//  values from each club's scratch-player distribution, then solves for the
//  start-line + shape that lands the ball at the observed (carry, side).
//  Some consistency identities are strictly enforced:
//    - SmashFactor == BallSpeed / ClubSpeed (clamped to club band)
//    - FaceToPath == FaceAngle - ClubPath
//    - Carry side offset is split between LaunchDirection and Curve
//

import CoreLocation
import Foundation

struct ShotGenerator {
    var profile: PlayerProfile = .scratchRight
    var rng: RandomNumberGeneratorRef

    init(profile: PlayerProfile = .scratchRight, seed: UInt64? = nil) {
        self.profile = profile
        self.rng = RandomNumberGeneratorRef(seed: seed)
    }

    struct Input {
        var start: CLLocationCoordinate2D
        var aimBearing: Double
        var landing: CLLocationCoordinate2D
        var clubHint: Club?
        var startsOnGreen: Bool = false
    }

    struct Output {
        var shot: TrackmanShot
        var club: Club
    }

    /// Back-fit a shot. Returns a consistent `TrackmanShot` + the inferred club.
    mutating func generate(_ input: Input) -> Output {
        let carry_m = max(0.1, Geo.distance(input.start, input.landing))
        let side_m  = Geo.crossTrackDistance(point: input.landing,
                                             origin: input.start,
                                             bearingDeg: input.aimBearing)

        let club = input.clubHint ?? profile.suggestClub(forRemaining: carry_m, onGreen: input.startsOnGreen)
        let s = club.stats

        // Speeds & smash factor — sample then enforce the identity.
        var ballSpeed = sampleNormal(mean: s.ballSpeedMean, std: s.ballSpeedStd)
        let smash     = clamp(sampleNormal(mean: s.smashFactorMean, std: s.smashFactorStd),
                              to: s.smashFactorRange)
        // Scale BallSpeed off measured carry ratio so big taps produce bigger speeds.
        let carryRatio = carry_m / max(1.0, s.meanCarry_m)
        ballSpeed *= sqrt(max(0.25, carryRatio))
        let clubSpeed = ballSpeed / smash

        // Angles from club band.
        let attackAngle  = sampleNormal(mean: s.attackAngleMean, std: s.attackAngleStd)
        let dynamicLoft  = sampleNormal(mean: s.dynamicLoftMean, std: s.dynamicLoftStd)
        let launchAngle  = sampleNormal(mean: s.launchAngleMean, std: s.launchAngleStd)
        let spinRate     = max(0, sampleNormal(mean: s.spinRateMean, std: s.spinRateStd))
        let spinLoft     = sampleNormal(mean: s.spinLoftMean, std: s.spinLoftStd)

        // Start-line + shape back-fit.
        // We want: carry-side offset ≈ LaunchDirection·(carry·tan·deg) + Curve
        // Split: ~40% via start-line, ~60% via curve (feels golf-realistic).
        // Work in degrees -> use side / carry to get a "side angle", then apportion.
        let sideAngleDeg = Geo.toDegrees(atan2(side_m, max(1.0, carry_m)))
        // Start-line noise kept tight (≈0.1°) so a straight-aimed shot
        // doesn't pick up a visible bow from RNG alone.
        var launchDirection = sideAngleDeg * 0.4 + sampleNormal(mean: 0, std: 0.1)
        // Curve is the lateral meters contributed by shape alone:
        // total side = start-line contribution + curve
        var startLineSide_m = tan(Geo.toRadians(launchDirection)) * carry_m
        var curve_m = side_m - startLineSide_m
        // Deadband: if the operator aimed essentially straight, snap to
        // a perfectly straight shot so the renderer doesn't bow the arc
        // off sub-degree start-line jitter.
        if abs(side_m) < 0.5 && abs(curve_m) < 0.5 {
            launchDirection = 0
            startLineSide_m = 0
            curve_m = 0
        }

        // ClubPath, FaceAngle: face-to-path approximately drives SpinAxis & curve.
        // SpinAxis (deg): positive = right-tilt (fade for RH), negative = draw.
        // Heuristic scale: 6° of SpinAxis ≈ ~10m of curve at 150m carry. Back out from curve.
        let spinAxis = clamp(curve_m / max(20.0, carry_m) * 90.0,
                             to: -35.0...35.0) + sampleNormal(mean: 0, std: 1.0)
        // FaceToPath ≈ spinAxis / 2 for a typical dynamic loft (simplified D-plane).
        let faceToPath = clamp(spinAxis * 0.45, to: -6.0...6.0)
        // ClubPath: roughly centered; small random + slight bias matching start-line.
        let clubPath = launchDirection - faceToPath + sampleNormal(mean: 0, std: 0.5)
        let faceAngle = clubPath + faceToPath

        // Other swing fields.
        let swingDirection = clubPath + sampleNormal(mean: 0, std: 0.3)
        let swingPlane = clamp(sampleNormal(mean: 62, std: 4), to: 45.0...80.0)
        let swingRadius = clamp(sampleNormal(mean: 1.0, std: 0.08), to: 0.7...1.2)
        let dPlaneTilt = clamp(-launchDirection * 3 + sampleNormal(mean: 0, std: 1), to: -20.0...20.0)

        // Ballistic-ish derived values.
        let maxHeight = max(0, sampleNormal(mean: s.maxHeightMean, std: s.maxHeightStd)
                               * sqrt(max(0.25, carryRatio)))
        let landingAngle = clamp(sampleNormal(mean: s.landingAngleMean, std: s.landingAngleStd),
                                 to: 5.0...75.0)
        // Rough HangTime from launch vertical speed with a simple 0.85 drag factor.
        let g = 9.81
        let v_y = ballSpeed * sin(Geo.toRadians(launchAngle))
        let hangTime = clamp(2 * v_y / g * 0.95, to: 0.3...9.0)
        let lastData = max(0, hangTime - 0.2)

        // Total distance = carry + rollout. Rollout scales with club and inverse of landing angle.
        let rolloutFactor = s.rolloutFactor * max(0.3, (55 - landingAngle) / 55.0)
        let total = carry_m * (1.0 + rolloutFactor)
        let totalSide = side_m + sampleNormal(mean: 0, std: 0.4)

        // Impact quality fields — narrow realistic bands.
        let dynamicLie   = clamp(sampleNormal(mean: 1.0, std: 0.5), to: -2.0...3.0)
        let impactOffset = sampleNormal(mean: 0, std: 0.005)      // m (heel/toe)
        let impactHeight = sampleNormal(mean: 0.01, std: 0.004)   // m above face center
        let lowPointDistance = sampleNormal(mean: 0.03, std: 0.03)
        let lowPointHeight   = sampleNormal(mean: 0.0, std: 0.004)
        let lowPointSide     = sampleNormal(mean: 0.0, std: 0.005)

        // Tee position — in Trackman local frame, small offsets; realistic for radar setup.
        let teePosition = [
            sampleNormal(mean: 2.4, std: 0.2),
            sampleNormal(mean: -0.15, std: 0.1),
            sampleNormal(mean: 0.014, std: 0.003)
        ]

        let shot = TrackmanShot(
            TeePosition: teePosition,
            PlayerDexterity: profile.dexterity,
            DynamicLie: dynamicLie,
            ImpactOffset: impactOffset,
            ImpactHeight: impactHeight,
            AttackAngle: round3(attackAngle),
            LaunchDirection: round3(launchDirection),
            BallSpeed: round4(ballSpeed),
            ClubPath: round3(clubPath),
            ClubSpeed: round3(clubSpeed),
            DynamicLoft: round3(dynamicLoft),
            FaceAngle: round3(faceAngle),
            FaceToPath: round3(faceAngle - clubPath),
            LaunchAngle: round3(launchAngle),
            SmashFactor: round4(ballSpeed / clubSpeed),
            SpinAxis: round3(spinAxis),
            SpinLoft: round3(spinLoft),
            SpinRate: round(spinRate),
            SwingDirection: round3(swingDirection),
            SwingPlane: round3(swingPlane),
            SwingRadius: round3(swingRadius),
            DPlaneTilt: round3(dPlaneTilt),
            LowPointDistance: round3(lowPointDistance),
            LowPointHeight: round3(lowPointHeight),
            LowPointSide: round3(lowPointSide),
            MaxHeight: round3(maxHeight),
            Carry: round3(carry_m),
            Total: round3(total),
            CarrySide: round3(side_m),
            TotalSide: round3(totalSide),
            LandingAngle: round6(landingAngle),
            HangTime: round6(hangTime),
            LastData: round3(lastData),
            Curve: round3(curve_m)
        )

        return Output(shot: shot, club: club)
    }

    // MARK: - sampling helpers

    private mutating func sampleNormal(mean: Double, std: Double) -> Double {
        guard std > 0 else { return mean }
        // Box–Muller
        let u1 = max(Double.ulpOfOne, rng.next01())
        let u2 = rng.next01()
        let z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + z0 * std
    }

    private func clamp<T: Comparable>(_ x: T, to range: ClosedRange<T>) -> T {
        min(max(x, range.lowerBound), range.upperBound)
    }

    private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
    private func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
    private func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
    private func round(_ x: Double) -> Double { x.rounded() }
}

/// Wrapper so we can hold an RNG as a struct value. Uses SystemRandomNumberGenerator by default,
/// or a deterministic seeded PRNG when a seed is provided (for reproducible arcs and tests).
struct RandomNumberGeneratorRef {
    private var seeded: SplitMix64?

    init(seed: UInt64?) {
        if let seed { self.seeded = SplitMix64(seed: seed) }
    }

    /// Uniform in (0, 1).
    mutating func next01() -> Double {
        if var s = seeded {
            let v = s.next()
            seeded = s
            return Double(v >> 11) * (1.0 / 9007199254740992.0)
        } else {
            var g = SystemRandomNumberGenerator()
            let v = UInt64.random(in: 0...UInt64.max, using: &g)
            return Double(v >> 11) * (1.0 / 9007199254740992.0)
        }
    }
}

/// SplitMix64 PRNG for deterministic seeded generation.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
