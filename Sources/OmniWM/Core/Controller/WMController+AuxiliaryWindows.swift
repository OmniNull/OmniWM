// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func invalidateOverviewDeferredActionsForServiceStop() {
        windowActionHandlerStorage?.invalidateOverviewDeferredActionsForServiceStop()
    }

    func setPreventSleepEnabled(_ enabled: Bool) {
        if enabled {
            SleepPreventionManager.shared.preventSleep()
        } else {
            SleepPreventionManager.shared.allowSleep()
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
        if enabled {
            quakeTerminalController.setup()
        } else {
            quakeTerminalController.cleanup()
        }
        updateHotkeyBindings(settings.hotkeyBindings)
    }

    func toggleQuakeTerminal() {
        guard settings.quakeTerminal.enabled else { return }
        quakeTerminalController.toggle()
    }

    func reapplyQuakeTerminalGeometryForMonitorChange() {
        guard settings.quakeTerminal.enabled else { return }
        quakeTerminalController.applyGeometryToVisibleWindow()
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
