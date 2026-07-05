//
//  ShotYardage.swift
//  caddie
//

import CoreLocation

/// Pure, view-independent yardage math shared by the play inspector and the map.
///
/// Extracted from `PlayDetailPane` so the segment logic can be unit-tested without
/// standing up a SwiftUI view. `nonisolated` so tests (and any off-main caller) can
/// use it directly.
nonisolated enum ShotYardage {
    /// Meters → yards conversion factor (1 m = 1.09361 yd).
    static let yardsPerMeter = 1.09361

    /// Yardage for each shot, parallel to `shots`. Shot 1 is measured from `tee`
    /// (the hole's first coordinate) when available; every later shot is measured
    /// from the previous shot. An element is `nil` when there's no reference point
    /// yet — i.e. shot 1 on a hole with no tee geometry.
    static func yards(
        tee: CLLocationCoordinate2D?,
        shots: [CLLocationCoordinate2D]
    ) -> [Int?] {
        meters(tee: tee, shots: shots).map { meters in
            meters.map { Int(($0 * yardsPerMeter).rounded()) }
        }
    }

    /// Straight-line distance in metres for each shot, parallel to `shots`, using
    /// the same segment logic as `yards`: shot 1 is measured from `tee` when
    /// available, every later shot from the previous shot. `nil` when there's no
    /// reference point yet. The unit-agnostic source both `yards` and the metric
    /// display path derive from.
    static func meters(
        tee: CLLocationCoordinate2D?,
        shots: [CLLocationCoordinate2D]
    ) -> [Double?] {
        var result: [Double?] = []
        var previous: CLLocationCoordinate2D? = tee
        for shot in shots {
            if let from = previous {
                let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: shot.latitude, longitude: shot.longitude))
                result.append(meters)
            } else {
                result.append(nil)
            }
            previous = shot
        }
        return result
    }

    /// Formats a metre distance for display, honoring the user's unit preference.
    /// `metric` → whole metres with an `m` suffix; otherwise whole yards with a `y`
    /// suffix. `separator` sits between the number and the unit (`""` for the map's
    /// compact "410y" pills, `" "` for the inspector's "410 y" rows).
    static func distanceLabel(meters: Double, metric: Bool, separator: String = "") -> String {
        if metric {
            return "\(Int(meters.rounded()))\(separator)m"
        }
        return "\(Int((meters * yardsPerMeter).rounded()))\(separator)y"
    }
}
