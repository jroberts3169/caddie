//
//  CourseMapView.swift
//  caddie
//
//  NSViewRepresentable wrapper around a native MKMapView. SwiftUI's `Map`
//  re-projects its `Marker`/`Annotation` content every frame, so on a streaming
//  `.realistic` terrain mesh the glyphs visibly bob/jitter as the ground height
//  under each one resolves. A native MKMapView anchors each MKAnnotationView to
//  the screen projection of its 2-D coordinate and keeps it pinned there, so the
//  glyphs stay rock-steady while keeping realistic elevation always on.
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Inputs

/// A single recorded shot on a hole. Carries the physics-backed `TrackmanShot`
/// measurement plus the club and the start/land coordinates, so the on-map arc
/// can bow to the shot's real apex (`MaxHeight`) and lateral shape (`Curve`).
///
/// `coordinate` (the landing point) and `init(coordinate:)` are kept as thin
/// shims so the yardage/label/annotation code that only needs a point — and the
/// tests — compile unchanged. The convenience initializer stamps a zeroed
/// measurement (flat arc) for those non-physics call sites.
struct Shot: Identifiable, Equatable {
    let id: UUID
    /// Where the shot was struck from (tee, or the previous shot's landing).
    var start: CLLocationCoordinate2D
    /// Where the shot came to rest — the point the marker is pinned to.
    var land: CLLocationCoordinate2D
    var club: Club
    var trackman: TrackmanShot

    /// Landing coordinate. Named `coordinate` so existing map/label code that
    /// only needs the resting point keeps working.
    var coordinate: CLLocationCoordinate2D { land }

    /// Apex height in metres, straight off the generated measurement.
    var apexHeight_m: Double { trackman.MaxHeight }
    /// Lateral shape in metres (draw/fade), straight off the measurement.
    var sideCurve_m: Double { trackman.Curve }

    init(id: UUID = UUID(),
         start: CLLocationCoordinate2D,
         land: CLLocationCoordinate2D,
         club: Club,
         trackman: TrackmanShot) {
        self.id = id
        self.start = start
        self.land = land
        self.club = club
        self.trackman = trackman
    }

    /// Lightweight initializer for call sites (tests, previews) that only have a
    /// landing point and no physics. Produces a flat, zero-apex shot whose start
    /// equals its landing.
    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.start = coordinate
        self.land = coordinate
        self.club = .iron7
        self.trackman = .zero
    }

    static func == (lhs: Shot, rhs: Shot) -> Bool {
        lhs.id == rhs.id
            && lhs.land.latitude == rhs.land.latitude
            && lhs.land.longitude == rhs.land.longitude
            && lhs.start.latitude == rhs.start.latitude
            && lhs.start.longitude == rhs.start.longitude
            && lhs.trackman == rhs.trackman
    }
}

/// How the map should frame its subject: a flat top-down region (for a whole
/// course) or a tilted, heading-aware 3D camera (for a single hole aimed down
/// the fairway).
enum MapFraming: Equatable {
    /// Flat, straight-down framing of a coordinate region — used when a course is
    /// first selected so its entire footprint fills the screen.
    case topDown(MKCoordinateRegion)
    /// Tilted camera looking at `center` from `distance` metres
    /// (`centerCoordinateDistance`, NOT altitude), pitched and rotated to
    /// `heading` — used to frame a hole down its tee→pin axis.
    case camera(
        center: CLLocationCoordinate2D,
        distance: CLLocationDistance,
        pitch: CGFloat,
        heading: CLLocationDirection
    )

    static func == (lhs: MapFraming, rhs: MapFraming) -> Bool {
        switch (lhs, rhs) {
        case let (.topDown(a), .topDown(b)):
            return a.center.latitude == b.center.latitude
                && a.center.longitude == b.center.longitude
                && a.span.latitudeDelta == b.span.latitudeDelta
                && a.span.longitudeDelta == b.span.longitudeDelta
        case let (.camera(ac, ad, ap, ah), .camera(bc, bd, bp, bh)):
            return ac.latitude == bc.latitude && ac.longitude == bc.longitude
                && ad == bd && ap == bp && ah == bh
        default:
            return false
        }
    }
}

/// A framing the map should apply, tagged with an identity token so re-applying
/// the *same* framing (e.g. re-selecting a course, or re-focusing the same hole)
/// still takes effect. SwiftUI would otherwise diff two equal values as "no
/// change" and skip the update.
struct MapFramingRequest: Equatable {
    var framing: MapFraming
    var id: UUID = UUID()

    static func == (lhs: MapFramingRequest, rhs: MapFramingRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// Small spherical-geometry helpers for framing a hole down its tee→pin axis
/// and for the physics-backed shot generator (cross-track / bearing math).
enum Geo {
    /// Mean earth radius in metres, matching the shot generator's model.
    static let earthRadius_m: Double = 6_371_008.8

    static func toRadians(_ d: Double) -> Double { d * .pi / 180.0 }
    static func toDegrees(_ r: Double) -> Double { r * 180.0 / .pi }

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Initial bearing (0…360, degrees, 0 = north) from `a` to `b`. Spelled
    /// `initialBearing` to match the shot generator (`bearing(from:to:)` is the
    /// framing code's spelling of the same value).
    static func initialBearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        bearing(from: a, to: b)
    }

    /// Signed cross-track distance in metres of `point` from the great-circle
    /// aim line (`origin` → `bearingDeg`). Positive = right of the aim line (as a
    /// RH player sees it), negative = left.
    static func crossTrackDistance(point p: CLLocationCoordinate2D,
                                   origin: CLLocationCoordinate2D,
                                   bearingDeg: Double) -> Double {
        let d13 = distance(origin, p) / earthRadius_m
        let θ13 = toRadians(initialBearing(origin, p))
        let θ12 = toRadians(bearingDeg)
        return asin(sin(d13) * sin(θ13 - θ12)) * earthRadius_m
    }

    /// Initial bearing (compass degrees, 0 = north) from `a` to `b`.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Midpoint along the great-circle arc between `a` and `b`.
    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, dLon = (b.longitude - a.longitude) * .pi / 180
        let bx = cos(lat2) * cos(dLon)
        let by = cos(lat2) * sin(dLon)
        let lat3 = atan2(sin(lat1) + sin(lat2),
                         sqrt((cos(lat1) + bx) * (cos(lat1) + bx) + by * by))
        let lon3 = lon1 + atan2(by, cos(lat1) + bx)
        return CLLocationCoordinate2D(latitude: lat3 * 180 / .pi, longitude: lon3 * 180 / .pi)
    }

