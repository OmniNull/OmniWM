// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct WindowSwitcherItem {
    let handle: WindowHandle
    let title: String
    let appName: String
    let icon: NSImage?
    var workspaceName: String
}

@MainActor
final class WindowSwitcherController {
    private weak var controller: WMController?
    private let panel: WindowSwitcherPanel
    private let capture: OverviewThumbnailCapture
    private var items: [WindowSwitcherItem] = []
    private var selection = WindowSwitcherSelection()
    private var workspaceId: WorkspaceDescriptor.ID?
    private var scope = WindowSwitcherScope.allWorkspaces
    private var screenFrame = CGRect.zero
    private var scale: CGFloat = 2
    private let dismissalMonitor = PanelDismissalMonitor()
    private var generation: UInt64 = 0
    private(set) var isVisible = false

    init(controller: WMController) {
        self.controller = controller
        panel = WindowSwitcherPanel(ownedWindowRegistry: controller.ownedWindowRegistry)
        capture = OverviewThumbnailCapture(
            environment: OverviewEnvironment(),
            ownedWindowRegistry: controller.ownedWindowRegistry,
            consumer: .windowSwitcher
        )
        capture.onPreview = { [weak self] handle, frame in
            self?.panel.updatePreview(frame, for: handle)
        }
        capture.onReadinessChange = { [weak self] in
            guard let self, isVisible else { return }
            panel.setCapturePending(capture.hasPendingFirstFrames)
        }
        panel.onSelect = { [weak self] token in
            self?.selection.select(token)
            self?.commit()
        }
        panel.onToggleScope = { [weak self] in self?.handle(.toggleScope) }
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
        case .toggleScope:
            guard isVisible else { return }
            scope = scope == .allWorkspaces ? .activeWorkspace : .allWorkspaces
            controller?.settings.windowSwitcher.scope = scope
            reconcileItems()
            render()
        case .commit:
            commit()
        case .cancel:
            dismiss()
        }
    }

    private func begin(reverse: Bool, initialScope: WindowSwitcherScope?) {
        guard let controller, controller.hotkeysEnabled, controller.settings.windowSwitcher.enabled,
              !controller.isLockScreenActive,
              !controller.isOverviewOpen(), !controller.commandPaletteController.isVisible,
              let monitor = controller.monitorForInteraction()
        else {
            dismiss()
            return
        }
        workspaceId = controller.activeWorkspace()?.id
        scope = initialScope ?? controller.settings.windowSwitcher.scope
        screenFrame = monitor.visibleFrame
        scale = NSScreen.screens.first { $0.displayId == monitor.displayId }?.backingScaleFactor ?? 2
        let current = controller.focusedOrFrontmostWindowTokenForAutomation(
            preferFrontmostWhenExternalOrOwnedFocusActive: true
        )
        items = buildItems(controller: controller, current: current)
        selection.begin(tokens: scopedItems().map { $0.handle.id }, current: current, reverse: reverse)
        isVisible = true
        controller.focusPolicyEngine.beginLease(owner: .windowSwitcher, reason: "window_switcher", duration: nil)
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { _ in false },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        render()
    }

    private func buildItems(controller: WMController, current: WindowToken?) -> [WindowSwitcherItem] {
        let recency = [current].compactMap { $0 } + controller.workspaceManager.windowFocusRecencyOrder
        let ranks = Dictionary(recency.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return controller.workspaceManager.allEntries().compactMap { entry -> WindowSwitcherItem? in
            guard !entry.observedState.isNativeSuppressed,
                  let handle = controller.workspaceManager.handle(for: entry.token),
                  let workspace = controller.workspaceManager.descriptor(for: entry.workspaceId)
            else { return nil }
            let app = controller.appInfoCache.info(for: entry.pid)
            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""
            return WindowSwitcherItem(
                handle: handle,
                title: title.isEmpty ? (app?.name ?? String(localized: "Window")) : title,
                appName: app?.name ?? String(localized: "Unknown"),
                icon: app?.icon,
                workspaceName: controller.settings.workspaces.displayName(for: workspace.name)
            )
        }.sorted {
            let left = ranks[$0.handle.id] ?? Int.max
            let right = ranks[$1.handle.id] ?? Int.max
            if left != right { return left < right }
            if $0.appName != $1.appName { return $0.appName < $1.appName }
            return $0.handle.id.windowId < $1.handle.id.windowId
        }
    }

    private func scopedItems() -> [WindowSwitcherItem] {
        guard let controller else { return [] }
        let manager = controller.workspaceManager
        return items.compactMap { item in
            guard manager.handle(for: item.handle.id) === item.handle,
                  let entry = manager.entry(for: item.handle),
                  !entry.observedState.isNativeSuppressed,
                  scope == .allWorkspaces || entry.workspaceId == workspaceId,
                  let workspace = manager.descriptor(for: entry.workspaceId)
            else { return nil }
            var item = item
            item.workspaceName = controller.settings.workspaces.displayName(for: workspace.name)
            return item
        }
    }

    private func reconcileItems() {
        selection.reconcile(tokens: scopedItems().map { $0.handle.id })
    }

    private func render() {
        guard let controller else { return }
        let visibleItems = scopedItems()
        let hasCaptureAccess = CGPreflightScreenCaptureAccess()
        let displayed = panel.show(
            content: WindowSwitcherPanel.Content(
                items: visibleItems,
                selected: selection.selected,
                scope: scope,
                hasCaptureAccess: hasCaptureAccess,
                showsFooter: controller.settings.windowSwitcher.showFooter
            ),
            screenFrame: screenFrame,
            cachedPreview: capture.preview(for:)
        )
        capture.reconcile(
            represented: Set(visibleItems.map(\.handle)),
            visible: displayed.map {
                OverviewPreviewRequest(handle: $0.handle, pixelWidth: Int(220 * scale), pixelHeight: Int(150 * scale))
            },
            prioritizing: displayed.first { $0.handle.id == selection.selected }?.handle,
            firstFrameOnly: true
        )
    }

    private func commit() {
        guard isVisible else { return }
        let target = scopedItems().first { $0.handle.id == selection.selected }?.handle
        dismiss()
        guard let target, let controller else { return }
        _ = controller.windowActionHandler.activateExplicitlySelectedWindow(handle: target)
    }

    func dismiss() {
        controller?.hotkeys.cancelWindowSwitcherSession(generation: generation)
        guard isVisible else { return }
        isVisible = false
        panel.hide()
        controller?.focusPolicyEngine.endLease(owner: .windowSwitcher)
        capture.clear()
        capture.releaseCache()
        items.removeAll()
        selection = WindowSwitcherSelection()
        dismissalMonitor.stop()
    }
}
