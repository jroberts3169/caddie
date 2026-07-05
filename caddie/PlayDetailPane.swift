//
//  PlayDetailPane.swift
//  caddie
//
//  Created by Jeff Roberts on 6/28/26.
//

import CoreLocation
import SwiftUI

struct PlayDetailPane: View {
    let holes: [OSMHole]
    @Binding var currentHoleIndex: Int
    let shots: [Shot]
    let onClearShots: () -> Void
    let onUndoShot: () -> Void

    private var currentHole: OSMHole? {
        guard holes.indices.contains(currentHoleIndex) else { return nil }
        return holes[currentHoleIndex]
    }

    /// Yardage for each shot, parallel to `shots`. Shot 1 is measured from the
    /// hole tee (the hole's first coordinate) when available; every later shot is
    /// measured from the previous shot. `nil` when there's no reference point yet
    /// (e.g. shot 1 on a hole with no tee geometry). Mirrors the segment logic the
    /// map uses to draw yardage pills so the two always agree.
    private var shotYards: [Int?] {
        let tee = currentHole?.coordinates.first.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        return ShotYardage.yards(tee: tee, shots: shots.map(\.coordinate))
    }

    /// Whether there's an earlier/later hole to move to. Drives both the
    /// header chevrons and the arrow-key shortcuts.
    private var canGoToPreviousHole: Bool {
        !holes.isEmpty && currentHoleIndex > 0
    }

    private var canGoToNextHole: Bool {
        !holes.isEmpty && currentHoleIndex < holes.count - 1
    }

    private func goToPreviousHole() {
        if canGoToPreviousHole { currentHoleIndex -= 1 }
    }

    private func goToNextHole() {
        if canGoToNextHole { currentHoleIndex += 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Hole navigation header ──────────────────────────────────────
            HStack {
                Button(action: goToPreviousHole) {
                    Image(systemName: "chevron.left")
                        .imageScale(.large)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoToPreviousHole)
                .accessibilityIdentifier("holePrevButton")

                Spacer()

                holeTitleMenu

                Spacer()

                Button(action: goToNextHole) {
                    Image(systemName: "chevron.right")
                        .imageScale(.large)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoToNextHole)
                .accessibilityIdentifier("holeNextButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Hole stats ──────────────────────────────────────────────────
            if let hole = currentHole {
                VStack(spacing: 20) {
                    statRow(label: "Par", value: hole.par.map { "\($0)" } ?? "—")
                    if let meters = hole.lengthMeters {
                        statRow(label: "Yards", value: "\(Int((meters * 1.09361).rounded()))")
                        statRow(label: "Meters", value: "\(Int(meters.rounded()))")
                    }
                }
                .padding(20)

                Divider()

                shotsSection
            } else {
                ContentUnavailableView(
                    "No Hole Data",
                    systemImage: "flag.slash",
                    description: Text("Hole information isn't available for this course yet.")
                )
                .padding()
            }

            Spacer()
        }
        .inspectorColumnWidth(min: 220, ideal: 260, max: 320)
        .background {
            // Hidden ⌘Z handler: undoes the last recorded shot on the focused hole.
            Button("Undo Shot", action: onUndoShot)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(shots.isEmpty)
                .hidden()
        }
        .background {
            // Hidden ←/→ handlers: step to the previous/next hole in Play mode.
            Button("Previous Hole", action: goToPreviousHole)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!canGoToPreviousHole)
                .hidden()
            Button("Next Hole", action: goToNextHole)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!canGoToNextHole)
                .hidden()
        }
    }

    // MARK: - Shots

    private var shotsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shots")
                    .font(.headline)
                Spacer()
                Text("\(shots.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if shots.isEmpty {
                Text("Click the map to record a shot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        let yards = shotYards
                        ForEach(Array(shots.enumerated()), id: \.element.id) { index, _ in
                            HStack {
                                Image(systemName: "\(index + 1).circle.fill")
                                    .foregroundStyle(.orange)
                                Text("Shot \(index + 1)")
                                Spacer()
                                if let yardage = yards[index] {
                                    Text("\(yardage) yd")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 220)

                Button(role: .destructive) {
                    onClearShots()
                } label: {
                    Label("Clear All Shots", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("clearShotsButton")
            }
        }
    }

    // MARK: - Subviews

    private var holeTitleMenu: some View {
        Menu {
            ForEach(Array(holes.enumerated()), id: \.offset) { index, hole in
                Button {
                    currentHoleIndex = index
                } label: {
                    if index == currentHoleIndex {
                        Label(holeMenuTitle(for: hole, at: index), systemImage: "checkmark")
                    } else {
                        Text(holeMenuTitle(for: hole, at: index))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(holeTitle)
                    .font(.title2.bold())
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(holes.isEmpty)
        .accessibilityIdentifier("holeTitleMenu")
    }

    private var holeTitle: String {
        guard !holes.isEmpty else { return "No Holes" }
        if let number = currentHole?.holeNumber {
            return "Hole \(number)"
        }
        if let ref = currentHole?.ref, !ref.isEmpty {
            return "Hole \(ref)"
        }
        return "Hole \(currentHoleIndex + 1)"
    }

    private func holeMenuTitle(for hole: OSMHole, at index: Int) -> String {
        if let number = hole.holeNumber {
            return "Hole \(number)"
        }
        if let ref = hole.ref, !ref.isEmpty {
            return "Hole \(ref)"
        }
        return "Hole \(index + 1)"
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.body)
    }
}