    /// Destination coordinate reached by travelling `distance_m` metres from
    /// `origin` along the initial compass `bearingDeg`. Used to probe a short
    /// ground baseline for the shot-arc's live screen-space projection.
    static func destination(from origin: CLLocationCoordinate2D,
                            bearingDeg: Double,
                            distance_m: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let angular = distance_m / radius
        let bearing = bearingDeg * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

// MARK: - Shot arc overlay

/// Transparent screen-space `NSView` layered over the `MKMapView` that renders
/// each recorded shot as a red parabolic ball-flight arc rising off the ground,
/// with a soft ground shadow beneath it. Because the map runs `.realistic`
/// elevation, a sky-rising arc can't be an `MKOverlay` (overlays are glued to
/// the terrain plane and inherit the 3D perspective).
///
/// The arc is a **2D quadratic Bézier drawn in screen space**, rebuilt every
/// display-link tick from the live camera per `docs/shot-arc-rendering.md`:
/// both endpoints are re-projected each frame (snapped to the rendered marker
/// glyph centre so the arc foot is welded to the shot counter), and the control
/// point is `chordMid + 2·(altitude·H + side·S)` where `H` is the shot's real
/// apex height in metres and `S` its lateral curve in metres, each scaled to
/// screen by a live camera-derived basis vector. The visible apex therefore
/// lands exactly at `chordMid + offset`.
///
/// The view is deliberately left in AppKit's default *unflipped* space
/// (screen-up = +y), so raising the apex *adds* to the control point's `y`.
fileprivate final class ShotArcOverlayView: NSView {
    struct ArcSegment {
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        /// Apex height of the flight in metres (the shot's `TrackmanShot.MaxHeight`).
        let apexHeight_m: Double
        /// Lateral shape of the flight in metres (the shot's `TrackmanShot.Curve`),
        /// signed: positive bows right of the aim line, negative left.
        let sideCurve_m: Double
    }

    weak var mapView: MKMapView?

    /// The shot segments to draw. Setting rebuilds on the next tick.
    var segments: [ArcSegment] = [] {
        didSet { tick() }
    }

    private static let shadowAlphaMin: CGFloat = 0.08
    private static let shadowAlphaMax: CGFloat = 0.5

    private var arcDisplayLink: CADisplayLink?

    private let arcLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = NSColor.systemRed.withAlphaComponent(0.95).cgColor
        l.fillColor = NSColor.clear.cgColor
        l.lineWidth = 2.5
        l.lineCap = .round
        l.lineJoin = .round
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.6
        l.shadowRadius = 2
        l.shadowOffset = .zero
        return l
    }()
    /// Container for per-segment ground-shadow strokes, sorted beneath the arc.
    private let shadowContainer = CALayer()
    /// Recycled shadow stroke layers (grown/shrunk instead of reallocated each tick).
    private var shadowSegments: [CAShapeLayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shadowContainer)
        layer?.addSublayer(arcLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fully transparent to clicks so MapKit pan/zoom and the map's gesture
    /// recognizers keep working underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        arcDisplayLink?.invalidate()
        arcDisplayLink = nil
        guard window != nil else { return }
        // A display link reliably follows MKMapView's internal animation ticks
        // (inertial pan, pitch, zoom easing) even while the region stays settled
        // between delegate callbacks, and is ProMotion-aware.
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        arcDisplayLink = link
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        arcLayer.frame = bounds
        arcLayer.contentsScale = scale
        shadowContainer.frame = bounds
        for s in shadowSegments { s.contentsScale = scale }
        tick()
    }

    deinit { arcDisplayLink?.invalidate() }

    @objc private func tick() {
        guard let map = mapView else {
            arcLayer.path = nil
            clearShadow()
            return
        }

        // Per §7 of docs/shot-arc-rendering.md: the arc is recomputed on EVERY
        // display-link tick — deliberately NOT gated behind a camera fingerprint.
        // MapKit animates pan/pitch/zoom internally (inertial fling, pinch easing)
        // between its region-changed callbacks, and during those animations
        // `map.camera` reports the *target* camera, not the in-flight interpolated
        // one. A fingerprint keyed off `map.camera` therefore reads "unchanged"
        // mid-animation, freezes the arc, and lets it drift behind the map until
        // the animation settles and snaps. Recomputing every frame from the live
        // projection (`map.convert`) pins the arc rigidly to its endpoints. Cost
        // is bounded by recycling the shadow segment layers instead of allocating.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard !segments.isEmpty else {
            arcLayer.path = nil
            clearShadow()
            return
        }

        // Each arc is a quadratic Bézier in screen space whose control point is
        // composed from the shot's real apex/side (metres) times a live
        // camera-derived basis — see `arcGeometry`. The ground shadow is a run of
        // short straight segments along the *screen chord* between the same two
        // projected endpoints (per §5.6 of the arc doc), bell-weighted so it's
        // dark at takeoff/landing and faint under the apex.
        let combined = CGMutablePath()
        var shadowSpecs: [(path: CGPath, alpha: CGFloat)] = []
        for seg in segments {
            guard let g = arcGeometry(for: seg, on: map) else { continue }
            let arc = CGMutablePath()
            arc.move(to: g.start)
            arc.addQuadCurve(to: g.end, control: g.ctrl)
            combined.addPath(arc)

            let n = Self.shadowSegmentCount
            var prev = g.start
            for i in 1...n {
                let u = CGFloat(i) / CGFloat(n)
                let next = CGPoint(x: g.start.x + (g.end.x - g.start.x) * u,
                                   y: g.start.y + (g.end.y - g.start.y) * u)
                let uMid = (CGFloat(i) - 0.5) / CGFloat(n)
                let bell = 1 - 4 * uMid * (1 - uMid)  // 1 at ends, 0 at apex
                let alpha = Self.shadowAlphaMin + (Self.shadowAlphaMax - Self.shadowAlphaMin) * bell
                let p = CGMutablePath()
                p.move(to: prev)
                p.addLine(to: next)
                shadowSpecs.append((p, alpha))
                prev = next
            }
        }
        arcLayer.path = combined
        applyShadow(shadowSpecs)
    }

    private struct ArcGeom {
        /// Screen point of the shot's start marker (its glyph centre).
        let start: CGPoint
        /// Screen point of the shot's landing marker (its glyph centre).
        let end: CGPoint
        /// Quadratic-Bézier control point: `chordMid + 2·(altitude·H + side·S)`.
        let ctrl: CGPoint
        /// The visible peak of the rendered curve, `(chordMid + ctrl)/2`.
        let apex: CGPoint
        /// Midpoint of the two projected endpoints; the offset base.
        let chordMid: CGPoint
        /// Screen pixels per metre of world altitude, `sin(pitch)·imagePlanePpm`.
        let altitudePxPerM: CGFloat
        /// Screen vector for one metre of ground travel perpendicular to the chord.
        let sideDirPxPerM: CGPoint
    }

    /// Number of straight segments used to draw the ground shadow along the chord.
    private static let shadowSegmentCount = 24

    /// Screen point (in this overlay's space) of the *rendered marker view* whose
    /// coordinate matches `coord`, per §6 of the arc doc. This is the anchoring
    /// trick: the arc foot is pinned to the numbered shot marker's on-screen
    /// pixel centre by reading the annotation view's actual frame — NOT by
    /// re-deriving it from `map.convert(coord, toPointTo:)`. On macOS the
    /// geographic `convert(_:toPointTo:subview)` does not reproduce where MapKit
    /// actually lays out its annotation views (they can differ by tens of points),
    /// so relying on it alone lets the arc float away from its marker. Returns
    /// `nil` only when no realized view exists yet, letting the caller fall back.
    private func annotationPoint(for coord: CLLocationCoordinate2D, on map: MKMapView) -> CGPoint? {
        for ann in map.annotations {
            if abs(ann.coordinate.latitude - coord.latitude) < 1e-7,
               abs(ann.coordinate.longitude - coord.longitude) < 1e-7,
               let v = map.view(for: ann) {
                let centerInMap = NSPoint(x: v.frame.midX, y: v.frame.midY)
                return map.convert(centerInMap, to: self)
            }
        }
        return nil
    }

    /// Returns the screen-space vector that one metre of ground travel along
    /// `bearingDeg` at `origin` projects to under the current camera. Probes a
    /// 10 m baseline centred on `origin` and divides by 10 so the result is
    /// robust to map-coordinate non-linearity over short distances. Carries both
    /// the direction and the (foreshortened) magnitude of a metre on screen.
    private func groundUnitProjection(from origin: CLLocationCoordinate2D,
                                      bearingDeg: Double,
                                      map: MKMapView) -> CGPoint {
        let half: Double = 5
        let a = Geo.destination(from: origin, bearingDeg: bearingDeg, distance_m: half)
        let b = Geo.destination(from: origin,
                                bearingDeg: (bearingDeg + 180).truncatingRemainder(dividingBy: 360),
                                distance_m: half)
        let aPt = map.convert(a, toPointTo: self)
        let bPt = map.convert(b, toPointTo: self)
        return CGPoint(x: (aPt.x - bPt.x) / 10, y: (aPt.y - bPt.y) / 10)
    }

    /// Builds one arc's screen-space geometry from the live camera, exactly per
    /// `docs/shot-arc-rendering.md` §5.
    private func arcGeometry(for seg: ArcSegment, on map: MKMapView) -> ArcGeom? {
        // 5.1 — project the endpoints, snapped to the numbered marker's on-screen
        // pixel centre (per §6). `annotationPoint` reads the realized annotation
        // view's frame; only when the marker isn't realized yet do we fall back to
        // the geographic projection. Anchoring to the marker view — not the raw
        // `map.convert` — is what keeps the arc foot glued to its shot counter on
        // macOS, where geographic-convert-to-a-subview doesn't match MapKit's own
        // annotation layout.
        let startPt = annotationPoint(for: seg.from, on: map) ?? map.convert(seg.from, toPointTo: self)
        let endPt = annotationPoint(for: seg.to, on: map) ?? map.convert(seg.to, toPointTo: self)
        guard startPt.x.isFinite, startPt.y.isFinite, endPt.x.isFinite, endPt.y.isFinite else { return nil }
        let chord = hypot(endPt.x - startPt.x, endPt.y - startPt.y)
        guard chord > 0.5 else { return nil }
        let ground_m = Geo.distance(seg.from, seg.to)
        guard ground_m > 0.1 else { return nil }

        // The apex and side are world-space quantities (metres). Recover the live
        // basis vectors by probing real ground geometry at the chord midpoint.
        let midCoord = CLLocationCoordinate2D(
            latitude: (seg.from.latitude + seg.to.latitude) / 2,
            longitude: (seg.from.longitude + seg.to.longitude) / 2)

        // 5.3 — side/curve basis: one metre perpendicular to the world chord.
        let chordBearing = Geo.initialBearing(seg.from, seg.to)
        let sidePerpBearing = (chordBearing + 90).truncatingRemainder(dividingBy: 360)
        let sideDirPxPerM = groundUnitProjection(from: midCoord, bearingDeg: sidePerpBearing, map: map)

        // 5.2 — altitude basis: world-up projects to screen-Y (zero camera roll);
        // magnitude = sin(pitch) × unforeshortened ppm sampled along the
        // camera-heading-perpendicular (image-plane) axis.
        let pitchRad = Double(map.camera.pitch) * .pi / 180
        let viewPerpBearing = (map.camera.heading + 90).truncatingRemainder(dividingBy: 360)
        let viewPerpVec = groundUnitProjection(from: midCoord, bearingDeg: viewPerpBearing, map: map)
        let unforeshortenedPpm = hypot(viewPerpVec.x, viewPerpVec.y)
        let altitudePxPerM = unforeshortenedPpm * CGFloat(sin(pitchRad))

        // 5.4 — compose the control point. A quadratic Bézier's t=0.5 point is
        // 0.5·chordMid + 0.5·ctrl, so `ctrl = chordMid + 2·offset` puts the
        // visible apex exactly at `chordMid + offset`. The view is unflipped
        // (screen-up = +y), so the altitude term ADDS to y.
        let chordMid = CGPoint(x: (startPt.x + endPt.x) / 2, y: (startPt.y + endPt.y) / 2)
        let H = CGFloat(seg.apexHeight_m)
        let S = CGFloat(seg.sideCurve_m)
        let ctrl = CGPoint(
            x: chordMid.x + sideDirPxPerM.x * S * 2,
            y: chordMid.y + altitudePxPerM * H * 2 + sideDirPxPerM.y * S * 2)
        guard ctrl.x.isFinite, ctrl.y.isFinite else { return nil }
        let apex = CGPoint(x: (chordMid.x + ctrl.x) / 2, y: (chordMid.y + ctrl.y) / 2)

        return ArcGeom(start: startPt, end: endPt, ctrl: ctrl, apex: apex,
                       chordMid: chordMid,
                       altitudePxPerM: altitudePxPerM, sideDirPxPerM: sideDirPxPerM)
    }

