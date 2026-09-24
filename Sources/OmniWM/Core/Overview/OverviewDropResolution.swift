// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum OverviewFloatingDestination: Equatable {
    case workspace(WorkspaceDescriptor.ID)
    case newWorkspace(Monitor.ID)
}

struct OverviewDropResolution: Equatable {
    let target: OverviewDragTarget?
    let label: String

    static var invalid: OverviewDropResolution {
        OverviewDropResolution(target: nil, label: String(localized: "Can’t drop here"))
    }
}

extension OverviewLayout {
    func resolveDrop(
        at point: CGPoint,
        draggedHandle: WindowHandle,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        floatingSize: CGSize?,
        monitor: Monitor
    ) -> OverviewDropResolution {
        guard viewportFrame.contains(point), point.y < searchBarFrame.minY else { return .invalid }
        if let floatingSize {
            return resolveFloatingDrop(at: point, size: floatingSize, monitor: monitor)
        }
        guard let target = resolveDragTarget(at: point, draggedHandle: draggedHandle) else { return .invalid }
        let label: String
        switch target {
        case .newWorkspace:
            label = String(localized: "Create workspace on \(monitor.name)")
        case .niriColumnInsert:
            label = String(localized: "New column")
        case let .niriWindowInsert(workspaceId, _, position):
            let vertical = workspaceSections.first { $0.workspaceId == workspaceId }?.orientation == .vertical
            if vertical {
                label = position == .before ? String(localized: "Stack right") : String(localized: "Stack left")
            } else {
                label = position == .before ? String(localized: "Stack above") : String(localized: "Stack below")
            }
        case let .workspaceMove(workspaceId):
            guard workspaceId != sourceWorkspaceId,
                  let section = workspaceSections.first(where: { $0.workspaceId == workspaceId })
            else { return .invalid }
            label = String(localized: "Move to workspace \(section.name)")
        case .floatingPlacement:
            return .invalid
        }
        return OverviewDropResolution(target: target, label: label)
    }

    private func resolveFloatingDrop(at point: CGPoint, size: CGSize, monitor: Monitor) -> OverviewDropResolution {
        guard size.hasFinitePositiveDimensions() else { return .invalid }
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        let destination: OverviewFloatingDestination
        let visibleFrame: CGRect
        let label: String
        if let newWorkspaceTarget, newWorkspaceTarget.frame.contains(adjustedPoint) {
            destination = .newWorkspace(newWorkspaceTarget.monitorId)
            let scale = newWorkspaceTarget.frame.height / monitor.frame.height
            visibleFrame = CGRect(
                x: newWorkspaceTarget.frame.midX - monitor.frame.width * scale / 2,
                y: newWorkspaceTarget.frame.minY,
                width: monitor.frame.width * scale,
                height: newWorkspaceTarget.frame.height
            )
            label = String(localized: "Create workspace on \(monitor.name)")
        } else if let section = workspaceSection(at: point), section.visibleFrame.contains(adjustedPoint) {
            destination = .workspace(section.workspaceId)
            visibleFrame = section.visibleFrame
            label = String(localized: "Place floating window")
        } else {
            return .invalid
        }
        let scale = visibleFrame.width / monitor.frame.width
        guard scale.isFinite, scale > 0 else { return .invalid }
        let proposed = CGRect(
            x: monitor.frame.minX + (adjustedPoint.x - visibleFrame.minX) / scale - size.width / 2,
            y: monitor.frame.minY + (adjustedPoint.y - visibleFrame.minY) / scale - size.height / 2,
            width: size.width,
            height: size.height
        )
        let frame = FloatingFrameGeometry.clamped(proposed, in: monitor.visibleFrame)
        let previewFrame = CGRect(
            x: visibleFrame.minX + (frame.minX - monitor.frame.minX) * scale,
            y: visibleFrame.minY + (frame.minY - monitor.frame.minY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        ).intersection(visibleFrame)
        return OverviewDropResolution(
            target: .floatingPlacement(destination: destination, frame: frame, previewFrame: previewFrame),
            label: label
        )
    }
}
