// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func updateWindowSwitcherSettings() {
        hotkeys.configureWindowSwitcher(settings.windowSwitcher.export())
        refreshHotkeyFailureSnapshots()
        guard !settings.windowSwitcher.enabled else { return }
        windowSwitcherControllerStorage?.shutdown()
        windowSwitcherControllerStorage = nil
    }

    func invalidateOverviewDeferredActionsForServiceStop() {
        windowActionHandlerStorage?.invalidateOverviewDeferredActionsForServiceStop()
    }

    func setPreventSleepEnabled(_ enabled: Bool, manager: SleepPreventionManager = .shared) {
        guard enabled != manager.awake.indefinite else { return }
        manager.perform(enabled ? .on : .off)
    }

    func performKeepAwake(_ command: ShellAwakeCommand, manager: SleepPreventionManager = .shared) {
        manager.perform(command)
        if settings.preventSleepEnabled != manager.awake.indefinite {
            settings.preventSleepEnabled = manager.awake.indefinite
        }
    }

    func toggleHiddenBarPanel(on monitorId: Monitor.ID? = nil) {
        statusBarController?.dismissPanel()
        hiddenBarController.toggleDrawer(
            on: hiddenBarMonitor(on: monitorId)?.id,
            placement: hiddenBarPanelPlacement(on: monitorId)
        )
    }

    private func hiddenBarMonitor(on monitorId: Monitor.ID?) -> Monitor? {
        let monitors = workspaceManager.monitors
        return monitors.first(where: { $0.id == monitorId })
            ?? currentMouseLocation().monitorApproximation(in: monitors)
            ?? monitors.first(where: \.isMain) ?? monitors.first
    }

    private func hiddenBarPanelPlacement(on monitorId: Monitor.ID?) -> HiddenBarPanelPlacement? {
        guard let monitor = hiddenBarMonitor(on: monitorId) else { return nil }
        let resolved = settings.workspaceBar.resolved(for: monitor)
        if isWorkspaceBarVisible(on: monitor, resolved: resolved),
           let placement = workspaceBarManager.hiddenBarPanelPlacement(on: monitor.id)
        {
            return placement
        }
        return HiddenBarPanelPlacement(
            attachment: PopupAttachment(
                anchor: CGPoint(x: monitor.frame.midX, y: monitor.visibleFrame.maxY)
            ),
            visibleFrame: monitor.visibleFrame
        )
    }

    func setHiddenBarEnabled(_ enabled: Bool) {
        hiddenBarController.setEnabled(enabled)
    }

    func updateHiddenBarSettings() {
        hiddenBarController.applySettings()
    }

    func hiddenBarSystemSettingsAllowance() -> [String: Bool] {
        hiddenBarController.systemSettingsAllowance()
    }

    func setQuakeTerminalEnabled(_ enabled: Bool) {
        applyQuakeTerminalSelection(enabled ? settings.quakeTerminal.provider : nil)
        updateHotkeyBindings(settings.hotkeyBindings)
    }

    func setQuakeTerminalProvider(_ provider: QuakeTerminalProvider) {
        guard settings.quakeTerminal.enabled else { return }
        applyQuakeTerminalSelection(provider)
    }

    private func applyQuakeTerminalSelection(_ selection: QuakeTerminalProvider?) {
        let previous = appliedQuakeTerminalSelection
        appliedQuakeTerminalSelection = selection
        if previous != selection {
            switch previous {
            case .kitty: kittyQuickAccessTerminal.hide()
            case .foot: footQuickAccessTerminal.hide()
            case .ghostty,
                 nil: break
            }
        }
        switch selection {
        case nil:
            quakeTerminalController.cleanup()
        case .ghostty:
            quakeTerminalController.setup()
            if previous == .kitty || previous == .foot {
                reloadQuakeTerminalAppearance()
            }
        case .kitty:
            guard previous != .kitty else { return }
            quakeTerminalController.hideForProviderSwitch()
            kittyQuickAccessTerminal.activate()
            applyKittyQuakeSettings()
        case .foot:
            guard previous != .foot else { return }
            quakeTerminalController.hideForProviderSwitch()
            footQuickAccessTerminal.activate()
        }
    }

    func toggleQuakeTerminal() {
        switch appliedQuakeTerminalSelection {
        case .ghostty:
            quakeTerminalController.toggle()
        case .kitty:
            kittyQuickAccessTerminal.toggle()
        case .foot:
            footQuickAccessTerminal.toggle()
        case nil:
            return
        }
    }

    func externalQuakeDisplay() -> ExternalQuakeDisplay? {
        guard let monitor = ExternalQuakeDisplay.monitor(at: currentMouseLocation(), in: workspaceManager.monitors)
        else { return nil }
        return ExternalQuakeDisplay(monitor: monitor, topBarBottom: workspaceBarManager.topBarBottom(on: monitor.id))
    }

    func kittyQuakeControlContext() -> KittyQuakeControlContext? {
        externalQuakeDisplay().map { KittyQuakeControlContext(settings: settings.quakeTerminal.kitty, display: $0) }
    }

    func footQuakeControlContext() -> FootQuakeControlContext? {
        let animationDuration = motionPolicy.animationsEnabled ? settings.quakeTerminal.animationDuration : 0
        return externalQuakeDisplay()?.panelArea.map {
            FootQuakeControlContext(
                settings: settings.quakeTerminal.foot,
                area: $0,
                animationDuration: animationDuration
            )
        }
    }

    func applyKittyQuakeSettings() {
        guard appliedQuakeTerminalSelection == .kitty else { return }
        kittyQuickAccessTerminal.applySettings()
    }

    func reapplyQuakeTerminalGeometryForMonitorChange() {
        guard appliedQuakeTerminalSelection == .ghostty else { return }
        quakeTerminalController.applyGeometryToVisibleWindow()
    }

    func reloadQuakeTerminalAppearance() {
        guard appliedQuakeTerminalSelection == .ghostty else { return }
        quakeTerminalController.applyGeometryToVisibleWindow()
        quakeTerminalController.reloadOpacityConfig()
        quakeTerminalController.reloadBackgroundBlur()
    }

    func presentQuakeTerminalFailure(title: String, message: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            _ = alert.runModal()
        }
    }

    func reloadQuakeTerminalOpacity() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundEffect() {
        quakeTerminalController.reloadOpacityConfig()
    }

    func reloadQuakeTerminalBackgroundBlur() {
        quakeTerminalController.reloadBackgroundBlur()
    }

    func toggleSystemStats() {
        let monitors = workspaceManager.monitors
        let pointer = NSEvent.mouseLocation.monitorApproximation(in: monitors)
        let main = monitors.first(where: \.isMain)
        _ = workspaceBarManager.toggleShellSystemStats(preferring: [pointer, main].compactMap(\.self) + monitors)
    }

    func openCommandPalette(mode: CommandPaletteMode? = nil) {
        commandPaletteController.toggle(wmController: self, mode: mode)
    }

    func clipboardPaletteItems() -> [ClipboardPaletteItem] {
        clipboardHistoryService.paletteItems
    }

    func setClipboardHistoryEnabled(_ enabled: Bool) {
        settings.clipboard.historyEnabled = enabled
        syncClipboardHistoryService()
    }

    func copyClipboardItem(id: UUID, plainText: Bool = false) async -> Bool {
        await clipboardHistoryService.copyItemToPasteboard(id: id, plainText: plainText)
    }

    func clipboardItemPreview(id: UUID) async -> ClipboardPalettePreview? {
        await clipboardHistoryService.preview(id: id)
    }

    func setClipboardItemPinned(_ pinned: Bool, id: UUID) async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.setPinned(pinned, id: id)
    }

    func deleteClipboardItem(id: UUID) async -> [ClipboardPaletteItem] {
        await clipboardHistoryService.deleteItem(id: id)
    }

    func clearClipboardHistory() async throws -> [ClipboardPaletteItem] {
        try await clipboardHistoryService.clearHistory()
    }

    func syncClipboardHistoryService() {
        clipboardHistoryService.updateConfiguration(clipboardHistoryConfiguration())
    }

    func openSponsorsWindow() {
        sponsorsWindowController.show()
    }

    func openMenuAnywhere() {
        windowActionHandler.openMenuAnywhere()
    }

    @discardableResult
    func navigateToCommandPaletteWindow(_ handle: WindowHandle) -> Bool {
        windowActionHandler.navigateToExplicitlySelectedWindow(handle: handle)
    }

    func summonCommandPaletteWindowRight(
        _ handle: WindowHandle,
        anchorToken: WindowToken,
        anchorWorkspaceId: WorkspaceDescriptor.ID
    ) {
        windowActionHandler.summonWindowRight(
            handle: handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    func toggleOverview() {
        windowActionHandler.toggleOverview()
    }

    func setOverviewEnabled(_ enabled: Bool) {
        if settings.overview.enabled != enabled {
            settings.overview.enabled = enabled
        }
        if !enabled {
            windowActionHandlerStorage?.releaseOverviewController()
        }
        updateHotkeyBindings(settings.hotkeyBindings)
    }

    func handleOverviewHotkey(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        windowActionHandlerStorage?.handleOverviewHotkey(invocation) ?? .inactive
    }

    func updateOverviewSettings() {
        windowActionHandlerStorage?.updateOverviewSettings()
    }

    func isOverviewOpen() -> Bool {
        windowActionHandler.isOverviewOpen()
    }
}
