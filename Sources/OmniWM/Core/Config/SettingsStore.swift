// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class SettingsStore {
    private nonisolated static let defaultExport = SettingsExport.defaults()
    let focus = FocusSettings()
    let pointer = PointerSettings()
    let monitors = MonitorConfigurationSettings()
    let gaps = GapSettings()
    let niri = NiriSettings()
    let dwindle: DwindlePreferences
    let gestures = GestureSettings()
    let workspaceBar = WorkspaceBarSettings()
    let workspaces = WorkspaceSettings()

    private let persistence: SettingsFilePersistence
    private let runtimeState: RuntimeStateStore
    private let autosaveEnabled: Bool
    private var isApplyingExport = false
    private var isApplyingRuntimeState = false

    var onIPCEnabledChanged: (@MainActor (Bool) -> Void)?
    var onExternalSettingsReloaded: (@MainActor () -> Void)?
    var onConfigNoticeChanged: (@MainActor () -> Void)?
    var onTrackpadGestureAvailabilityChanged: (@MainActor (Bool) -> Void)?
    private(set) var configNotice: SettingsConfigNotice?

    var hotkeysEnabled = SettingsStore.defaultExport.hotkeysEnabled {
        didSet { scheduleSave() }
    }

    func applyMonitorSetup(
        routingSettings: [MonitorRoutingSettings],
        monitors: [Monitor],
        mouseWarpEnabled: Bool,
        workspaceConfigurations: [WorkspaceConfiguration]
    ) {
        self.monitors.storeRoutingLayout(routingSettings, for: monitors)
        self.monitors.routingMode = .custom
        self.pointer.enabled = mouseWarpEnabled
        if workspaces.configurations != workspaceConfigurations {
            workspaces.configurations = workspaceConfigurations
        }
    }

    let borders = BorderSettings()

    let overview = OverviewSettings()

    var hotkeyBindings = SettingsStore.defaultExport.hotkeyBindings {
        didSet { scheduleSave() }
    }

    var systemHyperTrigger = SettingsStore.defaultExport.systemHyperTrigger {
        didSet { scheduleSave() }
    }

    private var hyperKeyModifiersStorage = SettingsStore.defaultExport.hyperKeyModifiers

    var hyperKeyModifiers: HyperKeyModifiers {
        get { hyperKeyModifiersStorage }
        set { applyHyperKeyModifiers(newValue) }
    }

    private func applyHyperKeyModifiers(_ newValue: HyperKeyModifiers) {
        guard newValue != hyperKeyModifiersStorage else { return }
        let retargeted = HotkeyBindingRegistry.retargetingHyperChords(hotkeyBindings, to: newValue)
        hyperKeyModifiersStorage = newValue
        hotkeyBindings = retargeted
        scheduleSave()
    }

    private(set) var scratchpadLabels = SettingsStore.normalizedScratchpadLabels(
        SettingsStore.defaultExport.scratchpads.labels
    ) {
        didSet { scheduleSave() }
    }

    private(set) var appRulesRevision: UInt64 = 0
    private(set) var appRulesDiagnosticSnapshot = WindowClassificationRulesSnapshot(
        revision: 0,
        rules: SettingsStore.defaultExport.appRules
    )

    var appRules = SettingsStore.defaultExport.appRules {
        didSet {
            if appRules != oldValue {
                appRulesRevision &+= 1
                appRulesDiagnosticSnapshot = WindowClassificationRulesSnapshot(
                    revision: appRulesRevision,
                    rules: appRules
                )
            }
            scheduleSave()
        }
    }

    var preventSleepEnabled = SettingsStore.defaultExport.preventSleepEnabled {
        didSet { scheduleSave() }
    }

    var updateChecksEnabled = SettingsStore.defaultExport.updateChecksEnabled {
        didSet { scheduleSave() }
    }

    var ipcEnabled = SettingsStore.defaultExport.ipcEnabled {
        didSet {
            guard oldValue != ipcEnabled else { return }
            onIPCEnabledChanged?(ipcEnabled)
            scheduleSave()
        }
    }

    let statusBar = StatusBarSettings()

    let hiddenBar = HiddenBarSettings()

    var commandPaletteLastMode = RuntimeStateStore.defaultCommandPaletteLastMode {
        didSet { runtimeState.commandPaletteLastMode = commandPaletteLastMode }
    }

    var commandPaletteApplicationsViewStyle: LauncherViewStyle {
        get { runtimeState.commandPaletteViewStyle(for: .applications) }
        set { runtimeState.setCommandPaletteViewStyle(newValue, for: .applications) }
    }

    var commandPaletteFilesViewStyle: LauncherViewStyle {
        get { runtimeState.commandPaletteViewStyle(for: .files) }
        set { runtimeState.setCommandPaletteViewStyle(newValue, for: .files) }
    }

    func recordLauncherLaunch(targetID: String, query: String, displayName: String? = nil) {
        runtimeState.recordLauncherLaunch(
            targetID: targetID,
            displayName: displayName ?? URL(fileURLWithPath: targetID).lastPathComponent,
            query: query
        )
    }

    func launcherShortcutTarget(for query: String) -> String? {
        runtimeState.launcherShortcutTarget(for: query)
    }

    func launcherLaunches(for targetID: String) -> [LauncherLaunch] {
        runtimeState.launcherLaunches(for: targetID)
    }

    var launcherLaunchesSnapshot: [String: [LauncherLaunch]] {
        runtimeState.launcherLaunchesSnapshot
    }

    var launcherHiddenSuggestions: Set<String> {
        get { runtimeState.launcherHiddenSuggestions }
        set { runtimeState.launcherHiddenSuggestions = newValue }
    }

    var animationsEnabled = SettingsStore.defaultExport.animationsEnabled {
        didSet { scheduleSave() }
    }

    let clipboard = ClipboardSettings()

    let quakeTerminal = QuakeTerminalSettings()

    var quakeTerminalUseCustomFrame = RuntimeStateStore.defaultQuakeTerminalUseCustomFrame {
        didSet {
            if !quakeTerminalUseCustomFrame, quakeTerminalCustomFrameStorage != nil {
                quakeTerminalCustomFrameStorage = nil
            }
            syncQuakeTerminalCustomFrameToRuntimeState()
        }
    }

    private var quakeTerminalCustomFrameStorage: NSRect? {
        didSet { syncQuakeTerminalCustomFrameToRuntimeState() }
    }

    var quakeTerminalCustomFrame: NSRect? {
        get { quakeTerminalCustomFrameStorage }
        set {
            if let frame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(newValue) {
                quakeTerminalCustomFrameStorage = frame
            } else {
                quakeTerminalCustomFrameStorage = nil
                quakeTerminalUseCustomFrame = false
            }
        }
    }

    func resetQuakeTerminalCustomFrame() {
        quakeTerminalUseCustomFrame = false
        quakeTerminalCustomFrame = nil
    }

    var appearanceMode = SettingsStore.defaultExport.appearanceMode {
        didSet { scheduleSave() }
    }

    var tabRailAppIcons = SettingsStore.defaultExport.tabRailAppIcons {
        didSet { scheduleSave() }
    }

    func loadPersistedWindowRestoreCatalog() -> PersistedWindowRestoreCatalog {
        runtimeState.windowRestoreCatalog ?? .empty
    }

    func savePersistedWindowRestoreCatalog(_ catalog: PersistedWindowRestoreCatalog) {
        runtimeState.windowRestoreCatalog = catalog.entries.isEmpty ? nil : catalog
    }

    var issueDraft: IssueDraft? {
        get { runtimeState.issueDraft }
        set { runtimeState.issueDraft = newValue }
    }

    var hasSeenIssueWalkthrough: Bool {
        get { runtimeState.hasSeenIssueWalkthrough }
        set { runtimeState.hasSeenIssueWalkthrough = newValue }
    }

    var monitorSetupStatus = RuntimeStateStore.defaultMonitorSetupStatus {
        didSet { runtimeState.monitorSetupStatus = monitorSetupStatus }
    }

    init(
        persistence: SettingsFilePersistence = SettingsFilePersistence(),
        runtimeState: RuntimeStateStore = RuntimeStateStore(),
        autosaveEnabled: Bool = true
    ) {
        dwindle = DwindlePreferences(gaps: gaps)
        self.persistence = persistence
        self.runtimeState = runtimeState
        self.autosaveEnabled = autosaveEnabled
        commandPaletteLastMode = runtimeState.commandPaletteLastMode
        monitorSetupStatus = runtimeState.monitorSetupStatus
        isApplyingRuntimeState = true
        quakeTerminalCustomFrameStorage = QuakeTerminalGeometryPolicy.normalizedCustomFrame(
            runtimeState.quakeTerminalCustomFrame
        )
        quakeTerminalUseCustomFrame = runtimeState.quakeTerminalUseCustomFrame && quakeTerminalCustomFrameStorage != nil
        isApplyingRuntimeState = false
        syncQuakeTerminalCustomFrameToRuntimeState()

        focus.onChange = { [weak self] in self?.scheduleSave() }
        pointer.onChange = { [weak self] in self?.scheduleSave() }
        monitors.onChange = { [weak self] in self?.scheduleSave() }
        gaps.onChange = { [weak self] in self?.scheduleSave() }
        niri.onChange = { [weak self] in self?.scheduleSave() }
        dwindle.onChange = { [weak self] in self?.scheduleSave() }
        gestures.onChange = { [weak self] in self?.scheduleSave() }
        workspaceBar.onChange = { [weak self] in self?.scheduleSave() }
        workspaces.onChange = { [weak self] in self?.scheduleSave() }
        borders.onChange = { [weak self] in self?.scheduleSave() }
        overview.onChange = { [weak self] in self?.scheduleSave() }
        statusBar.onChange = { [weak self] in self?.scheduleSave() }
        hiddenBar.onChange = { [weak self] in self?.scheduleSave() }
        clipboard.onChange = { [weak self] in self?.scheduleSave() }
        quakeTerminal.onChange = { [weak self] in self?.scheduleSave() }
        gestures.onAvailabilityChanged = { [weak self] available in
            guard let self, !self.isApplyingExport else { return }
            self.onTrackpadGestureAvailabilityChanged?(available)
        }

        let outcome = persistence.loadOutcome()
        transitionConfigNotice(to: outcome.notice)
        applyExport(outcome.export ?? SettingsExport.defaults())
        persistence.setExternalChangeHandler { [weak self] outcome in
            self?.handleExternalReload(outcome)
        }
        persistence.setSaveNoticeHandler { [weak self] notice in
            self?.transitionConfigNotice(to: notice)
        }
    }

    var settingsFileURL: URL {
        persistence.fileURL
    }

    var settingsWritesBlocked: Bool {
        persistence.settingsWritesBlocked
    }

    func ensureSettingsFileAvailable() throws {
        guard !FileManager.default.fileExists(atPath: settingsFileURL.path) else { return }
        if let notice = try persistence.saveImmediately(toExport()) {
            transitionConfigNotice(to: notice)
        }
    }

    func flushNow() {
        if autosaveEnabled {
            persistence.flushNow()
        } else {
            persistence.save(toExport())
        }
        runtimeState.flushNow()
    }

    private func syncQuakeTerminalCustomFrameToRuntimeState() {
        guard !isApplyingRuntimeState else { return }
        if let quakeTerminalCustomFrameStorage, quakeTerminalUseCustomFrame {
            runtimeState.quakeTerminalCustomFrame = quakeTerminalCustomFrameStorage
            runtimeState.quakeTerminalUseCustomFrame = true
        } else {
            runtimeState.quakeTerminalUseCustomFrame = false
            runtimeState.quakeTerminalCustomFrame = nil
        }
    }

    private func handleExternalReload(_ outcome: SettingsFileLoadOutcome) {
        transitionConfigNotice(to: outcome.notice)
        guard let export = outcome.export else { return }
        applyExport(export)
        onExternalSettingsReloaded?()
    }

    private func transitionConfigNotice(to notice: SettingsConfigNotice?) {
        guard notice != configNotice else { return }
        configNotice = notice
        onConfigNoticeChanged?()
    }

    func scheduleSave() {
        guard autosaveEnabled, !isApplyingExport else { return }
        persistence.scheduleSave(toExport())
    }

    static func normalizedScratchpadLabels(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { normalized, entry in
            guard let index = Int(entry.key.trimmingCharacters(in: .whitespacesAndNewlines)),
                  IPCScratchpadSlots.range.contains(index)
            else {
                return
            }
            let label = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return }
            normalized[String(index)] = label
        }
    }

    func scratchpadLabel(for index: Int) -> String? {
        scratchpadLabels[String(index)]
    }
}

