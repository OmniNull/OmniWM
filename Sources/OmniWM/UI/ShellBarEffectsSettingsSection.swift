// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellBarEffectsSettingsSection: View {
    let configuration: ShellConfigurationCoordinator
    @State private var editError: String?

    private var matrix: Bool {
        configuration.config.barShader?.source == "matrix-rain.metal" || configuration.config.profile == "matrix"
    }

    private var supported: Bool {
        if let shader = configuration.config.barShader {
            ["matrix-rain.metal", "sakura-petals.metal"].contains(shader.source)
        } else {
            ["matrix", "sakura"].contains(configuration.config.profile)
        }
    }

    var body: some View {
        if supported {
            Section(matrix ? String(localized: "Matrix Rain") : String(localized: "Sakura Petals")) {
                Toggle("Enable Background Effect", isOn: Binding(
                    get: { configuration.config.barShader != nil },
                    set: { enabled in
                        perform { try await configuration.set(enabled, key: "enabled", table: "barShader") }
                    }
                ))
                if let shader = configuration.config.barShader {
                    parameter("Intensity", index: 0, range: 0 ... 1, step: 0.05, shader: shader)
                    parameter("Motion Speed", index: 1, range: 0 ... 4, step: 0.1, shader: shader)
                    parameter(
                        matrix ? String(localized: "Character Size") : String(localized: "Petal Size"),
                        index: 2,
                        range: matrix ? 6 ... 40 : 4 ... 24,
                        step: 1,
                        shader: shader
                    )
                    parameter(
                        matrix ? String(localized: "Sweep Glow") : String(localized: "Animation Phase"),
                        index: 3,
                        range: matrix ? 0 ... 1 : 0 ... 60,
                        step: matrix ? 0.05 : 1,
                        shader: shader
                    )
                    SettingsSliderRow(
                        label: String(localized: "Frame Rate"),
                        value: Binding(get: { Double(shader.fps) }, set: { fps in
                            perform { try await configuration.set(Int(fps), key: "fps", table: "barShader") }
                        }),
                        range: 0 ... 60, step: 1,
                        valueText: shader.fps == 0 ? String(localized: "Still") : String(localized: "\(shader.fps) fps")
                    )
                    SettingsCaption(
                        localized: "Lower frame rates reduce effect rendering. Zero keeps a still background."
                    )
                }
                Button("Reset Effect to Style Defaults") {
                    perform { try await configuration.reset(table: "barShader") }
                }
            }
            .shellSettingsError($editError)
        }
    }

    private func parameter(
        _ title: String,
        index: Int,
        range: ClosedRange<Double>,
        step: Double,
        shader: ShellBarShader
    ) -> some View {
        SettingsSliderRow(
            label: title,
            value: Binding(get: { Double(shader.values[index]) }, set: { next in
                var values = (0 ..< 4).map { Double(shader.values[$0]) }
                values[index] = next
                perform { try await configuration.set(values, key: "values", table: "barShader") }
            }),
            range: range, step: step,
            valueText: Double(shader.values[index]).formatted(.number.precision(.fractionLength(0 ... 2)))
        )
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { editError = error.localizedDescription } }
    }
}
