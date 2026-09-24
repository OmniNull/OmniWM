// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Accessibility
import AppKit
import SwiftUI

struct AppWindowCornerSettings: View {
    @Bindable var preferences: GlobalWindowCornerPreferences

    private enum Selection: Hashable {
        case systemDefault
        case custom
    }

    var body: some View {
        if hasExternalConfiguration {
            externalConfigurationEditor
        } else {
            Picker("System-wide Window Corners", selection: selectionBinding) {
                Text("macOS Default").tag(Selection.systemDefault)
                Text("Custom").tag(Selection.custom)
            }
            .disabled(!preferences.isSupported || preferences.isManaged)

            if selection == .custom {
                cornerEditor(commitsChanges: true)
            }
        }

        statusContent

        SettingsCaption(
            localized: "Changes standard Mac app windows system-wide, including windows OmniWM doesn’t manage. Apps that draw their own window chrome may ignore it."
        )
        SettingsCaption(localized: "Changes take effect after each affected app is fully quit and reopened.")
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                preferences.refresh()
            }
            .onDisappear {
                preferences.cancelSliderEditing()
            }
            .onChange(of: preferences.errorMessage) { _, message in
                guard let message else { return }
                AccessibilityNotification.Announcement(message).post()
            }
    }

    private var selection: Selection {
        switch preferences.state {
        case .systemDefault:
            .systemDefault
        case .custom:
            .custom
        case .mixed,
             .malformed,
             .outOfRange:
            .custom
        }
    }

    private var selectionBinding: Binding<Selection> {
        Binding(
            get: { selection },
            set: { selection in
                switch selection {
                case .systemDefault:
                    preferences.chooseSystemDefault()
                case .custom:
                    preferences.chooseCustom()
                }
            }
        )
    }

    private var radiusText: String {
        AppWindowCornerRadiusFormatting.string(for: preferences.draftRadius)
    }

    private var hasExternalConfiguration: Bool {
        switch preferences.state {
        case .mixed,
             .malformed,
             .outOfRange:
            true
        case .systemDefault,
             .custom:
            false
        }
    }

    private var externalConfigurationEditor: some View {
        Group {
            LabeledContent("System-wide Window Corners") {
                Text("Existing macOS Configuration")
                    .foregroundStyle(.secondary)
            }

            Text(externalConfigurationReason)
                .font(.caption)
                .foregroundStyle(.orange)

            cornerEditor(commitsChanges: false)

            HStack {
                Button("Use macOS Default") {
                    preferences.chooseSystemDefault()
                }
                Button("Apply Custom") {
                    preferences.chooseCustom()
                }
            }
            .disabled(!preferences.isSupported || preferences.isManaged)
        }
    }

    private var externalConfigurationReason: String {
        switch preferences.state {
        case .mixed:
            String(localized: "The two macOS corner preferences do not match.")
        case .malformed:
            String(localized: "A macOS corner preference has an invalid value.")
        case .outOfRange:
            String(localized: "The existing macOS corner value is outside OmniWM’s supported range.")
        case .systemDefault,
             .custom:
            ""
        }
    }

    private func cornerEditor(commitsChanges: Bool) -> some View {
        Group {
            LabeledContent("Preview") {
                AppWindowCornerPreview(radius: preferences.draftRadius)
            }

            LabeledContent("Corner Radius") {
                HStack {
                    Slider(
                        value: radiusBinding(commitsChanges: commitsChanges),
                        in: GlobalWindowCornerPreferences.radiusRange,
                        step: 0.5,
                        onEditingChanged: { editing in
                            if editing {
                                preferences.beginSliderEditing()
                            } else if commitsChanges {
                                preferences.endSliderEditing()
                            } else {
                                preferences.cancelSliderEditing()
                            }
                        },
                        label: {
                            Text("Corner Radius")
                        }
                    )
                    .labelsHidden()
                    .accessibilityLabel("System-wide window corner radius")
                    .accessibilityValue(radiusText)
                    .accessibilityHint(
                        "Changes standard Mac app windows system-wide. Fully quit and reopen affected apps to apply."
                    )

                    SettingsValueText(text: radiusText, width: 72)
                }
            }
            .disabled(!preferences.isSupported || preferences.isManaged)
        }
    }

    private func radiusBinding(commitsChanges: Bool) -> Binding<Double> {
        Binding(
            get: { preferences.draftRadius },
            set: { radius in
                if commitsChanges {
                    preferences.sliderValueChanged(radius)
                } else {
                    preferences.updateDraftRadius(radius)
                }
            }
        )
    }

    @ViewBuilder
    private var statusContent: some View {
        if !preferences.isSupported {
            Text("App window corner controls require macOS 26.4 or later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if preferences.isManaged {
            Label("This setting is managed by your organization.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let errorMessage = preferences.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let successMessage = preferences.successMessage {
            Label(successMessage, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

enum AppWindowCornerRadiusFormatting {
    static func string(for radius: Double) -> String {
        guard radius != 0 else { return String(localized: "Square") }
        let formattedRadius = radius.formatted(.number.precision(.significantDigits(1 ... 6)))
        return String(localized: "\(formattedRadius) pt")
    }
}

private struct AppWindowCornerPreview: View {
    let radius: Double

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.background)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
            .frame(width: 180, height: 140)
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .padding(10)
            .accessibilityHidden(true)
    }
}