extension SettingsStore {
    func toExport() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: hotkeysEnabled,
            focus: focus.export(),
            mouseWarp: pointer.export(),
            routing: monitors.export(),
            monitorRanking: monitors.ranking,
            gaps: gaps.export(),
            niri: niri.export(),
            workspaceConfigurations: workspaces.configurations,
            defaultLayoutType: workspaces.defaultLayoutType,
            borders: borders.export(),
            overview: overview.export(),
            hotkeyBindings: hotkeyBindings,
            systemHyperTrigger: systemHyperTrigger,
            hyperKeyModifiers: hyperKeyModifiersStorage,
            workspaceBar: workspaceBar.export(),
            scratchpads: SettingsExport.Scratchpads(labels: scratchpadLabels),
            monitorBarSettings: workspaceBar.monitorOverrides,
            appRules: appRules,
            monitorOrientationSettings: monitors.orientationOverrides,
            monitorNiriSettings: niri.monitorOverrides,
            dwindle: dwindle.export(),
            monitorDwindleSettings: dwindle.monitorOverrides,
            monitorGapSettings: gaps.monitorOverrides.filter(\.hasOverrides),
            preventSleepEnabled: preventSleepEnabled,
            updateChecksEnabled: updateChecksEnabled,
            ipcEnabled: ipcEnabled,
            gestures: gestures.export(),
            statusBar: statusBar.export(),
            hiddenBar: hiddenBar.export(),
            animationsEnabled: animationsEnabled,
            clipboard: clipboard.export(),
            quakeTerminal: quakeTerminal.export(),
            appearanceMode: appearanceMode,
            tabRailAppIcons: tabRailAppIcons
        )
    }

    func applyExport(_ export: SettingsExport) {
        let baseline = SettingsStore.defaultExport
        let trackpadGesturesWereAvailable = gestures.trackpadGesturesEnabled
        isApplyingExport = true
        defer {
            isApplyingExport = false
            let trackpadGesturesAreAvailable = gestures.trackpadGesturesEnabled
            if trackpadGesturesWereAvailable != trackpadGesturesAreAvailable {
                onTrackpadGestureAvailabilityChanged?(trackpadGesturesAreAvailable)
            }
        }

        hotkeysEnabled = export.hotkeysEnabled
        focus.apply(export.focus)
        pointer.margin = export.mouseWarp.margin
        pointer.enabled = export.mouseWarp.enabled
        pointer.constrainToArrangement = export.mouseWarp.constrainToArrangement
        monitors.routingMode = export.routing.mode
        monitors.arrangements = export.routing.arrangements
        monitors.ranking = MonitorRanking.normalized(export.monitorRanking)
        gaps.apply(export.gaps)

        niri.apply(export.niri, baseline: baseline.niri)

        workspaces.configurations = WorkspaceSettings.normalizedConfigurations(export.workspaceConfigurations)
        workspaces.defaultLayoutType = export.defaultLayoutType

        borders.apply(export.borders)

        overview.apply(export.overview, baseline: baseline.overview)

        hyperKeyModifiersStorage = export.hyperKeyModifiers
        KeySymbolMapper.setHyperKeyModifiers(export.hyperKeyModifiers)
        hotkeyBindings = export.hotkeyBindings
        systemHyperTrigger = export.systemHyperTrigger

        workspaceBar.applyIdentity(export.workspaceBar)
        scratchpadLabels = SettingsStore.normalizedScratchpadLabels(export.scratchpads.labels)
        workspaceBar.applyAppearance(export.workspaceBar, monitorOverrides: export.monitorBarSettings)

        appRules = export.appRules
        monitors.orientationOverrides = export.monitorOrientationSettings
        niri.monitorOverrides = export.monitorNiriSettings

        dwindle.apply(export.dwindle)
        dwindle.monitorOverrides = export.monitorDwindleSettings
        gaps.monitorOverrides = export.monitorGapSettings.filter(\.hasOverrides)

        preventSleepEnabled = export.preventSleepEnabled
        updateChecksEnabled = export.updateChecksEnabled
        ipcEnabled = export.ipcEnabled
        gestures.apply(export.gestures)
        statusBar.apply(export.statusBar)
        hiddenBar.apply(export.hiddenBar)
        animationsEnabled = export.animationsEnabled
        clipboard.apply(export.clipboard)

        quakeTerminal.apply(export.quakeTerminal, baseline: baseline.quakeTerminal)

        appearanceMode = export.appearanceMode
        tabRailAppIcons = export.tabRailAppIcons
    }
}

extension SettingsStore {
    func resetHotkeysToDefaults() {
        hyperKeyModifiers = SettingsStore.defaultExport.hyperKeyModifiers
        hotkeyBindings = HotkeyBindingRegistry.defaults()
        systemHyperTrigger = SettingsStore.defaultExport.systemHyperTrigger
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        updateTrigger(for: commandId, newTrigger: newBinding.isUnassigned ? .unassigned : .chord(newBinding))
    }

    func updateTrigger(for commandId: String, newTrigger: HotkeyTrigger) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            trigger: newTrigger
        )
    }

    func clearBinding(for commandId: String) {
        updateBinding(for: commandId, newBinding: .unassigned)
    }

    func resetBindings(for commandId: String) {
        guard let defaultBinding = HotkeyBindingRegistry.defaults().first(where: { $0.id == commandId }),
              let index = hotkeyBindings.firstIndex(where: { $0.id == commandId })
        else { return }
        hotkeyBindings[index] = defaultBinding
    }

    func findConflicts(for trigger: HotkeyTrigger, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { hotkeyBinding in
            hotkeyBinding.id != commandId &&
                hotkeyBinding.binding.conflicts(with: trigger)
        }
    }
}
