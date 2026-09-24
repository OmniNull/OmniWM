// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import SwiftUI

enum HotkeyCaptureResult {
    case applied
    case conflict(ConflictAlert)
}

@MainActor enum HotkeyBindingEditor {
    static func capture(
        _ newBinding: KeyBinding,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        capture(newBinding.isUnassigned ? .unassigned : .chord(newBinding), for: actionId, settings: settings)
    }

    static func capture(
        _ newTrigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        let conflicts = settings.findConflicts(for: newTrigger, excluding: actionId)
        guard conflicts.isEmpty else {
            return .conflict(
                ConflictAlert(
                    targetActionId: actionId,
                    newTrigger: newTrigger,
                    conflictingCommands: conflicts.map(\.command.localizedDisplayName)
                )
            )
        }

        settings.updateTrigger(for: actionId, newTrigger: newTrigger)
        return .applied
    }

    static func applyConflictResolution(_ alert: ConflictAlert, settings: SettingsStore) {
        let conflicts = settings.findConflicts(for: alert.newTrigger, excluding: alert.targetActionId)
        for conflict in conflicts {
            settings.clearBinding(for: conflict.id)
        }
        settings.updateTrigger(for: alert.targetActionId, newTrigger: alert.newTrigger)
    }
}

enum HotkeyInputMonitoringStatus: Equatable {
    case granted
    case denied

    init(granted: Bool) {
        self = granted ? .granted : .denied
    }

    var displayText: String {
        switch self {
        case .granted:
            String(localized: "Granted")
        case .denied:
            String(localized: "Denied")
        }
    }
}

enum HotkeySettingsDisplayModel {
    private static let unassignedText = String(localized: "Unassigned")
    struct Group: Identifiable {
        let category: HotkeyCategory
        let bindings: [HotkeyBinding]

        var id: HotkeyCategory {
            category
        }
    }

    static func search(_ query: String, bindings: [HotkeyBinding]) -> [Group] {
        let normalizedQuery = ActionCatalog.normalizedSearchTerm(query)
        var bindingsByCategory: [HotkeyCategory: [HotkeyBinding]] = [:]
        for binding in bindings {
            guard ActionCatalog.visibility(for: binding.id) != .unassignable,
                  matchesSearch(normalizedQuery, binding: binding)
            else { continue }
            bindingsByCategory[binding.category, default: []].append(binding)
        }
        return HotkeyCategory.allCases.compactMap { category in
            bindingsByCategory[category].map { Group(category: category, bindings: $0) }
        }
    }