    private func applyShadow(_ specs: [(path: CGPath, alpha: CGFloat)]) {
        let scale = window?.backingScaleFactor ?? 2
        while shadowSegments.count < specs.count {
            let l = CAShapeLayer()
            l.fillColor = NSColor.clear.cgColor
            l.strokeColor = NSColor.black.cgColor
            l.lineWidth = 2
            l.lineCap = .butt
            l.contentsScale = scale
            shadowContainer.addSublayer(l)
            shadowSegments.append(l)
        }
        while shadowSegments.count > specs.count {
            shadowSegments.removeLast().removeFromSuperlayer()
        }
        for (i, spec) in specs.enumerated() {
            shadowSegments[i].path = spec.path
            shadowSegments[i].opacity = Float(spec.alpha)
        }
    }

    private func clearShadow() {
        for l in shadowSegments { l.removeFromSuperlayer() }
        shadowSegments.removeAll()
    }
}

/// Flat, `Equatable` snapshot of the per-layer style (resolved `NSColor` + a
/// visibility flag) the map needs to draw. Built by `ContentView` from the
/// `@Observable` `OverlaySettings` so SwiftUI's dependency tracking sees the read
/// and the representable re-syncs when colors/visibility change.
struct MapStyleConfig: Equatable {
    var colors: [OverlayLayer: NSColorBox]
    var visible: [OverlayLayer: Bool]
    var showMapLabels: Bool
    var useMetricDistance: Bool

    func color(_ layer: OverlayLayer) -> NSColor { colors[layer]?.color ?? .white }
    func isVisible(_ layer: OverlayLayer) -> Bool { visible[layer] ?? true }
}

/// `Equatable`/`Hashable` wrapper so an `NSColor` can live inside an `Equatable`
/// value type. Compares by sRGB component values, not object identity, so two
/// equal colors don't trigger a spurious re-style.
struct NSColorBox: Equatable {
    let color: NSColor

    static func == (lhs: NSColorBox, rhs: NSColorBox) -> Bool {
        let a = lhs.color.usingColorSpace(.sRGB)
        let b = rhs.color.usingColorSpace(.sRGB)
        return a?.redComponent == b?.redComponent
            && a?.greenComponent == b?.greenComponent
            && a?.blueComponent == b?.blueComponent
            && a?.alphaComponent == b?.alphaComponent
    }
}

// MARK: - Representable

struct CourseMapView: NSViewRepresentable {
    /// Boundary outline rings of the displayed course (each ring its own polygon).
    var outlines: [[CLLocationCoordinate2D]]
    /// Turf/detail features of the displayed course.
    var features: [OSMFeature]
    /// Holes of the displayed course (centerline + tee/pin markers).
    var holes: [OSMHole]
    /// The course currently opened, or `nil` when browsing the nearby map.
    var displayedCourse: GolfCourse?
    /// Geocoded coordinate for the displayed course's pin (falls back to the
    /// course's own coordinate when geocoding hasn't resolved).
    var courseMarkerCoordinate: CLLocationCoordinate2D?
    /// Golf courses within range of the user, shown as flags on the nearby map.
    var nearbyCourses: [GolfCourse]
    /// Resolved per-layer colors + visibility.
    var style: MapStyleConfig
    /// The framing to apply, or `nil` to leave the camera where it is.
    var framingRequest: MapFramingRequest?
    /// Recorded shots for the hole currently focused in Play mode.
    var shots: [Shot]
    /// The hole currently focused in Play mode.
    var currentHole: OSMHole?
    /// Whether the map is in Play mode (clicking records a shot).
    var isPlayMode: Bool
    /// Latest mouse-hover location in the map's local coordinate space, or `nil`
    /// when the pointer is outside the map. Fed from SwiftUI's `.onContinuousHover`
    /// (an external `NSTrackingArea` on `MKMapView` proved unreliable) so hovering a
    /// dimmed hole in Play mode can lift it back to full opacity.
    var hoverLocation: CGPoint?
    /// Called with the map coordinate of a click while in Play mode.
    var onAddShot: (CLLocationCoordinate2D) -> Void
    /// Called with a hole's OSM id when its tee marker is tapped in Play mode.
    var onSelectHole: (Int64) -> Void
    /// Called with a nearby course's identifier when its flag is tapped on the
    /// browse map, so that course can be opened.
    var onSelectCourse: (String) -> Void
    /// Called with the new region after the user pans/zooms the map (not fired for
    /// programmatic camera moves), so a "Search here" affordance can be offered.
    var onCameraMoved: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // Start with a real, non-zero frame. SwiftUI lays the NSView out a beat
        // later, but `MKMapView.setRegion` is a silent no-op while bounds are
        // `.zero`, so an early region set here would otherwise never stick.
        let initialFrame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let container = NSView(frame: initialFrame)
        container.autoresizesSubviews = true

        let map = MKMapView(frame: container.bounds)
        map.autoresizingMask = [.width, .height]
        map.delegate = context.coordinator
        // Realistic elevation, always. Hybrid keeps roads/labels over the imagery.
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsUserLocation = true
        container.addSubview(map)
        context.coordinator.map = map

        // Screen-space overlay that draws each shot as a rising ball-flight arc +
        // ground shadow. Added below the map's annotation views so the arc passes
        // behind the tee/pin/shot glyphs; it's click-transparent so the map stays
        // freely pannable.
        let arc = ShotArcOverlayView(frame: map.bounds)
        arc.autoresizingMask = [.width, .height]
        arc.wantsLayer = true
        map.addSubview(arc, positioned: .below, relativeTo: nil)
        arc.mapView = map
        context.coordinator.arcOverlay = arc
        // Click-to-record-a-shot (gated to Play mode in the handler). A plain click
        // recognizer fires reliably on a zero-movement click; MapKit's own pan still
        // owns drags, so the map stays freely pannable.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapClick(_:))
        )
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let map = context.coordinator.map else { return }
        context.coordinator.onAddShot = onAddShot
        context.coordinator.onSelectHole = onSelectHole
        context.coordinator.onSelectCourse = onSelectCourse
        context.coordinator.onCameraMoved = onCameraMoved
        context.coordinator.isPlayMode = isPlayMode
        context.coordinator.sync(
            map: map,
            outlines: outlines,
            features: features,
            holes: holes,
            displayedCourse: displayedCourse,
            courseMarkerCoordinate: courseMarkerCoordinate,
            nearbyCourses: nearbyCourses,
            style: style,
            shots: shots,
            currentHole: currentHole,
            framingRequest: framingRequest
        )
        // Re-run after `sync` (which owns `currentHoleID`) so a hover computed here
        // dims/undims against the up-to-date focused hole.
        context.coordinator.hover(at: hoverLocation)
    }
}

// MARK: - Overlays

/// The structural role of a map overlay, used by the renderer to pick the right
/// fill/stroke treatment independent of which `OverlayLayer` colors it.
private enum OverlayRole: String {
    case boundary
    case feature
    case hole
}

/// `MKPolygon` that remembers which layer/role styles it. Subclassing lets the
/// renderer recover the styling without a side table; MapKit instantiates the
/// subclass because the points-based initializer is the designated initializer.
private final class StyledPolygon: MKPolygon {
    var layer: OverlayLayer = .unknown
    var role: OverlayRole = .feature
}

/// `MKPolyline` counterpart of `StyledPolygon` (open features, hole centerlines).
private final class StyledPolyline: MKPolyline {
    var layer: OverlayLayer = .unknown
    var role: OverlayRole = .feature
    /// For `.hole` centerlines, the owning hole's OSM id, so the renderer can dim
    /// every non-focused hole to match the tee/pin/label emphasis in Play mode.
    var osmIdentifier: Int64?
}

// MARK: - Annotations

/// Pin for the course currently opened on the map.
private final class CourseMarkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    init(coordinate: CLLocationCoordinate2D, title: String?) {
        self.coordinate = coordinate
        self.title = title
    }
}

