// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct WindowSwitcherItem {
    let handle: WindowHandle
    var title: String
    let appName: String
    let icon: NSImage?
    var workspaceName: String
    var isMinimized: Bool
}

@MainActor
final class WindowSwitcherController {
    private weak var controller: WMController?
    private let panel: WindowSwitcherPanel
    private let capture: OverviewThumbnailCapture
    private var previews = WindowSwitcherPreviews()
    private var previewHandles: [WindowHandle] = []
    private var isReconcilingPreviews = false
    private var items: [WindowSwitcherItem] = []
    private var selection = WindowSwitcherSelection()
    private var workspaceId: WorkspaceDescriptor.ID?
    private var visibleWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    private var scope = WindowSwitcherScope.allWorkspaces
    private var screenFrame = CGRect.zero
    private var scale: CGFloat = 2
    private let dismissalMonitor = PanelDismissalMonitor()
    private var generation: UInt64 = 0
    private let modifierFlags: () -> CGEventFlags
    private let armExternalSession: @MainActor (HotkeyCenter, CGEventFlags) -> UInt64?
    private(set) var isVisible = false

    init(
        controller: WMController,
        previewCapture: OverviewThumbnailCapture? = nil,
        modifierFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
        armExternalSession: @escaping @MainActor (HotkeyCenter, CGEventFlags) -> UInt64? = {
            $0.beginExternalWindowSwitcherSession(holding: $1)
        }
    ) {
        self.controller = controller
        self.modifierFlags = modifierFlags
        self.armExternalSession = armExternalSession
        panel = WindowSwitcherPanel(ownedWindowRegistry: controller.ownedWindowRegistry)
        capture = previewCapture ?? OverviewThumbnailCapture(consumer: .windowSwitcher)
        capture.onPreview = { [weak self] handle, frame in
            guard let self, isVisible else { return }
            panel.updatePreview(previews.preview(for: handle, candidate: frame), for: handle)
        }
        capture.onReadinessChange = { [weak self] in
            self?.presentWhenReady()
        }
        panel.onSelect = { [weak self] token in
            self?.selection.select(token)
            self?.commit(focusOrigin: .pointerSelection)
        }
        panel.onCycleScope = { [weak self] in self?.handle(.cycleScope) }
        panel.onClose = { [weak self] token in self?.close(token) }
        panel.onVisibleItemsChanged = { [weak self] displayed in self?.captureVisibleItems(displayed) }
    }

    func handle(_ action: WindowSwitcherAction, generation: UInt64? = nil) {
        if case .begin = action {
            if isVisible { dismiss() }
            if let generation { self.generation = generation }
        } else if let generation, generation != self.generation {
            return
        }
        switch action {
        case let .begin(reverse, initialScope):
            begin(reverse: reverse, initialScope: initialScope)
        case let .cycle(reverse):
            guard isVisible else { return }
            let previous = selection.selected
            reconcileItems()
            if selection.selected == previous { selection.cycle(reverse: reverse) }
            render()
        case .cycleScope:
            guard isVisible else { return }
            scope = scope.next(offeringVisibleWorkspaces: visibleScopeAddsWorkspaces)
            controller?.settings.windowSwitcher.scope = scope
            reconcileItems()
            render()
        case let .moveRow(reverse):
            guard isVisible else { return }
            reconcileItems()
            selection.moveRow(columns: panel.columns, reverse: reverse)
            render()
        case .close:
            if let token = selection.selected { close(token) }
        case .commit:
            commit(focusOrigin: .keyboardOrProgrammatic)
        case .cancel:
            dismiss()
        }
    }

