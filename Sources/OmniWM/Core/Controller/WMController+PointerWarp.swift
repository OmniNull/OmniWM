// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    func resetMouseWarpTransientState() {
        mouseWarpHandler.resetTransientState()
        pointerEdgeBarrier.reset()
        publishPointerEdgeTopology()
    }

    func publishPointerEdgeTopology() {
        let monitors = workspaceManager.monitors
        var topology = PointerEdgeTopology()
        topology.isEnabled = isEnabled && settings.pointer.enabled && monitors.count > 1
            && !mouseEventHandler.isInputSuppressed
        guard topology.isEnabled else {
            pointerEdgeBarrier.publish(topology)
            return
        }
        topology.margin = CGFloat(settings.pointer.margin)
        topology.flipY = NSScreen.screens.first?.frame.maxY ?? 0
        topology.monitors = monitors
        if settings.pointer.constrainToArrangement, settings.monitors.routingMode == .custom {
            topology.containment = MouseContainment(
                layout: MonitorRouting.layout(for: monitors, in: settings.monitors.arrangements),
                monitors: monitors
            )
        }
        let fins = surfaceReconciler.pointerEdgeFinSpans()
        let grid = workspaceManager.monitorRoutingGrid()
        for monitor in monitors {
            for direction in [Direction.left, .right, .up, .down] {
                let side: ParkingEdgeMaskKey.Side = switch direction {
                case .left: .left
                case .right: .right
                case .up: .top
                case .down: .bottom
                }
                let target = workspaceManager.adjacentMonitor(from: monitor.id, direction: direction, grid: grid)
                let fin = fins[ParkingEdgeMaskKey(monitorId: monitor.id, side: side)]
                guard target != nil || fin != nil else { continue }
                topology.edges[.init(monitorId: monitor.id, direction: direction)] = .init(target: target, finSpan: fin)
            }
        }
        pointerEdgeBarrier.publish(topology)
    }

    func screen(for monitorId: Monitor.ID) -> NSScreen? {
        guard let monitor = workspaceManager.monitor(byId: monitorId) else { return nil }
        return NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
    }

    func moveMouseToWindow(_ handle: WindowHandle, preferredFrame: CGRect? = nil) {
        moveMouseToWindow(handle.id, preferredFrame: preferredFrame)
    }

    func moveMouseToWindow(_ token: WindowToken, preferredFrame: CGRect? = nil) {
        guard !axEventHandler.suppressesMouseWarp(for: token) else {
            MouseTrace.record("focus-warp suppressed (pointer-intent) token=\(token)")
            return
        }
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard let frame = preferredFrame ?? entry.axRef.flatMap(AXWindowService.framePreferFast)
            ?? shellAppWindowManager.frame(for: token)
        else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            MouseTrace.record("focus-warp suppressed (off-screen) token=\(token) center=\(TraceFormat.point(center))")
            return
        }

        let mouse = currentMouseLocation()
        guard !frame.contains(mouse) else {
            MouseTrace.record(
                "focus-warp suppressed (cursor-inside) token=\(token) mouse=\(TraceFormat.point(mouse))"
            )
            return
        }

        MouseTrace.record("focus-warp token=\(token) center=\(TraceFormat.point(center))")
        warpMouseCursorPosition(ScreenCoordinateSpace.toWindowServer(point: center))
        mouseWarpHandler.noteProgrammaticCursorMove(to: center)
    }
}
