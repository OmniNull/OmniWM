// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
func measureWorkspaceScrolls(in directory: URL) async throws {
    for kind in ScriptARCScrollWorkspace.Kind.allCases {
        let route = "workspace/scroll-" + kind.rawValue
        let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent(route))
        defer {
            fixture.script.stop()
            fixture.controller.layoutRefreshController.resetState()
        }
        let scene = try ScriptARCScrollWorkspace(controller: fixture.controller, kind: kind)
        try await fixture.measureWorkspaceScroll(scene, kind: kind, route: route)
    }
}

@MainActor
private struct ScriptARCScrollWorkspace {
    enum Kind: String, CaseIterable {
        case accepted
        case clamped
        case refused
    }

    let id: WorkspaceDescriptor.ID
    let name: String
    let monitor: Monitor
    let scale: CGFloat
    let initial: ViewportState
    let offset: CGFloat
    let expectedOffset: CGFloat

    init(controller: WMController, kind: Kind) throws {
        let manager = controller.workspaceManager
        guard let workspace = controller.activeWorkspace(), let monitor = manager.monitor(for: workspace.id) else {
            throw ScriptARCError("Missing active workspace for the scroll audit")
        }
        id = workspace.id
        name = workspace.name
        self.monitor = monitor

        controller.settings.borders.enabled = false
        controller.settings.niri.shrinkToFit = false
        controller.settings.niri.centerFocusedColumn = .always
        controller.settings.niri.allowOverscroll = kind != .refused
        controller.niriLayoutHandler.enableNiriLayout(centerFocusedColumn: .always)
        guard let engine = controller.niriEngine else { throw ScriptARCError("Missing Niri scroll engine") }
        let scale = engine.displayScale(in: workspace.id)
        self.scale = scale
        Self.prepareLayout(controller, monitor: monitor, workspace: workspace.id, scale: scale)
        let containers = engine.columns(in: workspace.id)
        let columnIndex = containers.count / 2
        guard columnIndex > 0, columnIndex < containers.count - 1,
              let selected = containers[columnIndex].windowNodes.first
        else { throw ScriptARCError("Missing interior column for the scroll audit") }
        manager.withNiriViewportState(for: workspace.id) {
            $0.activeColumnIndex = columnIndex
            $0.selectedNodeId = selected.id
        }
        _ = manager.commitWorkspaceSelection(nodeId: selected.id, focusedToken: selected.token, in: workspace.id)
        Self.reconcile(controller, workspace: workspace.id)
        initial = manager.niriViewportState(for: workspace.id)

        let working = controller.niriInteractionGeometry(for: monitor, scale: scale)
        offset = initial.viewOffset + (kind == .clamped
            ? working.workingFrame.width * CGFloat(containers.count) : working.innerGap)
        expectedOffset = kind == .clamped
            ? try Self.clampedOffset(offset, working: working, engine: engine, state: initial, workspace: workspace.id)
            : offset
    }

    private static func prepareLayout(
        _ controller: WMController, monitor: Monitor, workspace: WorkspaceDescriptor.ID, scale: CGFloat
    ) {
        let refresh = controller.layoutRefreshController
        refresh.resetState()
        refresh.layoutState
            .backingScaleByDisplay = [monitor.displayId: scale]
        let manager = controller.workspaceManager
        for window in manager.tiledEntries(in: workspace) {
            manager.setCachedConstraints(.unconstrained, for: window.token)
        }
        reconcile(controller, workspace: workspace)
    }

    private static func clampedOffset(
        _ offset: CGFloat, working: NiriInteractionGeometry, engine: NiriLayoutEngine,
        state: ViewportState, workspace: WorkspaceDescriptor.ID
    ) throws -> CGFloat {
        let columns = engine.columns(in: workspace)
        let geometry = NiriViewportGeometry(
            gap: working.innerGap, viewportSpan: working.workingFrame.width, orientation: .horizontal,
            edgeOverscroll: engine.effectiveSettings(in: workspace).edgeOverscroll
        )
        let position = state.containerPosition(
            at: state.activeColumnIndex, containers: columns, gap: working.innerGap,
            sizeKeyPath: geometry.orientation.settledSpanKeyPath
        )
        guard let bounds = geometry.overscrollBounds(columns: columns), position + offset > bounds.upperBound else {
            throw ScriptARCError("The scroll audit must clamp at the trailing bound")
        }
        return bounds.upperBound - position
    }

    private static func reconcile(_ controller: WMController, workspace: WorkspaceDescriptor.ID) {
        _ = controller.layoutRefreshController.buildWorkspacePlansInBatch {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspace])
        }
    }

    func reset(in controller: WMController) {
        let refresh = controller.layoutRefreshController
        refresh.resetState()
        refresh.layoutState.backingScaleByDisplay = [monitor.displayId: scale]
        controller.workspaceManager.updateNiriViewportState(initial, for: id)
    }

    func validate(in controller: WMController, kind: Kind) {
        let state = controller.workspaceManager.niriViewportState(for: id)
        if kind == .refused {
            precondition(state == initial, "A refused scroll changed the viewport")
        } else {
            precondition(state.viewOffset == expectedOffset, "The audited scroll did not reach its target")
            precondition(state.activeColumnIndex == initial.activeColumnIndex && state.selectedNodeId == initial
                .selectedNodeId)
        }
    }
}

@MainActor
extension ScriptARCFixture {
    fileprivate func measureWorkspaceScroll(
        _ scene: ScriptARCScrollWorkspace, kind: ScriptARCScrollWorkspace.Kind, route: String
    ) async throws {
        let chord = "Control+Option+W"
        let queue = try await acceptTitleScript("""
        omniwm.keymap.set("\(chord)", function()
            omniwm.dispatch("workspace", "scroll", "\(scene.name)", \(scene.offset), { animate = false })
        end)
        """)
        await queue.waitForAuditPark()
        let command = try binding(chord)
        if kind == .refused {
            scene.reset(in: controller)
            try await refusedFunction(
                command, route: route,
                diagnostic: "workspace scroll: the Niri layout policy would move the scroll offset.",
                report: true
            )
            scene.validate(in: controller, kind: kind)
        } else {
            for report in [false, true] {
                scene.reset(in: controller)
                try await function(command, route: route, busy: false, report: report)
                scene.validate(in: controller, kind: kind)
            }
        }
        for report in [false, true] {
            scene.reset(in: controller)
            measureNativeScroll(scene, kind: kind)
            if report { script_arc_report("native/scroll-" + kind.rawValue, "native", 0) }
        }
    }

    private func measureNativeScroll(_ scene: ScriptARCScrollWorkspace, kind: ScriptARCScrollWorkspace.Kind) {
        script_arc_begin()
        do throws(ConfigScriptDispatchRefusal) {
            let applied = try controller.niriLayoutHandler.scrollWorkspace(scene.id, to: scene.offset, animate: false)
            script_arc_end()
            precondition(applied && kind != .refused)
        } catch let refusal {
            script_arc_end()
            precondition(
                kind == .refused && refusal.reason == "the Niri layout policy would move the scroll offset",
                refusal.reason
            )
        }
        scene.validate(in: controller, kind: kind)
    }
}