    private static func matchesSearch(_ normalizedQuery: String, binding: HotkeyBinding) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if let terms = ActionCatalog.normalizedSearchTerms(for: binding.id) {
            if terms.contains(where: { $0.contains(normalizedQuery) }) { return true }
        } else if ActionCatalog.normalizedSearchTerm(binding.command.displayName).contains(normalizedQuery)
            || ActionCatalog.normalizedSearchTerm(binding.command.layoutCompatibility.rawValue)
            .contains(normalizedQuery)
        {
            return true
        }
        return ActionCatalog.normalizedSearchTerm(displayString(for: binding.binding)).contains(normalizedQuery)
            || ActionCatalog.normalizedSearchTerm(humanReadableString(for: binding.binding)).contains(normalizedQuery)
    }

    static func displayString(for binding: KeyBinding) -> String {
        binding.isUnassigned ? unassignedText : binding.displayString
    }

    static func displayString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return unassignedText
        case let .chord(binding):
            return displayString(for: binding)
        }
    }

    static func humanReadableString(for binding: KeyBinding) -> String {
        binding.isUnassigned ? unassignedText : binding.humanReadableString
    }

    static func humanReadableString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return unassignedText
        case let .chord(binding):
            return humanReadableString(for: binding)
        }
    }

    static func inputMonitoringStatus(
        preflightGranted: Bool,
        requestIfNeeded: Bool,
        requestGranted: Bool
    ) -> HotkeyInputMonitoringStatus {
        HotkeyInputMonitoringStatus(granted: preflightGranted || (requestIfNeeded && requestGranted))
    }
}

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingTarget: HotkeyRecordingTarget?
    @State private var conflictAlert: ConflictAlert?
    @State private var hyperTriggerError: String?
    @State private var searchText: String = ""
    @State private var confirmsResetToDefaults = false
    @State private var inputMonitoringStatus = HotkeyInputMonitoringStatus(
        granted: HotkeyCenter.inputMonitoringAccessGranted()
    )

    var body: some View {
        let groups = HotkeySettingsDisplayModel.search(searchText, bindings: settings.hotkeyBindings)
        HotkeySettingsPage(
            subtitle: String(
                localized: "Search commands, edit shortcuts, and review registration problems without leaving the settings window."
            )
        ) {
            Section("Controls") {
                LabeledContent("System Hyper Trigger") {
                    Picker("System Hyper Trigger", selection: systemHyperTriggerBinding) {
                        Text("None").tag(SystemHyperTrigger.none)
                        ForEach(SystemHyperTrigger.selectableKeyCodes, id: \.self) { code in
                            Text(KeySymbolMapper.keyName(code)).tag(SystemHyperTrigger.key(code))
                        }
                        ForEach(SystemHyperTrigger.selectableMouseButtons, id: \.self) { button in
                            Text("Mouse Button \(button)").tag(SystemHyperTrigger.mouseButton(button))
                                .disabled(settings.overview.mouseButton == button)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160)
                    .onChange(of: settings.systemHyperTrigger) { _, _ in
                        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
                    }
                    .accessibilityLabel("System Hyper trigger")
                    .accessibilityValue(settings.systemHyperTrigger.humanReadableString)
                }
                if let hyperTriggerError {
                    SettingsCaption(hyperTriggerError)
                }
                if let triggerFailure = controller.systemHyperTriggerFailure {
                    SettingsCaption(systemHyperTriggerFailureMessage(triggerFailure))
                }
                SettingsCaption(localized:
                    "Hold this key or button to act as \(settings.hyperKeyModifiers.symbolsString) (Hyper). Needs Input Monitoring permission. Leave as None to use a Hyper key set up elsewhere, such as Karabiner."
                )

                LabeledContent("Hyper Key Modifiers") {
                    HStack(spacing: 12) {
                        hyperModifierToggle(String(localized: "⌃ Control"), flag: UInt32(controlKey))
                        hyperModifierToggle(String(localized: "⌥ Option"), flag: UInt32(optionKey))
                        hyperModifierToggle(String(localized: "⇧ Shift"), flag: UInt32(shiftKey))
                        hyperModifierToggle(String(localized: "⌘ Command"), flag: UInt32(cmdKey))
                    }
                    .fixedSize()
                    .onChange(of: settings.hyperKeyModifiers) { _, _ in
                        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
                    }
                }
                SettingsCaption(localized:
                    "Modifiers that make up the Hyper chord. Unchecked modifiers stay free to combine with Hyper in shortcuts, such as Hyper+Shift when Shift is excluded."
                )

                LabeledContent("Input Monitoring") {
                    HStack(spacing: 10) {
                        Text(inputMonitoringStatus.displayText)
                            .foregroundStyle(inputMonitoringStatus == .granted ? Color.secondary : Color.orange)
                        Button("Request Permission") {
                            refreshInputMonitoringStatus(requestIfNeeded: true)
                        }
                    }
                }

                LabeledContent("Defaults") {
                    Button("Reset to Defaults", role: .destructive) {
                        confirmsResetToDefaults = true
                    }
                }
            }

            Section("Shortcuts") {
                LabeledContent("Search") {
                    HStack(spacing: 8) {
                        TextField("Command, shortcut, or scope", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search hotkeys")

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Label("Clear search", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Clear search")
                            .accessibilityLabel("Clear hotkey search")
                        }
                    }
                }

                if groups.isEmpty {
                    Text("No matching hotkeys.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups) { group in
                Section(group.category.localizedDisplayName) {
                    ForEach(group.bindings) { binding in
                        HotkeyBindingRow(
                            binding: binding,
                            recordingTarget: $recordingTarget,
                            failureReason: controller.hotkeyRegistrationFailures[binding.command],
                            isHyperActive: {
                                controller.isHyperTriggerActive
                            },
                            onStartChordRecording: startChordRecording,
                            onChordCaptured: handleChordCaptured,
                            onCancelRecording: cancelRecording,
                            onClearBinding: clearBinding,
                            onResetBindings: resetBindings,
                            onSetSide: setSide
                        )
                    }
                }
            }
        }
        .onAppear {
            inputMonitoringStatus = HotkeyInputMonitoringStatus(
                granted: HotkeyCenter.inputMonitoringAccessGranted()
            )
        }
        .onChange(of: recordingTarget) { _, _ in
            syncHotkeyRecordingState()
        }
        .onDisappear {
            guard isRecordingOrDrafting else { return }
            cancelRecording()
            controller.setHotkeysEnabled(settings.hotkeysEnabled)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                    cancelRecording()
                },
                secondaryButton: .cancel {
                    cancelRecording()
                }
            )
        }
        .confirmationDialog("Reset all hotkeys?", isPresented: $confirmsResetToDefaults) {
            Button("Reset Hotkeys", role: .destructive) {
                settings.resetHotkeysToDefaults()
                controller.updateHotkeyBindings(settings.hotkeyBindings)
                cancelRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All hotkey bindings will be restored to OmniWM defaults.")
        }
    }

    private var isRecordingOrDrafting: Bool {
        recordingTarget != nil
    }

    private func startChordRecording(for actionId: String) {
        recordingTarget = .chord(actionId)
    }

    private func hyperModifierToggle(_ title: String, flag: UInt32) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings.hyperKeyModifiers.contains(flag) },
            set: { included in
                guard let updated = settings.hyperKeyModifiers.setting(flag, included: included) else { return }
                settings.hyperKeyModifiers = updated
            }
        ))
        .disabled(
            settings.hyperKeyModifiers.contains(flag)
                && settings.hyperKeyModifiers.modifierCount <= HyperKeyModifiers.minimumModifierCount
        )
        .accessibilityLabel("Hyper includes \(title)")
    }

    private func systemHyperTriggerFailureMessage(_ failure: SystemHyperTriggerFailure) -> String {
        switch failure {
        case .eventTapUnavailable:
            String(localized: "System Hyper trigger is unavailable: grant Input Monitoring permission.")
        case .capsLockRemapUnavailable:
            String(localized: "System Hyper trigger is unavailable: Caps Lock remapping failed.")
        }
    }

    private func handleChordCaptured(actionId: String, newBinding: KeyBinding) {
        guard !newBinding.isUnassigned else {
            handleTriggerCaptured(actionId: actionId, newTrigger: .unassigned)
            return
        }
        let previousSide = settings.hotkeyBindings
            .first { $0.id == actionId }?.binding.chordBinding?.side ?? .either
        handleTriggerCaptured(actionId: actionId, newTrigger: .chord(newBinding.settingSide(previousSide)))
    }

    private func handleTriggerCaptured(actionId: String, newTrigger: HotkeyTrigger) {
        switch HotkeyBindingEditor.capture(newTrigger, for: actionId, settings: settings) {
        case .applied:
            controller.updateHotkeyBindings(settings.hotkeyBindings)
            cancelRecording()
        case let .conflict(alert):
            conflictAlert = alert
            cancelRecording()
        }
    }

    private func clearBinding(actionId: String) {
        settings.clearBinding(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func resetBindings(actionId: String) {
        settings.resetBindings(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func setSide(actionId: String, side: ModifierSide) {
        guard let binding = settings.hotkeyBindings.first(where: { $0.id == actionId }),
              let chord = binding.binding.chordBinding
        else { return }
        handleTriggerCaptured(actionId: actionId, newTrigger: .chord(chord.settingSide(side)))
    }

    private func cancelRecording() {
        recordingTarget = nil
        syncHotkeyRecordingState()
    }

    @discardableResult
    private func refreshInputMonitoringStatus(requestIfNeeded: Bool) -> Bool {
        let preflightGranted = HotkeyCenter.inputMonitoringAccessGranted()
        let requestGranted: Bool
        if preflightGranted || !requestIfNeeded {
            requestGranted = false
        } else {
            requestGranted = HotkeyCenter.requestInputMonitoringAccess()
        }
        let status = HotkeySettingsDisplayModel.inputMonitoringStatus(
            preflightGranted: preflightGranted,
            requestIfNeeded: requestIfNeeded,
            requestGranted: requestGranted
        )
        inputMonitoringStatus = status
        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
        return status == .granted
    }

    private func syncHotkeyRecordingState() {
        controller.setHotkeyRecordingActive(isRecordingOrDrafting)
    }
}

extension HotkeySettingsView {
    private var systemHyperTriggerBinding: Binding<SystemHyperTrigger> {
        Binding(
            get: { settings.systemHyperTrigger },
            set: { trigger in
                do {
                    try settings.setSystemHyperTrigger(trigger)
                    hyperTriggerError = nil
                } catch {
                    hyperTriggerError = error.localizedDescription
                }
            }
        )
    }
}

struct ConflictAlert: Identifiable {
    let targetActionId: String
    let newTrigger: HotkeyTrigger
    let conflictingCommands: [String]

    var id: String {
        [
            targetActionId,
            newTrigger.humanReadableString,
            conflictingCommands.joined(separator: "|")
        ].joined(separator: ":")
    }

    var message: String {
        if conflictingCommands.count == 1 {
            return String(
                localized: "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
            )
        }
        let commandList = conflictingCommands.joined(separator: ", ")
        return String(localized: "This key combination is used by: \(commandList). Do you want to replace all?")
    }
}
