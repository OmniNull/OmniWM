// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func innerGap(for monitor: Monitor) -> CGFloat {
        innerGap(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func innerGap(for monitor: Monitor, scale: CGFloat) -> CGFloat {
        let key = InnerGapCacheEntry.Key(
            monitor: monitor, scale: scale, revision: settings.layoutConfigurationRevision,
            runtimeGap: workspaceManager.gaps
        )
        if let cachedInnerGap, cachedInnerGap.key == key { return cachedInnerGap.value }
        let rawGap = settings.gaps.settings(for: monitor)?.innerGap == nil
            ? CGFloat(workspaceManager.gaps)
            : settings.gaps.resolved(for: monitor).innerGap
        let value = max(rawGap, borderClearance(scale: scale))
        cachedInnerGap = InnerGapCacheEntry(key: key, value: value)
        return value
    }

    func innerGap(for workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else {
            return CGFloat(workspaceManager.gaps)
        }
        return innerGap(for: monitor)
    }

    func resolvedDwindleSettings(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func resolvedDwindleSettings(for monitor: Monitor, scale: CGFloat) -> ResolvedDwindleSettings {
        let resolved = settings.dwindle.resolved(for: monitor)
        return ResolvedDwindleSettings(
            smartSplit: resolved.smartSplit,
            defaultSplitRatio: resolved.defaultSplitRatio,
            splitWidthMultiplier: resolved.splitWidthMultiplier,
            singleWindowFit: resolved.singleWindowFit,
            useGlobalGaps: resolved.useGlobalGaps,
            innerGap: max(resolved.innerGap, borderClearance(scale: scale))
        )
    }

    func layoutFrames(
        for monitor: Monitor,
        scale: CGFloat
    ) -> MonitorLayoutFrames {
        let key = MonitorLayoutCacheEntry.Key(
            monitor: monitor, scale: scale, revision: settings.layoutConfigurationRevision
        )
        if let cachedMonitorLayout, cachedMonitorLayout.key == key { return cachedMonitorLayout.value }
        let value = buildLayoutFrames(for: monitor, scale: scale)
        cachedMonitorLayout = MonitorLayoutCacheEntry(key: key, value: value)
        return value
    }

    private func buildLayoutFrames(for monitor: Monitor, scale: CGFloat) -> MonitorLayoutFrames {
        let bar = workspaceBarBaseReservedInsets(for: monitor)
        let room = workspaceBarRoom(for: monitor)
        let reserved = room.map { roomReservedInsets($0, bar: bar, monitor: monitor) } ?? bar
        let gaps = settings.gaps.resolved(for: monitor)
        let menuBarInset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        let normalizedTop = normalizedTopStrut(
            top: gaps.outerGapTop,
            menuBarInset: menuBarInset,
            reservedTopInset: bar.top
        )
        var rawStruts = Struts(
            left: gaps.outerGapLeft + bar.left,
            right: gaps.outerGapRight + bar.right,
            top: normalizedTop,
            bottom: gaps.outerGapBottom + bar.bottom
        )
        let clearance = borderClearance(scale: scale)
        let roomed = room.map { roomLayoutStruts($0, base: rawStruts, bar: bar, monitor: monitor, scale: scale) }
        if let roomed { rawStruts = roomed.struts }
        let effectiveStruts = Struts(
            left: max(rawStruts.left, clearance),
            right: max(rawStruts.right, clearance),
            top: max(rawStruts.top, clearance),
            bottom: max(rawStruts.bottom, clearance)
        )
        let rawWorkingFrame = computeWorkingArea(parentArea: monitor.visibleFrame, scale: scale, struts: rawStruts)
        let workingFrame = computeWorkingArea(parentArea: monitor.visibleFrame, scale: scale, struts: effectiveStruts)
        let fullscreenLayoutFrame: CGRect
        let borderSafeFillFrame: CGRect
        if gaps.fullscreenUsesOuterGaps {
            fullscreenLayoutFrame = rawWorkingFrame
            borderSafeFillFrame = workingFrame
        } else {
            (fullscreenLayoutFrame, borderSafeFillFrame) = ungappedFullscreenFrames(
                for: monitor, scale: scale, reserved: reserved, clearance: clearance
            )
        }
        return MonitorLayoutFrames(
            workingFrame: workingFrame,
            borderSafeFillFrame: borderSafeFillFrame,
            fullscreenLayoutFrame: fullscreenLayoutFrame,
            roomGapLimits: roomed?.gapLimits ?? [:]
        )
    }

    func niriInteractionGeometry(
        for monitor: Monitor
    ) -> NiriInteractionGeometry {
        niriInteractionGeometry(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func niriInteractionGeometry(
        for monitor: Monitor,
        scale: CGFloat
    ) -> NiriInteractionGeometry {
        let gap = innerGap(for: monitor, scale: scale)
        let frames = layoutFrames(for: monitor, scale: scale)
        return NiriInteractionGeometry(
            workingFrame: niriWorkingFrame(frames.workingFrame, roomGapLimits: frames.roomGapLimits, gap: gap),
            innerGap: gap,
            scale: scale
        )
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).workingFrame
    }

    func niriWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        let frames = layoutFrames(for: monitor, scale: scale)
        return niriWorkingFrame(
            frames.workingFrame, roomGapLimits: frames.roomGapLimits, gap: innerGap(for: monitor, scale: scale)
        )
    }

    func niriWorkingFrame(
        _ workingFrame: CGRect, roomGapLimits: [WorkspaceBarRoom.Edge: CGFloat], gap: CGFloat
    ) -> CGRect {
        guard settings.niri.edgeGaps else { return workingFrame.insetBy(dx: -gap, dy: -gap) }
        var frame = workingFrame
        for (edge, limit) in roomGapLimits {
            let outset = min(gap, limit)
            switch edge {
            case .left:
                frame.origin.x -= outset
                frame.size.width += outset
            case .right: frame.size.width += outset
            case .bottom:
                frame.origin.y -= outset
                frame.size.height += outset
            case .top: frame.size.height += outset
            }
        }
        return frame
    }

    func niriFullscreenLayoutFrame(
        _ fullscreenLayoutFrame: CGRect,
        workingFrame: CGRect,
        roomGapLimits: [WorkspaceBarRoom.Edge: CGFloat],
        monitor: Monitor,
        gap: CGFloat
    ) -> CGRect {
        guard settings.gaps.resolved(for: monitor).fullscreenUsesOuterGaps else { return fullscreenLayoutFrame }
        return niriWorkingFrame(workingFrame, roomGapLimits: roomGapLimits, gap: gap).insetBy(dx: gap, dy: gap)
    }

    func fullscreenLayoutFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).fullscreenLayoutFrame
    }

    func borderSafeFillFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).borderSafeFillFrame
    }

    func backingScaleFactor(for monitor: Monitor) -> CGFloat {
        layoutRefreshController.backingScale(for: monitor)
    }

    private func borderClearance(scale: CGFloat) -> CGFloat {
        BorderConfig.layoutClearance(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width),
            scale: scale
        )
    }

    func workspaceBarReservedInsets(for monitor: Monitor) -> Struts {
        let bar = workspaceBarBaseReservedInsets(for: monitor)
        guard let room = workspaceBarRoom(for: monitor) else { return bar }
        return roomReservedInsets(room, bar: bar, monitor: monitor)
    }

    private func workspaceBarBaseReservedInsets(for monitor: Monitor) -> Struts {
        guard settings.workspaceBar.resolvedRevealModifier == .off else { return .zero }
        let resolved = settings.workspaceBar.resolved(for: monitor)
        return WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarConfiguredVisible(on: monitor, resolved: resolved)
        ).reservedInsets
    }

    private func workspaceBarRoom(for monitor: Monitor) -> WorkspaceBarRoom? {
        guard settings.island.enabled, let room = settings.workspaceBar.profileOverride?.room,
              room.includes(monitor), isWorkspaceBarEnabled(
                  on: monitor,
                  resolved: settings.workspaceBar.resolved(for: monitor)
              )
        else { return nil }
        return room
    }

    private func roomValue(_ reservation: WorkspaceBarRoom.Reservation, monitor: Monitor) -> CGFloat {
        let clear: CGFloat = switch reservation.clear {
        case .none: 0
        case .notch: monitor.hasNotch && monitor.notchRange != nil ? monitor.notchHeight : 0
        case .menuBar: max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        }
        return reservation.value + clear
    }

    private func roomReservedInsets(_ room: WorkspaceBarRoom, bar: Struts, monitor: Monitor) -> Struts {
        var result = bar
        let inset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        for (edge, reservation) in room.edges {
            let value = max(0, roomValue(reservation, monitor: monitor) - (edge == .top ? inset : 0))
            switch reservation.mode {
            case .add: result[keyPath: edge.strut] += value
            case .total: result[keyPath: edge.strut] = value
            }
        }
        if let dock = room.dock {
            result[keyPath: dock.edge.strut] = max(
                bar[keyPath: dock.edge.strut], result[keyPath: dock.edge.strut],
                dock.value - (dock.edge == .top ? inset : 0)
            )
        }
        return result
    }

    private func roomLayoutStruts(
        _ room: WorkspaceBarRoom, base: Struts, bar: Struts, monitor: Monitor, scale: CGFloat
    ) -> (struts: Struts, gapLimits: [WorkspaceBarRoom.Edge: CGFloat]) {
        var result = base
        var limits: [WorkspaceBarRoom.Edge: CGFloat] = [:]
        let inset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        let clearance = borderClearance(scale: scale)
        for (edge, reservation) in room.edges {
            let value = roomValue(reservation, monitor: monitor)
            switch reservation.mode {
            case .add where edge == .top:
                result.top = normalizedTopStrut(
                    top: settings.gaps.resolved(for: monitor).outerGapTop + value,
                    menuBarInset: inset, reservedTopInset: bar.top
                )
            case .add: result[keyPath: edge.strut] += value
            case .total:
                result[keyPath: edge.strut] = max(clearance, value - (edge == .top ? inset : 0))
                limits[edge] = .infinity
            }
        }
        if let dock = room.dock {
            let strut = dock.edge.strut
            let exact = limits[dock.edge] != nil && result[keyPath: strut] >= base[keyPath: strut]
            let floor = max(base[keyPath: strut], result[keyPath: strut])
            let value = dock.value - (dock.edge == .top ? inset : 0)
            result[keyPath: strut] = max(floor, value)
            let gapFloor = max(clearance, floor)
            limits[dock.edge] = exact ? .infinity : value > gapFloor ? value - gapFloor : nil
        }
        return (result, limits)
    }

    private func ungappedFullscreenFrames(
        for monitor: Monitor,
        scale: CGFloat,
        reserved: Struts,
        clearance: CGFloat
    ) -> (layout: CGRect, borderSafe: CGRect) {
        let layout = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: reserved
        )
        let borderSafe = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: Struts(
                left: max(reserved.left, clearance),
                right: max(reserved.right, clearance),
                top: max(reserved.top, clearance),
                bottom: max(reserved.bottom, clearance)
            )
        )
        return (layout, borderSafe)
    }
}

extension WorkspaceBarRoom.Edge {
    fileprivate var strut: WritableKeyPath<Struts, CGFloat> {
        switch self {
        case .top: \.top
        case .left: \.left
        case .right: \.right
        case .bottom: \.bottom
        }
    }
}

extension Struts {
    var ipcInsets: IPCInsets {
        IPCInsets(top: Double(top), left: Double(left), bottom: Double(bottom), right: Double(right))
    }
}
