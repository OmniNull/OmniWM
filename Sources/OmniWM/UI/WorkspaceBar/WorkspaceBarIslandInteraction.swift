// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarHitTarget: Hashable {
    case workspace(WorkspaceDescriptor.ID)
    case window(WorkspaceDescriptor.ID, WindowToken)
    case scratchpad(Int)

    var workspaceId: WorkspaceDescriptor.ID? {
        switch self {
        case let .workspace(id),
             let .window(id, _): id
        case .scratchpad: nil
        }
    }

    fileprivate var hitPriority: Int {
        switch self {
        case .window,
             .scratchpad: 1
        case .workspace: 0
        }
    }
}

@MainActor
final class WorkspaceBarIslandInteraction {
    private(set) var frames: [WorkspaceBarHitTarget: CGRect] = [:]
    private(set) var labelFrames: [WorkspaceDescriptor.ID: CGRect] = [:]
    private(set) var generation: UInt64 = 0
    var onShowMenu: (WorkspaceBarHitTarget) -> Void = { _ in }
    var onActivateWindow: (WorkspaceDescriptor.ID, WindowToken) -> Void = { _, _ in }
    var onHoverWindow: (WorkspaceDescriptor.ID, WindowToken, Bool) -> Void = { _, _, _ in }

    func update(_ target: WorkspaceBarHitTarget, frame: CGRect) {
        guard frames[target] != frame else { return }
        frames[target] = frame
        generation &+= 1
    }

    func remove(_ target: WorkspaceBarHitTarget, reportedFrame: CGRect?) {
        guard let reportedFrame, frames[target] == reportedFrame else { return }
        frames[target] = nil
        generation &+= 1
    }

    func updateLabel(_ workspaceId: WorkspaceDescriptor.ID, frame: CGRect) {
        labelFrames[workspaceId] = frame
    }

    func removeLabel(_ workspaceId: WorkspaceDescriptor.ID, reportedFrame: CGRect?) {
        guard let reportedFrame, labelFrames[workspaceId] == reportedFrame else { return }
        labelFrames[workspaceId] = nil
    }

    func target(at point: CGPoint) -> WorkspaceBarHitTarget? {
        var best: WorkspaceBarHitTarget?
        for (target, frame) in frames where frame.contains(point) {
            if best.map({ target.hitPriority > $0.hitPriority }) ?? true {
                best = target
            }
        }
        return best
    }
}

extension EnvironmentValues {
    @Entry var workspaceBarInteraction: WorkspaceBarIslandInteraction?
}

extension View {
    func workspaceBarHitRegion(_ target: WorkspaceBarHitTarget) -> some View {
        modifier(WorkspaceBarHitRegionModifier(target: target))
    }

    func workspaceBarLabelRegion(_ workspaceId: WorkspaceDescriptor.ID) -> some View {
        modifier(WorkspaceBarLabelRegionModifier(workspaceId: workspaceId))
    }
}

private struct WorkspaceBarHitRegionModifier: ViewModifier {
    let target: WorkspaceBarHitTarget
    @Environment(\.workspaceBarInteraction) private var interaction
    @State private var reportedFrame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                reportedFrame = frame
                interaction?.update(target, frame: frame)
            }
            .onDisappear {
                interaction?.remove(target, reportedFrame: reportedFrame)
            }
    }
}

private struct WorkspaceBarLabelRegionModifier: ViewModifier {
    let workspaceId: WorkspaceDescriptor.ID
    @Environment(\.workspaceBarInteraction) private var interaction
    @State private var reportedFrame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                reportedFrame = frame
                interaction?.updateLabel(workspaceId, frame: frame)
            }
            .onDisappear {
                interaction?.removeLabel(workspaceId, reportedFrame: reportedFrame)
            }
    }
}

extension NSHostingView {
    func workspaceBarLocalPoint(forWindowPoint point: CGPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    func workspaceBarScreenRect(forLocalRect rect: CGRect) -> CGRect? {
        guard let window else { return nil }
        let viewRect = isFlipped
            ? rect
            : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }
}
