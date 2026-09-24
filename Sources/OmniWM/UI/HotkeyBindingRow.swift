// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import SwiftUI

enum HotkeyRecordingTarget: Equatable {
    case chord(String)
}

struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    @Binding var recordingTarget: HotkeyRecordingTarget?
    let failureReason: HotkeyRegistrationFailureReason?
    let isHyperActive: () -> Bool
    let onStartChordRecording: (String) -> Void
    let onChordCaptured: (String, KeyBinding) -> Void
    let onCancelRecording: () -> Void
    let onClearBinding: (String) -> Void
    let onResetBindings: (String) -> Void
    let onSetSide: (String, ModifierSide) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let failureReason {
                    Label("Registration issue", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(failureMessage(for: failureReason))
                        .accessibilityLabel("Registration issue")
                        .accessibilityValue(failureMessage(for: failureReason))
                }

                HotkeyBindingControl(
                    binding: binding.binding,
                    commandName: binding.command.localizedDisplayName,
                    isRecordingChord: recordingTarget == .chord(binding.id),
                    isHyperActive: isHyperActive,
                    onStartChordRecording: {
                        onStartChordRecording(binding.id)
                    },
                    onCaptured: { newBinding in
                        onChordCaptured(binding.id, newBinding)
                    },
                    onCancel: {
                        onCancelRecording()
                    },
                    onRemove: {
                        onClearBinding(binding.id)
                    },
                    onSetSide: { side in
                        onSetSide(binding.id, side)
                    }
                )

                ResetIconButton(title: String(localized: "Reset \(binding.command.localizedDisplayName) to default")) {
                    recordingTarget = nil
                    onResetBindings(binding.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(binding.command.localizedDisplayName)
                    .font(.body)

                HStack(spacing: 6) {
                    HotkeyScopeText(compatibility: binding.command.layoutCompatibility)

                    if let failureReason {
                        Text(failureMessage(for: failureReason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityValue(accessibilityValue)
        .onDisappear {
            guard recordingTarget == .chord(binding.id) else { return }
            onCancelRecording()
        }
    }

    private var accessibilityValue: String {
        var parts = [
            String(localized: "Shortcut \(HotkeySettingsDisplayModel.humanReadableString(for: binding.binding))"),
            String(localized: "Scope \(binding.command.layoutCompatibility.localizedDisplayName)")
        ]
        if let failureReason {
            parts.append(failureMessage(for: failureReason))
        }
        return parts.joined(separator: ", ")
    }

    private func failureMessage(for reason: HotkeyRegistrationFailureReason) -> String {
        switch reason {
        case .duplicateBinding:
            return String(
                localized: "Failed to register: this key combination is already assigned to another OmniWM command"
            )
        case .systemReserved:
            return String(localized: "Failed to register: this key combination may be reserved by the system")
        case .requiresInputMonitoring:
            return String(localized: "Left/Right-specific shortcuts need Input Monitoring permission to work")
        }
    }
}

private struct HotkeyScopeText: View {
    let compatibility: LayoutCompatibility

    var body: some View {
        Text("Scope: \(compatibility.localizedDisplayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct HotkeyBindingControl: View {
    let binding: HotkeyTrigger
    let commandName: String
    let isRecordingChord: Bool
    let isHyperActive: () -> Bool
    let onStartChordRecording: () -> Void
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onSetSide: (ModifierSide) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRecordingChord {
                KeyRecorderView(
                    accessibilityLabel: String(localized: "Recording hotkey for \(commandName)"),
                    isHyperActive: isHyperActive,
                    onCapture: onCaptured,
                    onCancel: onCancel
                )
                .frame(minWidth: 180, idealWidth: 210, minHeight: 34)
                .accessibilityHint("Press Escape to cancel recording")
            } else {
                HStack(spacing: 6) {
                    Button {
                        onStartChordRecording()
                    } label: {
                        Text(displayString)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .frame(minWidth: 112, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .help(
                        String(localized: "Change hotkey for \(commandName). Current shortcut: \(humanReadableString)")
                    )
                    .accessibilityLabel(String(localized: "Change hotkey for \(commandName)"))
                    .accessibilityValue(humanReadableString)
                }

                if !binding.isUnassigned {
                    Button {
                        onRemove()
                    } label: {
                        Label(String(localized: "Clear hotkey for \(commandName)"), systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this hotkey")
                    .accessibilityLabel(String(localized: "Clear hotkey for \(commandName)"))
                }

                if let chord = binding.chordBinding, chord.modifiers != 0 {
                    Picker(
                        "Modifier side",
                        selection: Binding(get: { chord.side }, set: { onSetSide($0) })
                    ) {
                        Text("Either").tag(ModifierSide.either)
                        Text("Left").tag(ModifierSide.left)
                        Text("Right").tag(ModifierSide.right)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Restrict this shortcut to the left or right side of its modifier keys")
                    .accessibilityLabel(String(localized: "Modifier side for \(commandName)"))
                    .accessibilityValue(sideAccessibilityValue(chord.side))
                }
            }
        }
    }

    private func sideAccessibilityValue(_ side: ModifierSide) -> String {
        switch side {
        case .either: String(localized: "Either side")
        case .left: String(localized: "Left side")
        case .right: String(localized: "Right side")
        }
    }

    private var displayString: String {
        HotkeySettingsDisplayModel.displayString(for: binding)
    }

    private var humanReadableString: String {
        HotkeySettingsDisplayModel.humanReadableString(for: binding)
    }
}
