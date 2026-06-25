//
//  OverlaySettingsView.swift
//  caddie
//

import SwiftUI

/// The Overlay Settings window (⌘,). Lets the user recolor and show/hide every
/// map overlay layer. Bound to the shared `OverlaySettings` from the environment.
struct OverlaySettingsView: View {
    @Environment(OverlaySettings.self) private var settings

    var body: some View {
        Form {
            Section {
                ForEach(OverlayLayer.structureLayers) { overlayRow($0) }
            } header: {
                Text("Course Structure")
            } footer: {
                Text("Boundary outline, hole centerlines, and trees.")
            }

            Section("Course Features") {
                ForEach(OverlayLayer.featureLayers) { overlayRow($0) }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.resetToDefaults()
                }
            } footer: {
                Text("Hidden layers are still fetched and cached — they're just not drawn.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }

    /// A single layer row: leading color well, the layer name, and a trailing
    /// visibility switch.
    private func overlayRow(_ layer: OverlayLayer) -> some View {
        HStack(spacing: 12) {
            ColorPicker(selection: settings.colorBinding(for: layer), supportsOpacity: true) {
                EmptyView()
            }
            .labelsHidden()

            Toggle(layer.title, isOn: settings.visibilityBinding(for: layer))
                .toggleStyle(.switch)
        }
    }
}

#Preview {
    OverlaySettingsView()
        .environment(OverlaySettings())
}