/// Flag for one of the nearby golf courses on the browse map.
private final class NearbyCourseAnnotation: NSObject, MKAnnotation {
    let identifier: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    init(identifier: String, coordinate: CLLocationCoordinate2D, title: String?) {
        self.identifier = identifier
        self.coordinate = coordinate
        self.title = title
    }
}

/// Numbered marker at a hole's tee, carrying par/length detail in its callout.
private final class HoleTeeAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let osmIdentifier: Int64
    let glyph: String
    /// Par/distance callout text. Mutable so a units change can update it in place
    /// without tearing down and re-adding the tee marker (which would flash).
    var title: String?
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64, glyph: String, title: String?) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
        self.glyph = glyph
        self.title = title
    }
}

/// Small filled disc at a hole's green (the pin position).
private final class HolePinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let osmIdentifier: Int64
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
    }
}

/// Par/distance text label beneath a hole's tee (e.g. "Par 4 · 410y"). We draw
/// it ourselves rather than lean on the tee marker's native `title`: MapKit
/// renders a marker's floating title in a separate layer that ignores the
/// annotation view's `alphaValue`, so the native title can't be dimmed in step
/// with the rest of the hole's markers. Owning it lets `emphasisAlpha` fade it.
private final class HoleTitleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let osmIdentifier: Int64
    /// The rendered "Par 4 · 410y" string. Mutable so a units change can re-render
    /// the label image in place without a remove/re-add flash.
    var text: String
    init(coordinate: CLLocationCoordinate2D, osmIdentifier: Int64, text: String) {
        self.coordinate = coordinate
        self.osmIdentifier = osmIdentifier
        self.text = text
    }
}

/// Numbered marker for a recorded shot on the active hole.
private final class ShotAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let number: Int
    init(coordinate: CLLocationCoordinate2D, number: Int) {
        self.coordinate = coordinate
        self.number = number
    }
}

/// Small yardage pill anchored near a shot segment.
private final class ShotYardageAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// The rendered distance string ("410y"/"375m"). Mutable so a units change can
    /// re-render the pill in place without a remove/re-add flash.
    var label: String
    let shotNumber: Int

    init(coordinate: CLLocationCoordinate2D, label: String, shotNumber: Int) {
        self.coordinate = coordinate
        self.label = label
        self.shotNumber = shotNumber
    }
}

// MARK: - Coordinator

extension CourseMapView {
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        /// The pin glyph is identical for every flag marker (tint is applied
        /// per-view via `markerTintColor`), so look the SF Symbol up once instead
        /// of re-allocating it on every `viewFor` call during pan/zoom.
        private static let flagGlyph = NSImage(
            systemSymbolName: "flag.fill", accessibilityDescription: nil
        )

        weak var map: MKMapView?
        /// Screen-space overlay that renders shot arcs + shadows.
        fileprivate weak var arcOverlay: ShotArcOverlayView?
        /// Called with the clicked coordinate while in Play mode.
        var onAddShot: ((CLLocationCoordinate2D) -> Void)?
        /// Called with a tapped tee's hole OSM id while in Play mode.
        var onSelectHole: ((Int64) -> Void)?
        /// Called with a tapped nearby course's identifier on the browse map.
        var onSelectCourse: ((String) -> Void)?
        /// Called with the new region after a user-initiated pan/zoom.
        var onCameraMoved: ((MKCoordinateRegion) -> Void)?
        /// Whether a click should record a shot.
        var isPlayMode: Bool = false
        /// OSM id of the hole currently focused in Play mode. Every other hole's
        /// tee/pin marker is dimmed so the active hole reads as the subject.
        var currentHoleID: Int64?
        /// OSM id of the hole whose marker the mouse is currently hovering (Play
        /// mode). A hovered dimmed hole is lifted back to full opacity so it can be
        /// previewed without leaving the active hole.
        private var hoveredHoleID: Int64?

        /// Hash of the inputs that determine the overlay set, so we only rebuild
        /// overlays (an expensive add/remove) when the geometry or style changes.
        private var appliedOverlayHash: Int?
        /// Hash of the inputs that determine the static annotation set (course
        /// marker, hole tees/pins, nearby flags) — everything except shots.
        private var appliedStaticAnnotationHash: Int?
        /// Hash of the inputs that determine the hole title label text (holes +
        /// distance-unit preference). Kept separate from the static-annotation hash
        /// so a units toggle updates the labels in place instead of rebuilding —
        /// and flashing — every tee/pin/marker.
        private var appliedHoleTitleHash: Int?
        /// Hash of the inputs that determine the shot annotation set.
        private var appliedShotAnnotationHash: Int?
        /// Identity of the last applied region request, so the same region can be
        /// re-framed but an unchanged one isn't reapplied every update pass.
        private var appliedRegionID: UUID?
        /// True while we're driving a programmatic `setRegion`, so the resulting
        /// `regionDidChangeAnimated` callback can be told apart from a user pan/zoom.
        private var isApplyingRegion = false
        /// Whether we've framed the map at least once. MapKit fires a region change
        /// as it settles its initial region on launch; suppressing reports until
        /// after our first framing keeps that from popping the "Search here" button.
        private var hasFramedOnce = false
        /// Whether a course-footprint zoom-out ceiling is currently installed on the
        /// map, so it can be lifted exactly once when the course is closed.
        private var courseZoomCeilingApplied = false
        /// True while a course is open and the camera boundary is pinned to its
        /// footprint, so the user can't pan away from the course out into the wider
        /// world. Cleared (boundary removed) when the course closes.
        private var courseCameraBoundaryApplied = false

        // MARK: Sync entry point

        func sync(
            map: MKMapView,
            outlines: [[CLLocationCoordinate2D]],
            features: [OSMFeature],
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig,
            shots: [Shot],
            currentHole: OSMHole?,
            framingRequest: MapFramingRequest?
        ) {
            currentHoleID = currentHole?.osmIdentifier
            let segments = shotSegments(shots: shots, currentHole: currentHole)
            arcOverlay?.segments = segments.map {
                ShotArcOverlayView.ArcSegment(
                    from: $0.from,
                    to: $0.to,
                    apexHeight_m: $0.apexHeight_m,
                    sideCurve_m: $0.sideCurve_m
                )
            }
            syncMapConfiguration(map: map, style: style)
            syncOverlays(
                map: map,
                outlines: outlines,
                features: features,
                holes: holes,
                style: style,
                shots: shots,
                currentHole: currentHole,
                segments: segments
            )
            syncAnnotations(
                map: map,
                holes: holes,
                displayedCourse: displayedCourse,
                courseMarkerCoordinate: courseMarkerCoordinate,
                nearbyCourses: nearbyCourses,
                style: style,
                shots: shots,
                segments: segments
            )
            applyFraming(map: map, framingRequest: framingRequest, courseIsOpen: displayedCourse != nil)
            // Drop the zoom-out ceiling and pan boundary once no course is open, so
            // the nearby browse map is freely pannable/zoomable again. (Both are set
            // in `applyFraming`, where the freshly-applied footprint is known.)
            if displayedCourse == nil {
                if courseZoomCeilingApplied {
                    map.setCameraZoomRange(nil, animated: false)
                    courseZoomCeilingApplied = false
                }
                if courseCameraBoundaryApplied {
                    map.setCameraBoundary(nil, animated: false)
                    courseCameraBoundaryApplied = false
                }
            }
            updateHoleEmphasis(map: map)
        }

        /// Applies map-level configuration (e.g. POI label filter) when the style changes.
        private var currentShowMapLabels: Bool?

        private func syncMapConfiguration(map: MKMapView, style: MapStyleConfig) {
            guard style.showMapLabels != currentShowMapLabels else { return }
            currentShowMapLabels = style.showMapLabels
            if let config = map.preferredConfiguration as? MKHybridMapConfiguration {
                config.pointOfInterestFilter = style.showMapLabels ? nil : .excludingAll
                map.preferredConfiguration = config
            }
        }

        // MARK: Clicks

        /// Handles a Play-mode click: a click on a hole's tee marker switches focus
        /// to that hole; otherwise the click records a shot. `map.hitTest` is
        /// unreliable for `MKMarkerAnnotationView` (its balloon is drawn above the
        /// coordinate anchor, so the view's frame doesn't line up with the visible
        /// glyph), so the tee glyphs are hit-tested geometrically: each tee's
        /// coordinate is projected to its on-screen tip and a balloon-shaped rect is
        /// anchored there. The nearest tee whose balloon contains the click wins.
        @objc func handleMapClick(_ gesture: NSClickGestureRecognizer) {
            guard let map else { return }
            let point = gesture.location(in: map)

            // On the browse map a click on a nearby course's flag opens that course.
            if let nearby = nearestNearbyCourse(to: point, in: map) {
                onSelectCourse?(nearby.identifier)
                return
            }

            guard isPlayMode else { return }

            if let holeID = nearestHoleMarker(to: point, in: map) {
                onSelectHole?(holeID)
                return
            }
            // Clicks landing on any other annotation glyph (course pin, shot marker)
            // shouldn't also drop a shot underneath it.
            var view = map.hitTest(point)
            while let current = view {
                if current is MKAnnotationView { return }
                view = current.superview
            }

            let coordinate = map.convert(point, toCoordinateFrom: map)
            onAddShot?(coordinate)
        }

        // MARK: Hover

