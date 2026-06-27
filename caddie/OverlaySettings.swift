//
//  OverlaySettings.swift
//  caddie
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Every independently styleable overlay layer drawn on the Map Surface. Each
/// layer carries a user-configurable color and visibility toggle, surfaced in the
/// Overlay Settings window.
enum OverlayLayer: String, CaseIterable, Identifiable {
    case boundary
    case holes
    case green
    case fairway
    case tee
    case bunker
    case rough
    case water
    case path
    case drivingRange
    case unknown

    var id: String { rawValue }

    /// Course-wide structure overlays (boundary outline, hole centerlines).
    static let structureLayers: [OverlayLayer] = [.boundary, .holes]
    /// Per-feature fills/strokes mapped from `OSMFeature.Kind`.
    static let featureLayers: [OverlayLayer] = [
        .green, .fairway, .tee, .bunker, .rough, .water, .path, .drivingRange, .unknown,
    ]

    var title: String {
        switch self {
        case .boundary: return "Course Boundary"
        case .holes: return "Holes"
        case .green: return "Greens"
        case .fairway: return "Fairways"
        case .tee: return "Tees"
        case .bunker: return "Bunkers"
        case .rough: return "Rough"
        case .water: return "Water Hazards"
        case .path: return "Cart Paths"
        case .drivingRange: return "Driving Range"
        case .unknown: return "Other Features"
        }
    }

    /// The shipped default color. The boundary is a plain white stroke; every other
    /// layer uses an sRGB `#RRGGBBAA` hex literal so first-run styling is identical
    /// to the pre-settings appearance.
    var defaultColor: Color {
        switch self {
        case .boundary: return .white
        case .holes: return Color(hex: "rgb(49, 141, 178)")!
        case .green: return Color(hex: "rgb(20, 119, 45)")!
        case .fairway: return Color(hex: "rgb(94, 221, 26)")!
        case .tee: return Color(hex: "#FFFFFFFF")!
        case .bunker: return Color(hex: "rgb(247, 255, 133)")!
        case .rough: return Color(hex: "#215E21FF")!
        case .water: return Color(hex: "#007AFFFF")!
        case .path: return Color(hex: "rgb(99, 99, 99)")!
        case .drivingRange: return Color(hex: "rgb(124, 176, 240)")!
        case .unknown: return Color(hex: "rgb(255, 0, 0)")!
        }
    }

    /// Painter order for the feature overlays that share the `.aboveRoads` map
    /// level. Lower values are drawn first (further back); higher values
    /// composite on top. Tuned so the visible stack reads, top to bottom:
    /// hole line ▸ greens ▸ fairways ▸ rough — the broad turf areas sit at the
    /// back, with the smaller detail features (tees, bunkers, water, cart paths)
    /// layered on top of the turf they sit within.
    ///
    /// This only sequences features WITHIN the `.aboveRoads` pass. The coarse z-axis
    /// is the MapKit overlay LEVEL, not this value: structure layers (boundary, holes)
    /// render in their own passes pinned to `.aboveLabels`, so they always sit above
    /// every feature here regardless of `drawOrder`. `drawOrder` can never cross
    /// levels — to change where the boundary or holes stack, set their
    /// `.mapOverlayLevel` in `ContentView`, NOT these numbers.
    var drawOrder: Int {
        switch self {
        case .rough: return 0
        case .drivingRange: return 1
        case .fairway: return 2
        case .green: return 3
        case .tee: return 4
        case .bunker: return 5
        case .water: return 6
        case .path: return 7
        case .unknown: return 8
        // Structure layers are pinned to `.aboveLabels` and never flow through the
        // sorted feature loop, so these values are unread — they exist only to keep
        // the switch exhaustive. Boundary/holes z-order is set by their map level.
        case .boundary: return -1
        case .holes: return 99
        }
    }

