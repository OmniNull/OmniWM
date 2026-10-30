// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct UndoResizeHotkeyRow: View {
    static let actionId = "undoResize"

    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingTarget: HotkeyRecordingTarget?
    @State private var conflictAlert: ConflictAlert?
    @State private var captureRejection: String?

    var body: some View {
        if let binding = settings.hotkeyBindings.first(where: { $0.id == Self.actionId }) {
            HotkeyBindingRow(
                binding: binding,
                recordingTarget: $recordingTarget,
                failureReason: controller.hotkeyRegistrationFailures[binding.command],
                modeKeyFailure: nil,
                showsModeKey: false,
                pausedDuringSecureInput: SecureInputShortcutRisk.isPaused(
                    binding.binding,
                    hyperTriggerConfigured: settings.systemHyperTrigger != .none,
                    hyperModifiers: settings.hyperKeyModifiers.carbonMask,
                    shiftedCharacters: SecureInputShortcutRisk.currentLayoutShiftedCharacters()
                ),
                isHyperActive: { controller.isHyperTriggerActive },
                onStartChordRecording: { recordingTarget = .chord($0) },
                onChordCaptured: handleChordCaptured,
                onCancelRecording: cancelRecording,
                onClearBinding: { actionId in
                    settings.clearBinding(for: actionId)
                    applyBindings()
                },
                onResetBindings: { actionId in
                    settings.resetBindings(for: actionId)
                    applyBindings()
                },
                onSetSide: setSide,
                onModeKeyCaptured: { _, _ in },
                onClearModeKey: { _ in }
            )
            .id("Undo Resize")
            .onChange(of: recordingTarget) { _, _ in
                controller.setHotkeyRecordingActive(recordingTarget != nil)
            }
            .alert(item: $conflictAlert) { alert in
                Alert(
                    title: Text("Hotkey Conflict"),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("Replace")) {
                        HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                        applyBindings()
                    },
                    secondaryButton: .cancel { cancelRecording() }
                )
            }
            .alert(
                "Hotkey Conflict",
                isPresented: Binding(get: { captureRejection != nil }, set: { if !$0 { captureRejection = nil } }),
                presenting: captureRejection
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func handleChordCaptured(actionId: String, newTrigger: HotkeyTrigger) {
        let side = settings.hotkeyBindings.first { $0.id == actionId }?.binding.chordBinding?.side ?? .either
        capture(newTrigger.chordBinding.map { .chord($0.settingSide(side)) } ?? newTrigger, for: actionId)
    }

    private func setSide(actionId: String, side: ModifierSide) {
        guard let chord = settings.hotkeyBindings.first(where: { $0.id == actionId })?.binding.chordBinding
        else { return }
        capture(.chord(chord.settingSide(side)), for: actionId)
    }

    private func capture(_ trigger: HotkeyTrigger, for actionId: String) {
        switch HotkeyBindingEditor.capture(trigger, for: actionId, settings: settings) {
        case .applied:
            applyBindings()
        case let .conflict(alert):
            conflictAlert = alert
            cancelRecording()
        case let .rejected(message):
            captureRejection = message
            cancelRecording()
        }
    }

    private func applyBindings() {
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func cancelRecording() {
        recordingTarget = nil
        controller.setHotkeyRecordingActive(false)
    }
}
