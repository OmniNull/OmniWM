// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellSettingsOptionRow: View {
    let key: String
    let option: ShellComponentOption
    let value: ShellComponentValue?
    let write: (ShellComponentValue) -> Void
    @Environment(\.locale) private var locale

    private var title: String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue(option.title), table: ShellLocalizer.table,
            locale: locale, bundle: .atURL(Bundle.module.bundleURL)
        ))
    }

    private var resolved: ShellComponentValue? {
        value ?? option.defaultValue
    }

    var body: some View {
        switch option.kind {
        case .boolean:
            Toggle(title, isOn: Binding(
                get: { if case let .bool(value)? = resolved { value } else { false } },
                set: { write(.bool($0)) }
            ))
        case .choice:
            Picker(title, selection: Binding(
                get: { if case let .string(value)? = resolved { value } else { "" } },
                set: { write(.string($0)) }
            )) {
                ForEach(option.choices, id: \.self) { choice in
                    Text(ShellWidgetSettingsModel.title(choice)).tag(choice)
                }
            }
        case .number:
            numberRow
        case .string:
            if key.lowercased().hasSuffix("color") {
                colorRow
            } else {
                ShellTextOptionRow(
                    title: title, value: stringValue, maximum: option.maxLength,
                    write: { write(.string($0)) }
                )
            }
        case .strings:
            ShellTextOptionRow(
                title: title,
                value: { if case let .strings(values)? = resolved { values.joined(separator: "\n") } else { "" } }(),
                maximum: option.maxLength * 256, multiline: true,
                write: { write(.strings($0.split(separator: "\n").map(String.init))) }
            )
        }
    }

    private var stringValue: String {
        if case let .string(value)? = resolved { value } else { "" }
    }

    private var numberValue: Double {
        if case let .number(value)? = resolved { value } else { option.minimum ?? 0 }
    }

    @ViewBuilder private var numberRow: some View {
        if let minimum = option.minimum, let maximum = option.maximum, minimum < maximum {
            SettingsSliderRow(
                label: title,
                value: Binding(get: { numberValue }, set: { write(.number($0)) }),
                range: minimum ... maximum, step: option.step ?? 1,
                valueText: numberValue.formatted(.number.precision(.fractionLength(0 ... 2)))
            )
        } else {
            LabeledContent(title) {
                TextField(title, value: Binding(
                    get: { numberValue }, set: { if option.accepts(.number($0)) { write(.number($0)) } }
                ), format: .number)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var colorRow: some View {
        ColorPicker(title, selection: Binding(
            get: {
                guard let color = ShellWidgetSettingsModel.rgba(stringValue) else { return .black }
                return Color(red: color.x, green: color.y, blue: color.z, opacity: color.w)
            },
            set: { color in
                guard let color = SettingsColor(color: color) else { return }
                let rgba = [color.red, color.green, color.blue, color.alpha].map { Int(($0 * 255).rounded()) }
                write(.string("#" + rgba.map { String(format: "%02x", $0) }.joined()))
            }
        ), supportsOpacity: true)
    }
}

struct ShellTextOptionRow: View {
    let title: String
    let value: String
    let maximum: Int
    var multiline = false
    let write: (String) -> Void
    @State private var draft: String

    init(title: String, value: String, maximum: Int, multiline: Bool = false, write: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.maximum = maximum
        self.multiline = multiline
        self.write = write
        _draft = State(initialValue: value)
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                TextField(title, text: $draft, axis: multiline ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(multiline ? 3 ... 8 : 1 ... 1)
                    .onSubmit(save)
                if draft != value {
                    HStack {
                        Button("Cancel") { draft = value }
                        Button("Apply", action: save).disabled(draft.count > maximum)
                    }
                    if draft.count > maximum {
                        Text("Use at most \(maximum) characters.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(minWidth: 140, maxWidth: 300)
        }
        .onChange(of: value) { _, next in draft = next }
    }

    private func save() {
        guard draft.count <= maximum, draft != value else { return }
        write(draft)
    }
}