    /// The overlay layer a given OSM feature kind is drawn on.
    static func forFeature(_ kind: OSMFeature.Kind) -> OverlayLayer {
        switch kind {
        case .green: return .green
        case .fairway: return .fairway
        case .tee: return .tee
        case .bunker: return .bunker
        case .rough: return .rough
        case .waterHazard: return .water
        case .cartpath, .path: return .path
        case .drivingRange: return .drivingRange
        case .unknown: return .unknown
        }
    }
}

/// Observable store for per-layer overlay color + visibility, persisted to
/// `UserDefaults`. Unset layers fall back to `OverlayLayer.defaultColor` and
/// visible, so a fresh install renders exactly as before.
@MainActor
@Observable
final class OverlaySettings {
    private var colorOverrides: [OverlayLayer: Color] = [:]
    private var visibilityOverrides: [OverlayLayer: Bool] = [:]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for layer in OverlayLayer.allCases {
            if let hex = defaults.string(forKey: Self.colorKey(layer)), let color = Color(hex: hex) {
                colorOverrides[layer] = color
            }
            if defaults.object(forKey: Self.visibilityKey(layer)) != nil {
                visibilityOverrides[layer] = defaults.bool(forKey: Self.visibilityKey(layer))
            }
        }
    }

    func color(for layer: OverlayLayer) -> Color {
        colorOverrides[layer] ?? layer.defaultColor
    }

    func isVisible(_ layer: OverlayLayer) -> Bool {
        visibilityOverrides[layer] ?? true
    }

    func setColor(_ color: Color, for layer: OverlayLayer) {
        colorOverrides[layer] = color
        defaults.set(color.hexRGBA, forKey: Self.colorKey(layer))
    }

    func setVisible(_ visible: Bool, for layer: OverlayLayer) {
        visibilityOverrides[layer] = visible
        defaults.set(visible, forKey: Self.visibilityKey(layer))
    }

    /// Clears every override so all layers revert to their shipped defaults.
    func resetToDefaults() {
        for layer in OverlayLayer.allCases {
            colorOverrides[layer] = nil
            visibilityOverrides[layer] = nil
            defaults.removeObject(forKey: Self.colorKey(layer))
            defaults.removeObject(forKey: Self.visibilityKey(layer))
        }
    }

    func colorBinding(for layer: OverlayLayer) -> Binding<Color> {
        Binding(get: { self.color(for: layer) }, set: { self.setColor($0, for: layer) })
    }

    func visibilityBinding(for layer: OverlayLayer) -> Binding<Bool> {
        Binding(get: { self.isVisible(layer) }, set: { self.setVisible($0, for: layer) })
    }

    private static func colorKey(_ layer: OverlayLayer) -> String { "overlay.color.\(layer.rawValue)" }
    private static func visibilityKey(_ layer: OverlayLayer) -> String { "overlay.visible.\(layer.rawValue)" }
}

extension Color {
    /// sRGB `#RRGGBBAA` hex, suitable for round-tripping through `UserDefaults`.
    var hexRGBA: String? {
        #if canImport(AppKit)
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        let a = Int((srgb.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        #else
        return nil
        #endif
    }

    /// Parses an sRGB color from either a `#RRGGBBAA` (or `RRGGBBAA`) hex string
    /// or a CSS-style `rgb(r, g, b)` / `rgba(r, g, b, a)` string where the
    /// channels are 0–255 integers and the optional alpha is a 0–255 integer.
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("rgb") {
            let inside = s.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            let parts = inside.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard (3...4).contains(parts.count),
                  let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2])
            else { return nil }
            let a = parts.count == 4 ? (Int(parts[3]) ?? 255) : 255
            self = Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255,
                         blue: Double(b) / 255, opacity: Double(a) / 255)
            return
        }
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let r = Double((value >> 24) & 0xFF) / 255
        let g = Double((value >> 16) & 0xFF) / 255
        let b = Double((value >> 8) & 0xFF) / 255
        let a = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