        /// Lifts the hovered hole to full opacity. Only meaningful in Play mode
        /// (where other holes are dimmed). `point` is in the map's local coordinate
        /// space (as delivered by SwiftUI's `.onContinuousHover`), or `nil` when the
        /// pointer leaves the map. The hit test reuses the tee glyph geometry so
        /// hovering a hole's numbered marker previews that hole's tee, dotted
        /// centerline and stats label without switching the active hole.
        func hover(at point: CGPoint?) {
            guard let map else { return }
            // `.onContinuousHover` reports in the SwiftUI view's coordinate space,
            // which is offset from the MKMapView's own bounds (the map ignores the
            // safe area and extends under the title bar), so its point can't be
            // hit-tested against `map.convert`-projected tee tips. Read the pointer
            // straight from the map's window instead — that lands in the exact same
            // space as a click's `gesture.location(in: map)`, where the tee geometry
            // is known to be correct. The passed point only signals hover vs. exit.
            guard point != nil, let window = map.window else {
                updateHover(to: nil, map: map)
                return
            }
            let inMap = map.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let holeID = hoveredHole(at: inMap, in: map)
            updateHover(to: holeID, map: map)
        }

        /// Applies a new hovered-hole id, re-running the emphasis pass only when it
        /// actually changes so a continuous mouse move doesn't thrash the map.
        private func updateHover(to holeID: Int64?, map: MKMapView) {
            guard holeID != hoveredHoleID else { return }
            hoveredHoleID = holeID
            updateHoleEmphasis(map: map)
        }

