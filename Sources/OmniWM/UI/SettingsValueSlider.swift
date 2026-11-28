// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SettingsSliderDraft {
    private var initial: Double?
    private(set) var value: Double?

    mutating func begin(at current: Double) {
        guard initial == nil else { return }
        initial = current
        value = current
    }

    mutating func update(_ next: Double) -> Bool {
        guard initial != nil else { return false }
        value = next
        return true
    }

    mutating func finish(at current: Double) -> Double? {
        defer { self = Self() }
        guard current == initial, current != value else { return nil }
        return value
    }
}

struct SettingsValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    let width: CGFloat
    var formatDraft: ((Double) -> String)?
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @State private var draft = SettingsSliderDraft()

    var body: some View {
        let text = draft.value.map { formatDraft?($0) ?? $0.formatted() } ?? valueText
        Slider(value: Binding(
            get: { draft.value ?? value },
            set: { next in
                if !draft.update(next) { value = next }
            }
        ), in: range, step: step, onEditingChanged: { editing in
            if editing {
                if settings?.fieldSources.document?.hasFormulas == true { draft.begin(at: value) }
            } else if let next = draft.finish(at: value) {
                value = next
            }
        }, label: {
            Text(label)
        })
        .labelsHidden()
        .accessibilityLabel(label)
        .accessibilityValue(text)

        SettingsValueText(text: text, width: width)
    }
}
