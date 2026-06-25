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
    case trees
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

    /// Course-wide structure overlays (boundary outline, hole centerlines, trees).
    static let structureLayers: [OverlayLayer] = [.boundary, .holes, .trees]
    /// Per-feature fills/strokes mapped from `OSMFeature.Kind`.
    static let featureLayers: [OverlayLayer] = [
        .green, .fairway, .tee, .bunker, .rough, .water, .path, .drivingRange, .unknown,
    ]

    var title: String {
        switch self {
        case .boundary: return "Course Boundary"
        case .holes: return "Holes"
        case .trees: return "Trees"
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
    /// layer falls back to its asset-catalog color so first-run styling is
    /// identical to the pre-settings appearance.
    var defaultColor: Color {
        switch self {
        case .boundary: return .white
        case .holes: return Color(.courseHole)
        case .trees: return Color(.courseTree)
        case .green: return Color(.courseGreen)
        case .fairway: return Color(.courseFairway)
        case .tee: return Color(.courseTee)
        case .bunker: return Color(.courseBunker)
        case .rough: return Color(.courseRough)
        case .water: return Color(.courseWater)
        case .path: return Color(.coursePath)
        case .drivingRange: return Color(.courseDrivingRange)
        case .unknown: return Color(.courseUnknown)
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

    /// Parses a `#RRGGBBAA` (or `RRGGBBAA`) sRGB hex string.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 24) & 0xFF) / 255
        let g = Double((value >> 16) & 0xFF) / 255
        let b = Double((value >> 8) & 0xFF) / 255
        let a = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