        /// The OSM id of the hole whose tee OR pin glyph is nearest `point` (within
        /// its hit rect), or `nil` if the mouse is over no marker. Both a hole's tee
        /// marker and its pin marker preview the same hole, so either one lifts it.
        private func hoveredHole(at point: CGPoint, in map: MKMapView) -> Int64? {
            var best: (id: Int64, distance: CGFloat)?
            func consider(_ annotation: MKAnnotation, holeID: Int64) {
                let rect = markerHitRect(for: annotation, in: map)
                guard rect.contains(point) else { return }
                let dx = point.x - rect.midX, dy = point.y - rect.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (holeID, distance)
                }
            }
            for tee in map.annotations.compactMap({ $0 as? HoleTeeAnnotation }) {
                consider(tee, holeID: tee.osmIdentifier)
            }
            for pin in map.annotations.compactMap({ $0 as? HolePinAnnotation }) {
                consider(pin, holeID: pin.osmIdentifier)
            }
            return best?.id
        }

        /// Screen-space hit rect for a marker's balloon glyph, in the map's
        /// coordinate space. Prefers the annotation view's ACTUAL frame — MapKit
        /// positions and billboards that view at a constant screen size regardless
        /// of camera pitch/zoom, so its frame is reliable where a
        /// geometrically-estimated glyph center is not — padded outward for an
        /// easier target. Falls back to a balloon rect anchored at the projected
        /// coordinate tip when the view isn't materialized (off-screen, or not yet
        /// drawn after an add).
        private func markerHitRect(for annotation: MKAnnotation, in map: MKMapView) -> CGRect {
            let pad: CGFloat = 14
            if let view = map.view(for: annotation) {
                return view.frame.insetBy(dx: -pad, dy: -pad)
            }
            // MKMarkerAnnotationView balloon: ~40pt wide, tip at bottom-center,
            // rising ~52pt above the tip.
            let tip = map.convert(annotation.coordinate, toPointTo: map)
            return CGRect(x: tip.x - 20, y: tip.y - 52, width: 40, height: 52)
                .insetBy(dx: -pad, dy: -pad)
        }

        /// The OSM id of the hole whose tee OR pin glyph contains `point`, or `nil`
        /// if the click missed every hole marker. A hole's tee and its pin both
        /// switch focus to that hole. When markers overlap, the one whose hit rect
        /// center is nearest the click wins (not the first in iteration order).
        private func nearestHoleMarker(to point: CGPoint, in map: MKMapView) -> Int64? {
            var best: (id: Int64, distance: CGFloat)?
            func consider(_ annotation: MKAnnotation, holeID: Int64) {
                // The current hole's own markers are where you record shots, so they
                // aren't a hole-switch target — clicks there fall through to `addShot`.
                if holeID == currentHoleID { return }
                // Hit-test against the marker's actual rendered frame (see
                // `markerHitRect`), which stays accurate when the map is tilted into
                // a hole where a geometric glyph-center estimate drifts.
                let rect = markerHitRect(for: annotation, in: map)
                guard rect.contains(point) else { return }
                let dx = point.x - rect.midX, dy = point.y - rect.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (holeID, distance)
                }
            }
            for tee in map.annotations.compactMap({ $0 as? HoleTeeAnnotation }) {
                consider(tee, holeID: tee.osmIdentifier)
            }
            for pin in map.annotations.compactMap({ $0 as? HolePinAnnotation }) {
                consider(pin, holeID: pin.osmIdentifier)
            }
            return best?.id
        }

        /// The nearby-course flag whose balloon glyph contains `point`, or `nil` if
        /// the click missed every flag. Uses the same balloon-geometry hit test as
        /// the tees (an `MKMarkerAnnotationView`'s frame doesn't line up with its
        /// visible glyph). When flags overlap, the one whose tip is nearest wins.
        private func nearestNearbyCourse(to point: CGPoint, in map: MKMapView) -> NearbyCourseAnnotation? {
            var best: (course: NearbyCourseAnnotation, distance: CGFloat)?
            for course in map.annotations.compactMap({ $0 as? NearbyCourseAnnotation }) {
                let tip = map.convert(course.coordinate, toPointTo: map)
                let balloon = CGRect(x: tip.x - 24, y: tip.y - 56, width: 48, height: 60)
                guard balloon.contains(point) else { continue }
                let dx = point.x - tip.x, dy = point.y - tip.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || distance < best!.distance {
                    best = (course, distance)
                }
            }
            return best?.course
        }

        // MARK: Overlays

        private func syncOverlays(
            map: MKMapView,
            outlines: [[CLLocationCoordinate2D]],
            features: [OSMFeature],
            holes: [OSMHole],
            style: MapStyleConfig,
            shots: [Shot],
            currentHole: OSMHole?,
            segments: [ShotSegment]
        ) {
            var hasher = Hasher()
            for ring in outlines {
                hasher.combine(ring.count)
                if let f = ring.first { hasher.combine(f.latitude); hasher.combine(f.longitude) }
            }
            for f in features {
                hasher.combine(f.osmIdentifier)
                hasher.combine(f.isClosed)
            }
            for h in holes { hasher.combine(h.osmIdentifier) }
            for s in shots {
                hasher.combine(s.id)
                hasher.combine(s.coordinate.latitude)
                hasher.combine(s.coordinate.longitude)
            }
            hasher.combine(currentHole?.osmIdentifier)
            if let tee = currentHole?.coordinates.first {
                hasher.combine(tee.lat)
                hasher.combine(tee.lon)
            }
            // Style affects which overlays exist (visibility) and is cheap to fold in
            // so a Settings color/visibility change re-renders.
            for layer in OverlayLayer.allCases {
                hasher.combine(layer)
                hasher.combine(style.isVisible(layer))
                if let c = style.colors[layer]?.color.usingColorSpace(.sRGB) {
                    hasher.combine(c.redComponent)
                    hasher.combine(c.greenComponent)
                    hasher.combine(c.blueComponent)
                    hasher.combine(c.alphaComponent)
                }
            }
            let hash = hasher.finalize()
            guard hash != appliedOverlayHash else { return }
            appliedOverlayHash = hash

            let old = map.overlays
            // Add the new overlays first, then remove the old, so the map never
            // flashes empty between the two operations.
            // Features, painter-ordered, on the `.aboveRoads` level.
            let sortedFeatures = features.sorted {
                OverlayLayer.forFeature($0.kind).drawOrder < OverlayLayer.forFeature($1.kind).drawOrder
            }
            for feature in sortedFeatures {
                let layer = OverlayLayer.forFeature(feature.kind)
                guard style.isVisible(layer) else { continue }
                let coords = feature.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if feature.isClosed, coords.count >= 3 {
                    let poly = StyledPolygon(coordinates: coords, count: coords.count)
                    poly.layer = layer
                    poly.role = .feature
                    map.addOverlay(poly, level: .aboveRoads)
                } else if coords.count >= 2 {
                    let line = StyledPolyline(coordinates: coords, count: coords.count)
                    line.layer = layer
                    line.role = .feature
                    map.addOverlay(line, level: .aboveRoads)
                }
            }
            // Hole centerlines on `.aboveLabels` so they sit over the turf fills.
            if style.isVisible(.holes) {
                for hole in holes {
                    let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    guard coords.count >= 2 else { continue }
                    let line = StyledPolyline(coordinates: coords, count: coords.count)
                    line.layer = .holes
                    line.role = .hole
                    line.osmIdentifier = hole.osmIdentifier
                    map.addOverlay(line, level: .aboveLabels)
                }
            }
            // Boundary rings on `.aboveLabels`, above the feature fills.
            if style.isVisible(.boundary) {
                for ring in outlines where ring.count >= 3 {
                    let poly = StyledPolygon(coordinates: ring, count: ring.count)
                    poly.layer = .boundary
                    poly.role = .boundary
                    map.addOverlay(poly, level: .aboveLabels)
                }
            }
            // Recorded shots are drawn as rising ball-flight arcs by
            // `ShotArcOverlayView` (a screen-space overlay), not as ground
            // polylines — a sky-rising arc can't be an MKOverlay glued to the
            // 3D terrain plane.
            map.removeOverlays(old)
        }

        // MARK: Delegate

        /// Reports user-initiated pan/zoom so the map host can offer a "Search
        /// here" affordance. Our own programmatic camera moves (course framing,
        /// "Search here" itself) set `isApplyingRegion` around `setRegion`, so the
        /// resulting callback is recognized as ours and filtered out — everything
        /// else is the user dragging or zooming.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isApplyingRegion {
                isApplyingRegion = false
                hasFramedOnce = true
                return
            }
            guard hasFramedOnce else { return }
            onCameraMoved?(mapView.region)
        }

        /// The app drives all marker emphasis itself (hole focus, the flag on the
        /// current pin, dimming) and navigates on tap, so MapKit's built-in
        /// annotation selection is unwanted: a selected `MKMarkerAnnotationView`
        /// enlarges its balloon and lifts its glyph, which reads as a hole number
        /// "shifting" vertically and — because nothing else deselects it — persists
        /// as you move between holes. Immediately deselecting keeps every marker in
        /// its resting layout, killing that shift at the source (the `dequeueMarker`
        /// reset only catches recycled views, not one selected while on the map).
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? StyledPolygon {
                let renderer = MKPolygonRenderer(polygon: poly)
                let color = currentStyle?.color(poly.layer) ?? .white
                switch poly.role {
                case .boundary:
                    renderer.fillColor = .clear
                    renderer.strokeColor = color
                    renderer.lineWidth = 3
                default:
                    renderer.fillColor = color.withAlphaComponent(0.55)
                    renderer.strokeColor = color
                    renderer.lineWidth = 1
                }
                return renderer
            }
            if let line = overlay as? StyledPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                let color = currentStyle?.color(line.layer) ?? .white
                renderer.strokeColor = color
                if line.role == .hole {
                    renderer.lineWidth = 2
                    renderer.lineDashPattern = [6, 4]
                    if let id = line.osmIdentifier {
                        renderer.strokeColor = color.withAlphaComponent(emphasisAlpha(for: id))
                    }
                } else {
                    renderer.lineWidth = 2
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// The most recent style, stashed so `rendererFor` (called lazily by MapKit
        /// outside the `sync` call) can resolve current colors.
        private var currentStyle: MapStyleConfig?

        // MARK: Annotations

        private func syncAnnotations(
            map: MKMapView,
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig,
            shots: [Shot],
            segments: [ShotSegment]
        ) {
            currentStyle = style
            syncStaticAnnotations(
                map: map,
                holes: holes,
                displayedCourse: displayedCourse,
                courseMarkerCoordinate: courseMarkerCoordinate,
                nearbyCourses: nearbyCourses,
                style: style
            )
            syncShotAnnotations(map: map, shots: shots, segments: segments)
            syncHoleTitles(map: map, holes: holes, displayedCourse: displayedCourse, style: style)
        }

        /// Rebuilds the course marker, hole tees/pins, and nearby flags. This set
        /// changes only on course selection / nearby load / holes style change —
        /// never when a shot is recorded — so dropping a shot no longer tears down
        /// and recycles every tee/pin glyph (MapKit recycles the view during removal
        /// and hands back a stale cached image for one frame, which read as a flash).
        /// Gated on its own hash so an unrelated update is a no-op.
        private func syncStaticAnnotations(
            map: MKMapView,
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            courseMarkerCoordinate: CLLocationCoordinate2D?,
            nearbyCourses: [GolfCourse],
            style: MapStyleConfig
        ) {
            var hasher = Hasher()
            if let course = displayedCourse {
                hasher.combine(course.identifier)
                let c = courseMarkerCoordinate ?? course.coordinate
                hasher.combine(c.latitude); hasher.combine(c.longitude)
            } else {
                for course in nearbyCourses { hasher.combine(course.identifier) }
            }
            for h in holes { hasher.combine(h.osmIdentifier) }
            hasher.combine(style.isVisible(.holes))
            // Fold in the holes color so a color-only Settings change rebuilds the
            // tee/pin annotations: their tint is baked in by `viewFor`, which MapKit
            // only re-invokes on add/recycle, not when `currentStyle` changes.
            if let c = style.colors[.holes]?.color.usingColorSpace(.sRGB) {
                hasher.combine(c.redComponent)
                hasher.combine(c.greenComponent)
                hasher.combine(c.blueComponent)
                hasher.combine(c.alphaComponent)
            }
            let hash = hasher.finalize()
            guard hash != appliedStaticAnnotationHash else { return }
            appliedStaticAnnotationHash = hash

            // Remove only the static glyphs (leave the user-location dot and any
            // shot/yardage annotations in place), then rebuild them.
            let toRemove = map.annotations.filter {
                $0 is CourseMarkerAnnotation
                    || $0 is HoleTeeAnnotation
                    || $0 is HolePinAnnotation
                    || $0 is HoleTitleAnnotation
                    || $0 is NearbyCourseAnnotation
            }
            map.removeAnnotations(toRemove)

            if let course = displayedCourse {
                let coord = courseMarkerCoordinate ?? course.coordinate
                map.addAnnotation(CourseMarkerAnnotation(coordinate: coord, title: course.name))
                if style.isVisible(.holes) {
                    for hole in holes {
                        let coords = hole.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                        if let tee = coords.first {
                            map.addAnnotation(HoleTeeAnnotation(
                                coordinate: tee,
                                osmIdentifier: hole.osmIdentifier,
                                glyph: hole.displayGlyph,
                                title: Self.holeTitle(hole, metric: style.useMetricDistance)
                            ))
                            map.addAnnotation(HoleTitleAnnotation(
                                coordinate: tee,
                                osmIdentifier: hole.osmIdentifier,
                                text: Self.holeTitle(hole, metric: style.useMetricDistance)
                            ))
                        }
                        if let pin = coords.last, coords.count >= 2 {
                            map.addAnnotation(HolePinAnnotation(coordinate: pin, osmIdentifier: hole.osmIdentifier))
                        }
                    }
                }
            } else {
                for course in nearbyCourses {
                    map.addAnnotation(NearbyCourseAnnotation(
                        identifier: course.identifier,
                        coordinate: course.coordinate,
                        title: course.name
                    ))
                }
            }
        }

        /// Updates the par/distance label text (and tee callout title) in place when
        /// the distance-unit preference changes, without removing or re-adding any
        /// annotation. Rebuilding the static set on a units toggle would recycle the
        /// tee/pin/marker views and flash them (MapKit hands back a stale cached image
        /// for one frame during removal); mutating just the affected labels avoids it.
        private func syncHoleTitles(
            map: MKMapView,
            holes: [OSMHole],
            displayedCourse: GolfCourse?,
            style: MapStyleConfig
        ) {
            guard displayedCourse != nil, style.isVisible(.holes) else { return }

            var hasher = Hasher()
            hasher.combine(style.useMetricDistance)
            for h in holes { hasher.combine(h.osmIdentifier) }
            let hash = hasher.finalize()
            guard hash != appliedHoleTitleHash else { return }
            appliedHoleTitleHash = hash

            var titleByHole: [Int64: String] = [:]
            for hole in holes {
                titleByHole[hole.osmIdentifier] = Self.holeTitle(hole, metric: style.useMetricDistance)
            }

            for annotation in map.annotations {
                switch annotation {
                case let title as HoleTitleAnnotation:
                    guard let newText = titleByHole[title.osmIdentifier], newText != title.text else { continue }
                    title.text = newText
                    // Re-render the label image on the live view so the change shows
                    // without a remove/re-add. `view(for:)` is nil when the label is
                    // off-screen/unrealized; the fresh `text` is used when it's next
                    // dequeued, so nothing is lost.
                    if let view = map.view(for: title) {
                        view.image = holeTitleLabelImage(newText)
                    }
                case let tee as HoleTeeAnnotation:
                    if let newText = titleByHole[tee.osmIdentifier] { tee.title = newText }
                default:
                    continue
                }
            }
        }

        /// Reconciles the recorded-shot markers and yardage pills incrementally:
        /// matching annotations are left untouched (no recycle, no flash); only
        /// genuinely new shot/segment annotations are inserted and stale ones
        /// removed. So recording a shot adds one marker without redrawing the
        /// markers already on screen — and never touches the tees/pins/course pin.
        private func syncShotAnnotations(
            map: MKMapView,
            shots: [Shot],
            segments: [ShotSegment]
        ) {
            var hasher = Hasher()
            for s in shots {
                hasher.combine(s.id)
                hasher.combine(s.coordinate.latitude)
                hasher.combine(s.coordinate.longitude)
            }
            for seg in segments {
                hasher.combine(seg.shotNumber)
                hasher.combine(seg.meters)
            }
            hasher.combine(currentStyle?.useMetricDistance ?? false)
            let hash = hasher.finalize()
            guard hash != appliedShotAnnotationHash else { return }
            appliedShotAnnotationHash = hash

            // Reconcile shot markers by number. Existing markers whose coordinate
            // still matches are kept as-is; only genuinely new shots are added and
            // stale ones removed.
            var shotByNumber: [Int: ShotAnnotation] = [:]
            for shot in map.annotations.compactMap({ $0 as? ShotAnnotation }) {
                shotByNumber[shot.number] = shot
            }
            var addShots: [ShotAnnotation] = []
            for (index, shot) in shots.enumerated() {
                let number = index + 1
                if let existing = shotByNumber[number],
                   existing.coordinate.latitude == shot.coordinate.latitude,
                   existing.coordinate.longitude == shot.coordinate.longitude {
                    shotByNumber[number] = nil
                } else {
                    addShots.append(ShotAnnotation(coordinate: shot.coordinate, number: number))
                }
            }
            let removeShots = Array(shotByNumber.values)

            // Same reconcile for the yardage pills, keyed by their shot number.
            // A pill whose segment still sits at the same midpoint is KEPT even when
            // its label changed (e.g. a yards↔metres units toggle): the text is
            // updated in place and the live view re-rendered, so switching units
            // never removes+re-adds the pill (which would flash). Only genuinely new
            // or moved pills are added and stale ones removed.
            var yardageByNumber: [Int: ShotYardageAnnotation] = [:]
            for yardage in map.annotations.compactMap({ $0 as? ShotYardageAnnotation }) {
                yardageByNumber[yardage.shotNumber] = yardage
            }
            var addYardage: [ShotYardageAnnotation] = []
            let metric = currentStyle?.useMetricDistance ?? false
            for segment in segments {
                let label = ShotYardage.distanceLabel(meters: segment.meters, metric: metric)
                if let existing = yardageByNumber[segment.shotNumber],
                   existing.coordinate.latitude == segment.midpoint.latitude,
                   existing.coordinate.longitude == segment.midpoint.longitude {
                    // Same pill position: keep it, updating the label in place if the
                    // unit/text changed so no remove/re-add (and no flash) occurs.
                    if existing.label != label {
                        existing.label = label
                        if let view = map.view(for: existing) {
                            view.image = yardagePillImage(label)
                        }
                    }
                    yardageByNumber[segment.shotNumber] = nil
                } else {
                    addYardage.append(ShotYardageAnnotation(
                        coordinate: segment.midpoint,
                        label: label,
                        shotNumber: segment.shotNumber
                    ))
                }
            }
            let removeYardage = Array(yardageByNumber.values)

            map.removeAnnotations(removeShots + removeYardage)
            map.addAnnotations(addShots + addYardage)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is MKUserLocation:
                return nil // system blue dot

            case let course as CourseMarkerAnnotation:
                let view = dequeueMarker(mapView, id: "courseMarker", for: course)
                view.markerTintColor = .systemRed
                view.glyphImage = Self.flagGlyph
                view.displayPriority = .required
                view.canShowCallout = true
                return view

            case let nearby as NearbyCourseAnnotation:
                let view = dequeueMarker(mapView, id: "nearbyCourse", for: nearby)
                view.markerTintColor = .systemGreen
                view.glyphImage = Self.flagGlyph
                view.displayPriority = .required
                view.canShowCallout = true
                return view

            case let tee as HoleTeeAnnotation:
                let view = dequeueMarker(mapView, id: "holeTee", for: tee)
                view.markerTintColor = currentStyle?.color(.holes) ?? .systemBlue
                view.glyphText = tee.glyph
                view.displayPriority = .required
                view.canShowCallout = true
                // The par/distance text is drawn by our own `HoleTitleAnnotation`
                // so it can be dimmed; MapKit's native marker title can't be, so
                // suppress it here to avoid an un-dimmable duplicate.
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.alphaValue = emphasisAlpha(for: tee.osmIdentifier)
                return view

            case let pin as HolePinAnnotation:
                // Every hole's pin is the same native marker; focus is conveyed by
                // opacity and display priority, both mutated in place by
                // `updateHoleEmphasis`. Keeping one view class (never swapping a
                // balloon marker for a disc) means changing holes never has to
                // remove+re-add the pin, so the marker stays anchored instead of
                // flashing when clicking through holes quickly.
                let view = dequeueMarker(mapView, id: "holePin", for: pin)
                view.markerTintColor = currentStyle?.color(.holes) ?? .systemBlue
                view.glyphImage = Self.flagGlyph
                view.canShowCallout = false
                view.displayPriority = pinDisplayPriority(for: pin.osmIdentifier)
                view.alphaValue = emphasisAlpha(for: pin.osmIdentifier)
                return view

            case let label as HoleTitleAnnotation:
                let id = "holeTitle"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: label, reuseIdentifier: id)
                view.annotation = label
                view.canShowCallout = false
                view.displayPriority = .required
                // Sit just below the tee marker's coordinate tip (positive y is down),
                // where MapKit's native marker title used to float.
                view.centerOffset = CGPoint(x: 0, y: 29)
                view.image = holeTitleLabelImage(label.text)
                view.alphaValue = emphasisAlpha(for: label.osmIdentifier)
                return view

            case let shot as ShotAnnotation:
                let view = dequeueMarker(mapView, id: "shot", for: shot)
                view.markerTintColor = .systemOrange
                view.glyphText = "\(shot.number)"
                view.displayPriority = .required
                view.canShowCallout = false
                return view

            case let yardage as ShotYardageAnnotation:
                let id = "shotYardage"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: yardage, reuseIdentifier: id)
                view.annotation = yardage
                view.canShowCallout = false
                view.displayPriority = .required
                view.centerOffset = CGPoint(x: 0, y: -12)
                view.image = yardagePillImage(yardage.label)
                return view

            default:
                return nil
            }
        }

        /// Renders a shot-distance pill ("410y"/"375m") as a rounded dark capsule with
        /// centered white text. Shared by `viewFor` (initial draw) and the in-place
        /// units-toggle reconcile so both produce an identical image.
        private func yardagePillImage(_ text: String) -> NSImage {
            let pillSize = pillSizeForYardage(text)
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paraStyle
            ]
            // Drawing handler renders at the target context's scale factor,
            // so the pill is sharp on Retina displays without manual scaling.
            return NSImage(size: pillSize, flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
                NSColor.black.withAlphaComponent(0.72).setFill()
                path.fill()
                let textRect = NSRect(x: 7, y: 3, width: rect.width - 14, height: rect.height - 6)
                text.draw(in: textRect, withAttributes: attrs)
                return true
            }
        }

        private func dequeueMarker(
            _ mapView: MKMapView,
            id: String,
            for annotation: MKAnnotation
        ) -> MKMarkerAnnotationView {
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            // Reset mutable visual state that survives recycling. A marker that was
            // selected (which enlarges the balloon and lifts its glyph) leaves the
            // glyph label vertically offset when the view is later reused for a
            // different annotation — visible as hole numbers sitting too high on the
            // tee markers after a sub-course switch removes+re-adds every tee. Clear
            // the glyph and offset here so each caller starts from a clean marker.
            view.setSelected(false, animated: false)
            view.centerOffset = .zero
            view.glyphText = nil
            view.glyphImage = nil
            return view
        }

        /// Whether `holeID` is the hole currently focused in Play mode. The single
        /// source of truth for "is this the active hole" so the pin's flag/priority
        /// styling in `viewFor` and `updateHoleEmphasis` can't drift apart.
        private func isFocused(holeID: Int64) -> Bool {
            isPlayMode && holeID == currentHoleID
        }

        // Opacity a hole's tee/pin marker should render at. In Play mode every
        // hole other than the focused one is dimmed so the active hole stands 
        // out; in Plan mode (or before a hole is chosen) all markers are fully 
        // opaque. A hovered hole is also lifted to full opacity so it can be previewed.
        private func emphasisAlpha(for holeID: Int64) -> CGFloat {
            guard isPlayMode, let current = currentHoleID else { return 1 }
            if holeID == current || holeID == hoveredHoleID { return 1 }
            return 0.35
        }

        /// Display priority a hole's pin should render at. The focused hole's pin
        /// outranks the rest so it wins any MapKit declutter. Single source of truth
        /// so `viewFor` and `updateHoleEmphasis` can't rank pins differently.
        private func pinDisplayPriority(for holeID: Int64) -> MKFeatureDisplayPriority {
            isFocused(holeID: holeID) ? .required : .defaultHigh
        }

        /// Re-applies `emphasisAlpha` to the tee/pin views already on the map, and
        /// refreshes each pin's flag/disc styling. MapKit only calls `viewFor` on
        /// add/recycle, so when the focused hole changes (advancing holes, switching
        /// sub-course, entering/leaving Play) the existing markers must be updated in
        /// place. Fades so the change reads as a deliberate emphasis shift rather
        /// than a pop.
        private func updateHoleEmphasis(map: MKMapView) {
            // Every hole marker is a persistent native view — the pin no longer
            // swaps view class on focus — so a hole change is a pure in-place
            // update: fade each marker's opacity and re-rank the pins' display
            // priority. Nothing is removed or re-added, so the markers stay
            // anchored instead of flashing when clicking through holes quickly.
            //
            // Only the hole markers (tee, pin, title) participate in emphasis, so
            // filter to them once up front — the animation loop never touches the
            // unrelated views (shots, yardage pills, course/nearby flags, the
            // user-location dot), and `map.view(for:)` is only paid per hole marker.
            let holeMarkers: [(annotation: MKAnnotation, holeID: Int64)] =
                map.annotations.compactMap { annotation in
                    switch annotation {
                    case let tee as HoleTeeAnnotation: return (tee, tee.osmIdentifier)
                    case let pin as HolePinAnnotation: return (pin, pin.osmIdentifier)
                    case let label as HoleTitleAnnotation: return (label, label.osmIdentifier)
                    default: return nil
                    }
                }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                for (annotation, holeID) in holeMarkers {
                    guard let view = map.view(for: annotation) else { continue }
                    // The focused hole's pin outranks the rest so it wins any MapKit
                    // declutter; priority isn't animatable, so set it directly.
                    if annotation is HolePinAnnotation,
                       let marker = view as? MKMarkerAnnotationView {
                        marker.displayPriority = pinDisplayPriority(for: holeID)
                    }
                    let target = emphasisAlpha(for: holeID)
                    if view.alphaValue != target {
                        view.animator().alphaValue = target
                    }
                }
            }
            // The dotted hole centerlines dim the same way, but overlay renderers
            // aren't part of the AppKit animation graph — re-stroke each cached hole
            // renderer with the new emphasis alpha and mark it for redraw.
            for overlay in map.overlays {
                guard let line = overlay as? StyledPolyline, line.role == .hole,
                      let id = line.osmIdentifier,
                      let renderer = map.renderer(for: overlay) as? MKPolylineRenderer else { continue }
                let color = currentStyle?.color(line.layer) ?? .white
                renderer.strokeColor = color.withAlphaComponent(emphasisAlpha(for: id))
                renderer.setNeedsDisplay()
            }
        }

        /// Compact hole label, e.g. "Par 4 · 410y". Falls back to the
        /// coordinate-derived tee-to-pin distance when OSM lacks a length tag.
        /// `metric` switches the distance suffix between yards and metres.
        private static func holeTitle(_ hole: OSMHole, metric: Bool) -> String {
            var parts: [String] = []
            if let par = hole.par { parts.append("Par \(par)") }
            if let meters = hole.effectiveLengthMeters {
                parts.append(ShotYardage.distanceLabel(meters: meters, metric: metric))
            }
            return parts.isEmpty ? "Hole" : parts.joined(separator: " · ")
        }

        private struct ShotSegment {
            let shotNumber: Int
            let from: CLLocationCoordinate2D
            let to: CLLocationCoordinate2D
            let midpoint: CLLocationCoordinate2D
            let meters: Double
            /// Apex height in metres, from the shot's generated measurement.
            let apexHeight_m: Double
            /// Lateral shape in metres (signed), from the shot's measurement.
            let sideCurve_m: Double
        }

        /// Creates one segment per recorded shot. Shot 1 starts at the hole tee
        /// when available, then each following shot starts at the prior shot.
        private func shotSegments(shots: [Shot], currentHole: OSMHole?) -> [ShotSegment] {
            var segments: [ShotSegment] = []
            var previous: CLLocationCoordinate2D?
            if let tee = currentHole?.coordinates.first {
                previous = CLLocationCoordinate2D(latitude: tee.lat, longitude: tee.lon)
            }

            for (index, shot) in shots.enumerated() {
                guard let from = previous else {
                    previous = shot.coordinate
                    continue
                }
                let meters = distanceMeters(from: from, to: shot.coordinate)
                let midpoint = CLLocationCoordinate2D(
                    latitude: (from.latitude + shot.coordinate.latitude) / 2,
                    longitude: (from.longitude + shot.coordinate.longitude) / 2
                )
                segments.append(ShotSegment(
                    shotNumber: index + 1,
                    from: from,
                    to: shot.coordinate,
                    midpoint: midpoint,
                    meters: meters,
                    apexHeight_m: shot.apexHeight_m,
                    sideCurve_m: shot.sideCurve_m
                ))
                previous = shot.coordinate
            }
            return segments
        }

        private func distanceMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        }

        private func pillSizeForYardage(_ text: String) -> CGSize {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
            let textSize = text.size(withAttributes: attrs)
            return CGSize(width: max(34, ceil(textSize.width) + 14), height: 20)
        }

        /// Renders a hole's "Par 4 · 410y" label the way MapKit's native marker
        /// title looked — white text with a soft dark shadow for legibility over
        /// imagery, no pill — so the whole-view `alphaValue` can dim it in step with
        /// the hole's markers. Padding leaves room for the shadow blur.
        private func holeTitleLabelImage(_ text: String) -> NSImage {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
                .shadow: shadow
            ]
            let textSize = text.size(withAttributes: attrs)
            let pad: CGFloat = 6
            let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad * 2)
            return NSImage(size: size, flipped: false) { rect in
                text.draw(in: rect.insetBy(dx: pad, dy: pad), withAttributes: attrs)
                return true
            }
        }

        // MARK: Region

        private func applyFraming(map: MKMapView, framingRequest: MapFramingRequest?, courseIsOpen: Bool) {
            guard let request = framingRequest, request.id != appliedRegionID else { return }
            appliedRegionID = request.id
            // Animate only short hops; a long cross-country jump animated would make
            // MapKit stream imagery along the whole flight path and stall (leaving the
            // base map blank while overlays float).
            let from = map.camera.centerCoordinate
            let to: CLLocationCoordinate2D
            switch request.framing {
            case let .topDown(region): to = region.center
            case let .camera(center, _, _, _): to = center
            }
            let jump = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            let animated = jump < 5_000
            // Mark this as our own move so the ensuing regionDidChange isn't
            // mistaken for a user pan/zoom (which would pop the "Search here" button).
            isApplyingRegion = true
            switch request.framing {
            case let .topDown(region):
                // Clear any constraints left over from a previously-open course
                // BEFORE framing. Switching straight from course A to course B never
                // passes through the `displayedCourse == nil` cleanup, so A's pan
                // boundary/zoom ceiling would otherwise still be active here and
                // MapKit would clamp this `setRegion` back toward A's footprint —
                // landing the map near the previously-selected course.
                if courseCameraBoundaryApplied {
                    map.setCameraBoundary(nil, animated: false)
                    courseCameraBoundaryApplied = false
                }
                if courseZoomCeilingApplied {
                    map.setCameraZoomRange(nil, animated: false)
                    courseZoomCeilingApplied = false
                }
                // Draw the full-course overview straight at its final framing rather
                // than animating a zoom-in to it — the pull-back/zoom read as awkward.
                map.setRegion(region, animated: false)
                if courseIsOpen {
                    // Cap how far out the user can zoom while a course is open: 1.5× the
                    // distance MapKit chose for this footprint framing. This leaves a
                    // little breathing room for context without letting the map zoom
                    // past the course out into the wider world. Read from the camera
                    // *after* `setRegion` so it reflects the just-applied footprint.
                    let ceiling = map.camera.centerCoordinateDistance * 1.5
                    map.setCameraZoomRange(
                        MKMapView.CameraZoomRange(maxCenterCoordinateDistance: ceiling),
                        animated: false
                    )
                    courseZoomCeilingApplied = true
                    // Lock panning to the course footprint. The boundary constrains
                    // the camera's *center* to this region, so the user can nudge to
                    // the edges for context but can't pan the course off-screen out
                    // into the surrounding world. Widen the framing region slightly
                    // so the boundary allows the full footprint to be centered even
                    // after the little zoom-out headroom above.
                    let bounded = MKCoordinateRegion(
                        center: region.center,
                        span: MKCoordinateSpan(
                            latitudeDelta: region.span.latitudeDelta * 1.5,
                            longitudeDelta: region.span.longitudeDelta * 1.5
                        )
                    )
                    if let boundary = MKMapView.CameraBoundary(coordinateRegion: bounded) {
                        map.setCameraBoundary(boundary, animated: false)
                        courseCameraBoundaryApplied = true
                    }
                }
            case let .camera(center, distance, pitch, heading):
                // `fromDistance` is centerCoordinateDistance (camera→look-at point),
                // NOT altitude — passing an altitude here would snap the camera far
                // closer than intended.
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: distance,
                    pitch: pitch,
                    heading: heading
                )
                if animated {
                    // MapKit's default `setCamera(animated:)` duration is quite
                    // brisk; wrapping the call in an explicit `NSAnimationContext`
                    // makes MapKit adopt that duration, so the hole-to-hole glide is
                    // slower and easier to follow. `allowsImplicitAnimation` lets the
                    // camera change ride the context's timing.
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Self.holeCameraDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        ctx.allowsImplicitAnimation = true
                        map.setCamera(camera, animated: true)
                    }
                } else {
                    map.setCamera(camera, animated: false)
                }
            }
        }

        /// How long the tilted per-hole camera glide takes, in seconds. Bumped well
        /// above MapKit's brisk default so moving between holes reads as a smooth
        /// fly-over rather than a snap.
        private static let holeCameraDuration: TimeInterval = 1.6
    }
}
