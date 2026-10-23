// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct WorldView {
    private let controller: WMController
    private let liveBoundsProvider: ((Int) -> CGRect?)?

    /// Creates a world view over the window-manager controller.
    /// - Parameters:
    ///   - controller: The window manager this view reads state from.
    ///   - liveBoundsProvider: Injectable source of live window bounds (defaults to
    ///     querying the WindowServer); lets tests supply synthetic bounds.
    init(
        controller: WMController,
        liveBoundsProvider: ((Int) -> CGRect?)? = nil
    ) {
        self.controller = controller
        self.liveBoundsProvider = liveBoundsProvider
    }

    var hasStartedServices: Bool {
        controller.hasStartedServices
    }

    var monitors: [Monitor] {
        controller.workspaceManager.monitors
    }

    var renderableFocusToken: WindowToken? {
        controller.workspaceManager.renderableFocusToken
    }

    var borderFocusToken: WindowToken? {
        controller.workspaceManager.borderFocusToken
    }

    var suppressedFocusToken: WindowToken? {
        controller.workspaceManager.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        controller.workspaceManager.systemModalFocusToken
    }

    func hasPendingNativeFullscreenTransition(for token: WindowToken) -> Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition(for: token)
    }

    func hasPendingNativeFullscreenTransition(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.hasPendingNativeFullscreenTransition(in: workspaceId)
    }

    var spaceTopology: SpaceTopology {
        controller.workspaceManager.spaceTopology
    }

    var borderConfig: BorderConfig {
        controller.resolvedBorderConfig()
    }

    func entry(for token: WindowToken) -> WindowState? {
        controller.workspaceManager.entry(for: token)
    }

    func isWindowFullscreenInLayout(_ token: WindowToken) -> Bool {
        entry(for: token).map { isWindowFullscreenInLayout($0) } ?? false
    }

    func isWindowFullscreenInLayout(_ entry: borrowing WindowState) -> Bool {
        switch controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) {
        case .dwindle:
            return controller.dwindleEngine?.isWindowFullscreen(entry.token, in: entry.workspaceId) == true
        case .niri:
            return controller.niriEngine?.isWindowFullscreen(entry.token, in: entry.workspaceId) == true
        }
    }

    func isManagedWindowDisplayable(_ entry: borrowing WindowState) -> Bool {
        controller.isManagedWindowDisplayable(entry)
    }

    func hasPendingWindowClose(for entry: WindowState) -> Bool {
        controller.axEventHandler.hasPendingWindowClose(entry.token, workspaceId: entry.workspaceId)
    }

    func isWorkspaceVisible(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
    }

    func tabRailInfos() -> [TabRailInfo] {
        var infos = controller.niriLayoutHandler.desiredTabRailInfos()
        infos.append(contentsOf: controller.dwindleLayoutHandler.desiredTabRailInfos())
        return infos
    }

    var tabRailStyle: TabRailStyle {
        controller.tabRailStyle
    }

    func barSurfaces() -> [DesiredBarSurface] {
        guard controller.hasWorkspaceBarDataConsumers else { return [] }
        let settings = controller.settings
        var bars: [DesiredBarSurface] = []
        for monitor in controller.workspaceManager.monitors {
            let resolved = settings.workspaceBar.resolved(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            let projection = controller.workspaceBarProjection(
                for: monitor,
                projection: resolved.projectionOptions
            )
            bars.append(
                DesiredBarSurface(
                    monitor: monitor,
                    visible: controller.isWorkspaceBarVisible(on: monitor, resolved: resolved),
                    snapshot: WorkspaceBarSnapshot(
                        projection: projection,
                        showLabels: resolved.showLabels,
                        backgroundOpacity: resolved.backgroundOpacity,
                        transparentBackground: resolved.transparentBackground,
                        solidBlackBackground: resolved.solidBlackBackground,
                        barHeight: geometry.barHeight,
                        orientation: resolved.position.isVertical ? .vertical : .horizontal,
                        secureInputActive: controller.isSecureInputIndicated,
                        keyboardMode: controller.keyboardModeKind,
                        barFill: resolved.barFill,
                        barBorder: resolved.barBorder
                    ),
                    retainWhileHidden: controller.canAutoHideWorkspaceBar(on: monitor, resolved: resolved)
                )
            )
        }
        return bars
    }

    func niriColumnSummaries() -> [WorkspaceDescriptor.ID: NiriColumnSummary] {
        guard controller.hasWindowOrLayoutEventSubscribers else { return [:] }
        var summaries: [WorkspaceDescriptor.ID: NiriColumnSummary] = [:]
        for workspace in controller.workspaceManager.workspaces {
            summaries[workspace.id] = controller.niriLayoutHandler.columnSummary(for: workspace.id)
        }
        return summaries
    }

    func parkingEdgeMasks() -> [DesiredParkingEdgeMask] {
        var masks = SurfaceDerivation.deriveParkingEdgeMasks(monitors: monitors, spaceTopology: spaceTopology)
        guard controller.isEnabled, !controller.isOverviewOpen(),
              !controller.mouseEventHandler.isInputSuppressed,
              let engine = controller.niriEngine
        else { return masks }

        for monitor in monitors {
            guard masks.contains(where: { $0.key.monitorId == monitor.id }),
                  let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id) == .niri,
                  !hasPendingNativeFullscreenTransition(in: workspace.id)
            else { continue }
            let columns = engine.projectedColumns(in: workspace.id)
            guard !columns.isEmpty else { continue }
            let state = controller.workspaceManager.niriViewportState(for: workspace.id)
            let activeIndex = engine.projectedActiveColumnIndex(state: state, columns: columns, in: workspace.id)
            let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
            let sides: [ParkingEdgeMaskKey.Side] = orientation == .horizontal ? [.left, .right] : [.bottom, .top]
            for side in sides {
                let key = ParkingEdgeMaskKey(monitorId: monitor.id, side: side)
                let targetIndex = activeIndex + side.step
                let navigation: ParkingEdgeNavigation? = if columns.indices.contains(targetIndex),
                                                            let window = engine
                                                                .projectedActiveWindow(in: columns[targetIndex])
                {
                    ParkingEdgeNavigation(
                        workspaceId: workspace.id,
                        target: window.token,
                        hoverEnabled: controller.focusFollowsMouseEnabled
                    )
                } else {
                    nil
                }
                if let index = masks.firstIndex(where: { $0.key == key }) {
                    masks[index].navigation = navigation
                } else {
                    masks.append(DesiredParkingEdgeMask(
                        key: key, frame: side.frame(in: monitor.visibleFrame), navigation: navigation
                    ))
                }
            }
        }
        return masks
    }

    func islandSurfaces() -> [DesiredIslandSurface] {
        guard controller.settings.island.enabled else { return [] }
        let topology = spaceTopology
        return monitors.map { monitor in
            DesiredIslandSurface(
                monitor: monitor,
                fullscreen: topology.isDisplayShowingFullscreenSpace(on: monitor) == true,
                navigation: controller.workspaceBarManager.hasShellIsland(on: monitor)
                    ? islandNavigation(on: monitor) : nil
            )
        }
    }

    private func islandNavigation(on monitor: Monitor) -> IslandNavigationSnapshot? {
        let manager = controller.workspaceManager
        guard let workspace = manager.activeWorkspaceOrFirst(on: monitor.id) else { return nil }
        let entries = manager.barVisibleEntries(in: workspace.id, showFloatingWindows: true)
        var remaining = Dictionary(uniqueKeysWithValues: entries.lazy.map { ($0.token, $0) })
        var windows: [IslandNavigationSnapshot.Window] = []
        windows.reserveCapacity(entries.count)
        let layout = manager.activeLayoutKind(for: workspace.id)
        if layout == .niri {
            for (index, column) in manager.layoutTopology(for: workspace.id).columns.enumerated() {
                for tile in column.tiles {
                    if let entry = remaining.removeValue(forKey: tile.token) {
                        windows.append(islandWindow(entry, column: index + 1))
                    }
                }
            }
        }
        for entry in entries where remaining.removeValue(forKey: entry.token) != nil {
            windows.append(islandWindow(entry, column: 0))
        }
        let selected = manager.selectedManagedToken
        let remembered = manager.focusSessionSnapshot.lastFocusedByWorkspace[workspace.id]
        let focused: WindowToken? = if let selected, windows.contains(where: { $0.token == selected }) {
            selected
        } else if let remembered, windows.contains(where: { $0.token == remembered }) {
            remembered
        } else {
            nil
        }
        return IslandNavigationSnapshot(
            workspace: workspace.name,
            name: controller.settings.workspaces.displayName(for: workspace.name),
            layout: layout == .niri ? "niri" : "dwindle",
            focused: focused,
            windows: windows
        )
    }

    private func islandWindow(_ entry: WindowState, column: Int) -> IslandNavigationSnapshot.Window {
        let cache = controller.appInfoCache
        let info = cache.hasCachedInfo(for: entry.pid) ? cache.info(for: entry.pid) : nil
        let name = info?.name ?? String(localized: "Unknown")
        let title = AXWindowService.cachedTitle(windowId: UInt32(entry.windowId))
            ?? entry.managedReplacementMetadata?.title
        return IslandNavigationSnapshot.Window(
            token: entry.token,
            bundle: entry.managedReplacementMetadata?.bundleId ?? info?.bundleId ?? "",
            name: name,
            title: title ?? "",
            column: column
        )
    }

    func nativeFullscreenPlaceholders() -> [NativeFullscreenPlaceholderUpdate] {
        let workspaceManager = controller.workspaceManager
        var updates: [NativeFullscreenPlaceholderUpdate] = []
        for record in workspaceManager.nativeFullscreenRecordsByOriginalToken.values {
            let entry = workspaceManager.entry(for: record.currentToken)
            updates.append(
                NativeFullscreenPlaceholderUpdate(
                    originalToken: record.originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    windowTitle: entry?.managedReplacementMetadata?.title ?? "",
                    frame: .zero,
                    displayContext: nil,
                    selected: workspaceManager.selectedManagedToken == record.currentToken
                        || workspaceManager.pendingFocusedToken == record.currentToken,
                    visible: record.transition == .suspended
                        && entry?.layoutReason == .nativeFullscreen
                        && entry.map(isPlaceholderDescriptorVisible(entry:)) == true
                )
            )
        }
        updates.sort {
            ($0.originalToken.pid, $0.originalToken.windowId) < ($1.originalToken.pid, $1.originalToken.windowId)
        }
        return updates
    }

    private func isPlaceholderDescriptorVisible(entry: WindowState) -> Bool {
        let workspaceManager = controller.workspaceManager
        guard isWorkspaceVisible(entry.workspaceId),
              !workspaceManager.isWindowSuppressedByMacOS(entry.token),
              !workspaceManager.isHiddenInCorner(entry.token)
        else { return false }
        guard spaceTopology.isPopulated,
              let monitor = workspaceManager.monitor(for: entry.workspaceId),
              spaceTopology.isDisplayShowingFullscreenSpace(on: monitor) == false
        else { return false }
        return true
    }

    /// Resolves the frame the focused-window border ring should hug.
    /// The ring follows presentation truth: live WindowServer bounds win whenever
    /// they can be queried (apps apply AX writes late and may constrain themselves,
    /// so layout-intent frames can overlap the presented window). Pending AX writes
    /// and layout caches only backfill when live bounds are unavailable.
    /// - Returns: The frame to draw the border around, or `nil` when the window has
    ///   no usable geometry from any source.
    func borderFrame(for entry: WindowState) -> CGRect? {
        if let observed = observedWindowBounds(windowId: entry.windowId) {
            return observed
        }
        BorderOpMetricsRecorder.shared.noteBoundsQueryFallback()
        if let pending = controller.axManager.pendingFrameWrite(for: entry.windowId) {
            return pending
        }
        return cachedBorderFrame(for: entry)
    }

    func cachedBorderFrame(for entry: WindowState) -> CGRect? {
        if let pending = controller.axManager.pendingFrameWrite(for: entry.windowId) {
            return pending
        }
        if entry.mode == .floating {
            if let observed = entry.observedState.frame {
                return observed
            }
            if let desired = entry.desiredState.floatingFrame {
                return desired
            }
            if let lastFloatingFrame = entry.floatingState?.lastFrame {
                return lastFloatingFrame
            }
        } else if let applied = controller.axManager.lastAppliedFrame(for: entry.windowId) {
            return applied
        }
        return nil
    }

    /// Returns the window's live bounds in AppKit screen coordinates, or `nil` when
    /// the window has no positive-size WindowServer bounds.
    func observedWindowBounds(windowId: Int) -> CGRect? {
        if let liveBoundsProvider {
            return liveBoundsProvider(windowId)
        }
        guard windowId > 0,
              let bounds = MainThreadAXSpanTrace.measure(.borderLiveBounds, windowId: windowId, {
                  SkyLight.shared.getWindowBounds(UInt32(windowId))
              }, succeeded: { $0 != nil }),
              bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: bounds)
    }
}
