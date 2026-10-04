// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct OverviewSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingUpdate: Task<Void, Never>?
    @State private var mouseButtonError: String?

    var body: some View {
        let hotkeyMouseButtons = OverviewInputSettingsValidation.hotkeyMouseButtons(settings.hotkeyBindings)
        Form {
            Section("Overview") {
                Toggle("Enable Overview", isOn: Binding(
                    get: { settings.overview.enabled },
                    set: { controller.setOverviewEnabled($0) }
                ))
            }

            Section("Layout") {
                SettingsSliderRow(
                    label: String(localized: "Zoom"),
                    value: Bindable(settings.overview).zoom,
                    range: 0.5 ... 1.5,
                    step: 0.05,
                    valueText: "\(Int((settings.overview.zoom * 100).rounded()))%"
                )
                .onChange(of: settings.overview.zoom) { _, _ in
                    scheduleUpdate()
                }
                SettingsCaption(localized: "Zoom changes made in Overview are remembered when it closes.")
            }
            .disabled(!settings.overview.enabled)

            Section("Input") {
                Toggle("Invert Scrolling Direction", isOn: Bindable(settings.overview).invertScrollDirection)
                SettingsSliderRow(
                    label: String(localized: "Mouse Wheel Speed"),
                    value: Bindable(settings.overview).mouseScrollSpeed,
                    range: 0.05 ... 2,
                    step: 0.05,
                    valueText: "\(Int((settings.overview.mouseScrollSpeed * 100).rounded()))%"
                )
                SettingsCaption(localized: "Adjusts mouse wheels. Trackpad scrolling keeps its normal speed.")
                Picker("Toggle Overview Mouse Button", selection: Binding(
                    get: { settings.overview.mouseButton },
                    set: { button in
                        do {
                            try settings.setOverviewMouseButton(button)
                            mouseButtonError = nil
                        } catch {
                            mouseButtonError = error.localizedDescription
                        }
                    }
                )) {
                    Text("Unassigned").tag(nil as Int64?)
                    ForEach(Array(OverviewInputSettingsValidation.mouseButtons), id: \.self) { button in
                        Text(OverviewInputSettingsValidation.buttonLabel(button)).tag(Optional(button))
                            .disabled(
                                settings.systemHyperTrigger.mouseButtonNumber == button
                                    || hotkeyMouseButtons.contains(button)
                            )
                    }
                }
                SettingsCaption(
                    localized: "Press to open or close Overview. Buttons assigned to System Hyper or a hotkey are unavailable."
                )
                if let mouseButtonError {
                    SettingsCaption(mouseButtonError)
                }
            }
            .disabled(!settings.overview.enabled)

            Section("Appearance") {
                ColorPicker(
                    "Backdrop Color",
                    selection: colorBinding(\.backdropColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Normal Window Border",
                    selection: colorBinding(\.normalBorderColor),
                    supportsOpacity: true
                )
                ColorPicker(
                    "Hovered Window Border",
                    selection: colorBinding(\.hoveredBorderColor),
                    supportsOpacity: true
                )
                Toggle("Selected Border Matches Focus Border", isOn: Bindable(settings.overview).matchFocusBorder)
                    .onChange(of: settings.overview.matchFocusBorder) { _, _ in
                        scheduleUpdate()
                    }
                ColorPicker(
                    "Selected Window Border",
                    selection: colorBinding(\.selectedBorderColor),
                    supportsOpacity: true
                )
                .disabled(settings.overview.matchFocusBorder)
            }
            .disabled(!settings.overview.enabled)
        }
        .formStyle(.grouped)
    }

    private func colorBinding(_ keyPath: ReferenceWritableKeyPath<OverviewSettings, SettingsColor>) -> Binding<Color> {
        Binding(
            get: { [settings] in settings.overview[keyPath: keyPath].swiftUIColor },
            set: { color in
                guard let converted = SettingsColor(color: color) else { return }
                settings.overview[keyPath: keyPath] = converted
                scheduleUpdate()
            }
        )
    }

    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controller.updateOverviewSettings()
        }
    }
}
