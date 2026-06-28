//
//  PlayDetailPane.swift
//  caddie
//
//  Created by Jeff Roberts on 6/28/26.
//

import SwiftUI

struct PlayDetailPane: View {
    let holes: [OSMHole]
    @Binding var currentHoleIndex: Int

    private var currentHole: OSMHole? {
        guard holes.indices.contains(currentHoleIndex) else { return nil }
        return holes[currentHoleIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Hole navigation header ──────────────────────────────────────
            HStack {
                Button {
                    if currentHoleIndex > 0 { currentHoleIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .disabled(currentHoleIndex == 0 || holes.isEmpty)

                Spacer()

                Text(holeTitle)
                    .font(.title2.bold())

                Spacer()

                Button {
                    if currentHoleIndex < holes.count - 1 { currentHoleIndex += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .disabled(currentHoleIndex >= holes.count - 1 || holes.isEmpty)
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
    }

    // MARK: - Subviews

    private var holeTitle: String {
        guard !holes.isEmpty else { return "No Holes" }
        if let ref = currentHole?.ref, !ref.isEmpty {
            return "Hole \(ref)"
        }
        return "Hole \(currentHoleIndex + 1)"
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