    private func begin(reverse: Bool, initialScope: WindowSwitcherScope?) {
        guard let controller, controller.settings.windowSwitcher.enabled,
              !controller.isLockScreenActive,
              !controller.isOverviewOpen(), !controller.commandPaletteController.isVisible,
              let monitor = controller.monitorForInteraction()
        else {
            dismiss()
            return
        }
        workspaceId = controller.activeWorkspace()?.id
        visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
        scope = initialScope ?? controller.settings.windowSwitcher.scope
        screenFrame = monitor.visibleFrame
        scale = NSScreen.screens.first { $0.displayId == monitor.displayId }?.backingScaleFactor ?? 2
        let current = controller.focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenExternalOrOwnedFocusActive: true
        ).map { listedToken($0, manager: controller.workspaceManager) }
        items = buildItems(controller: controller)
        selection.begin(
            tokens: scopedItems().map { $0.handle.id }, current: current, reverse: reverse,
            recent: listedRecency(manager: controller.workspaceManager)
        )
        isVisible = true
        controller.focusPolicyEngine.beginLease(owner: .windowSwitcher, reason: "window_switcher", duration: nil)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { _ in false },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        render()
    }

    private func buildItems(controller: WMController) -> [WindowSwitcherItem] {
        return controller.workspaceManager.allEntries().compactMap { entry -> WindowSwitcherItem? in
            guard !entry.observedState.isNativeWithdrawn,
                  entry.target.hostedMetadata?.role.isSheet != true,
                  let handle = controller.workspaceManager.handle(for: entry.token),
                  let workspace = controller.workspaceManager.descriptor(for: entry.workspaceId)
            else { return nil }
            let presentation = controller.appInfoCache.presentation(
                for: entry, title: AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
            )
            let title = presentation.title ?? ""
            return WindowSwitcherItem(
                handle: handle,
                title: title.isEmpty ? (presentation.name ?? String(localized: "Window")) : title,
                appName: presentation.name ?? String(localized: "Unknown"),
                icon: presentation.icon,
                workspaceName: controller.settings.workspaces.displayName(for: workspace.name),
                isMinimized: entry.observedState.isMinimized
            )
        }
    }

    private func scopedItems() -> [WindowSwitcherItem] {
        guard let controller else { return [] }
        let manager = controller.workspaceManager
        let byToken = Dictionary(uniqueKeysWithValues: items.map { ($0.handle.id, $0) })
        let scoped = manager.workspaces.filter { workspace in
            switch scope {
            case .allWorkspaces: true
            case .visibleWorkspaces: visibleWorkspaceIds.contains(workspace.id)
            case .activeWorkspace: workspace.id == workspaceId
            }
        }
        .flatMap { workspace in
            orderedEntries(in: workspace.id, manager: manager).compactMap { entry -> WindowSwitcherItem? in
                guard !entry.observedState.isNativeWithdrawn,
                      var item = byToken[entry.token],
                      manager.handle(for: entry.token) === item.handle
                else { return nil }
                item.workspaceName = controller.settings.workspaces.displayName(for: workspace.name)
                item.isMinimized = entry.observedState.isMinimized
                if let metadata = entry.target.hostedMetadata {
                    item.title = metadata.title
                    if metadata.role == .main,
                       controller.shellAppWindowManager.activeSheet(for: entry.token) != nil
                    {
                        item.title += " — " + String(localized: "Dialog open")
                    }
                }
                return item
            }
        }
        guard controller.settings.windowSwitcher.order == .lastUsed else { return scoped }
        return WindowSwitcherOrder.lastUsed.orderedItems(scoped, recent: listedRecency(manager: manager))
    }

    private func listedToken(_ token: WindowToken, manager: WorkspaceManager) -> WindowToken {
        guard let role = manager.entry(for: token)?.target.hostedMetadata?.role, role.isSheet else { return token }
        return manager.hostedFamilyRoot(for: token) ?? token
    }

    private func listedRecency(manager: WorkspaceManager) -> [WindowToken] {
        var seen: Set<WindowToken> = []
        return manager.windowFocusRecencyOrder.map { listedToken($0, manager: manager) }
            .filter { seen.insert($0).inserted }
    }

    private func orderedEntries(in workspaceId: WorkspaceDescriptor.ID, manager: WorkspaceManager) -> [WindowState] {
        let entries = manager.entries(in: workspaceId)
        if manager.activeLayoutKind(for: workspaceId) == .dwindle,
           let root = manager.dwindleEngine?.root(for: workspaceId)
        {
            let byToken = Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) })
            var seen: Set<WindowToken> = []
            return (root.collectAllWindows() + entries.map(\.token)).compactMap { token in
                guard seen.insert(token).inserted else { return nil }
                return byToken[token]
            }
        }
        return WorkspaceEntryOrdering.orderedEntries(
            consume entries,
            topology: manager.layoutTopology(for: workspaceId)
        )
    }

    private func reconcileItems() {
        selection.reconcile(tokens: scopedItems().map { $0.handle.id })
    }

    private func render() {
        guard let controller else { return }
        let visibleItems = scopedItems()
        let hasCaptureAccess = ScreenCapturePermissionMonitor.shared.isGranted
        panel.prepare(
            content: WindowSwitcherPanel.Content(
                items: visibleItems,
                selected: selection.selected,
                scope: scope,
                hasCaptureAccess: hasCaptureAccess,
                showsFooter: controller.settings.windowSwitcher.showFooter
            ),
            screenFrame: screenFrame
        )
    }

    private func captureVisibleItems(_ displayed: [WindowSwitcherItem]) {
        guard isVisible, let controller else { return }
        previewHandles = displayed.filter { !$0.isMinimized }.map(\.handle)
        isReconcilingPreviews = true
        defer {
            isReconcilingPreviews = false
            presentWhenReady()
        }
        guard ScreenCapturePermissionMonitor.shared.isGranted else {
            previews.removeAll()
            capture.clear()
            capture.releaseCache()
            return
        }
        for item in displayed {
            panel.updatePreview(
                previews.preview(for: item.handle, candidate: capture.preview(for: item.handle)),
                for: item.handle
            )
        }
        capture.reconcile(
            represented: Set(controller.workspaceManager.allEntries().compactMap {
                controller.workspaceManager.handle(for: $0.token)
            }),
            visible: displayed.filter { !$0.isMinimized }.map {
                OverviewPreviewRequest(handle: $0.handle, pixelWidth: Int(220 * scale), pixelHeight: Int(180 * scale))
            },
            prioritizing: displayed.first { $0.handle.id == selection.selected }?.handle,
            firstFrameOnly: true
        )
    }

    private func presentWhenReady() {
        guard isVisible, !isReconcilingPreviews else { return }
        let pending = capture.hasPendingFirstFrames
        panel.setCapturePending(pending)
        guard previews.isReady(for: previewHandles) || !pending else { return }
        panel.present()
    }

    func refreshWindows() {
        guard isVisible else { return }
        reconcileItems()
        render()
    }

    private func close(_ token: WindowToken) {
        guard isVisible, let controller,
              let target = scopedItems().first(where: { $0.handle.id == token })
        else { return }
        selection.select(token)
        render()
        if !controller.windowActionHandler.closeWindow(handle: target.handle) { NSSound.beep() }
    }

    private func commit(focusOrigin: ManagedFocusOrigin) {
        guard isVisible else { return }
        let target = scopedItems().first { $0.handle.id == selection.selected }?.handle
        dismiss()
        guard let target else { return }
        activate(target, focusOrigin: focusOrigin)
    }

    private func activate(_ target: WindowHandle, focusOrigin: ManagedFocusOrigin) {
        guard let controller else { return }
        if !controller.windowActionHandler.focusWindowFromBar(handle: target, focusOrigin: focusOrigin) {
            NSSound.beep()
        }
    }

    func shutdown() {
        dismiss()
        capture.releaseCache(reason: .shutdown)
        panel.close()
    }

    func dismiss() {
        controller?.hotkeys.cancelWindowSwitcherSession(generation: generation)
        capture.clear()
        if controller?.settings.windowSwitcher.enabled != true || controller?.isLockScreenActive == true {
            capture.releaseCache()
        }
        items.removeAll()
        previews.removeAll()
        previewHandles.removeAll()
        selection = WindowSwitcherSelection()
        guard isVisible else { return }
        isVisible = false
        panel.hide()
        controller?.focusPolicyEngine.endLease(owner: .windowSwitcher)
        dismissalMonitor.stop()
    }
}

extension WindowSwitcherController {
    private var visibleScopeAddsWorkspaces: Bool {
        if let workspaceId, visibleWorkspaceIds.contains(workspaceId) {
            return visibleWorkspaceIds.count > 1
        }
        return !visibleWorkspaceIds.isEmpty
    }

    func advanceFromAutomation(reverse: Bool, scope: WindowSwitcherScope?) {
        guard !isVisible else {
            handle(.cycle(reverse: reverse))
            return
        }
        guard let hotkeys = controller?.hotkeys else { return }
        let held = modifierFlags().intersection(WindowSwitcherInput.releaseModifiers)
        let sessionGeneration = held.isEmpty ? nil : armExternalSession(hotkeys, held)
        handle(.begin(reverse: reverse, scope: scope), generation: sessionGeneration)
        let releasedBeforeTapArmed = !modifierFlags().contains(held)
        if sessionGeneration == nil || releasedBeforeTapArmed { handle(.commit) }
    }
}
