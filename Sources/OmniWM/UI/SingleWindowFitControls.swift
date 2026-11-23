// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SingleWindowFitControls: View {
    let label: String
    let field: SettingsFieldID
    var row: String?
    let fit: SingleWindowFit
    let modes: [SingleWindowFit.Mode]
    var isOverridden: Bool = false
    let onChange: (SingleWindowFit) -> Void
    var onReset: (() -> Void)?

    var body: some View {
        marked(modePicker)
        if fit.mode == .custom { marked(sizeEditor) }
    }

    @ViewBuilder
    private func marked(_ control: some View) -> some View {
        if field == .monitorNiriOverrides || field == .monitorDwindleOverrides {
            control.settingsField(field, row: row, leaf: "singleWindowFit")
        } else {
            control.settingsField(field)
        }
    }

    private var modePicker: some View {
        LabeledContent(label) {
            HStack {
                Picker(label, selection: Binding(
                    get: { fit.mode },
                    set: { onChange(SingleWindowFit(mode: $0, width: fit.width, height: fit.height)) }
                )) {
                    ForEach(modes) { mode in
                        Text(mode.localizedDisplayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(label)

                if let onReset {
                    OverrideStatus(label: label, isOverridden: isOverridden, onReset: onReset)
                }
            }
        }
    }

    private var sizeEditor: some View {
        LabeledContent("Window Size") {
            HStack(spacing: 6) {
                TextField("Width", value: Binding(
                    get: { fit.width },
                    set: { onChange(SingleWindowFit(mode: .custom, width: $0, height: fit.height)) }
                ), format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("\(label) width")

                Text("×").foregroundStyle(.secondary)

                TextField("Height", value: Binding(
                    get: { fit.height },
                    set: { onChange(SingleWindowFit(mode: .custom, width: fit.width, height: $0)) }
                ), format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("\(label) height")

                Text("pt").foregroundStyle(.secondary)
            }
        }
    }
}
