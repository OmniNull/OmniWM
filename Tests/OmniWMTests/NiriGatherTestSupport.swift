// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriGatherFocusOperationRecorder {
    var operations: [String] = []

    var windowFocusOperations: WindowFocusOperations {
        WindowFocusOperations(
            activateApp: { self.operations.append("activateApp \($0)") },
            focusSpecificWindow: { _, windowId, _ in self.operations.append("focusSpecificWindow \(windowId)") },
            submitFocusSpecificWindow: { _, windowId, _ in
                self.operations.append("submitFocusSpecificWindow \(windowId)")
            },
            deactivateSameAppWindow: { _, windowId in
                self.operations.append("deactivateSameAppWindow \(windowId)")
                return false
            },
            activateAndFocusSameAppWindow: { _, windowId, _ in
                self.operations.append("activateAndFocusSameAppWindow \(windowId)")
                return false
            },
            raiseWindow: { _ in self.operations.append("raiseWindow") },
            orderWindow: { self.operations.append("orderWindow \($0)") }
        )
    }
}

@MainActor
struct NiriGatherFixture {
    struct WorkspaceSpec {
        let name: String
        var layoutType: LayoutType = .niri
        var monitor: Monitor?
    }

    let controller: WMController
    let monitors: [Monitor]
    let focusRecorder: NiriGatherFocusOperationRecorder
    private let workspaceIdsByName: [String: WorkspaceDescriptor.ID]

    init(prefix: String, monitors: [Monitor], workspaces: [WorkspaceSpec]) throws {
        let focusRecorder = NiriGatherFocusOperationRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: prefix,
            windowFocusOperations: focusRecorder.windowFocusOperations
        )
        controller.workspaceManager.applyMonitorConfigurationChange(monitors)
        let names = Set(workspaces.map(\.name))
        controller.settings.workspaces.configurations.removeAll { names.contains($0.name) }
        for spec in workspaces {
            controller.settings.workspaces.configurations.append(
                WorkspaceConfiguration(
                    name: spec.name,
                    monitorAssignment: spec.monitor.map { .specificDisplay(OutputId(from: $0)) } ?? .main,
                    layoutType: spec.layoutType
                )
            )
        }
        controller.workspaceManager.applySettings()
        var workspaceIdsByName: [String: WorkspaceDescriptor.ID] = [:]
        for spec in workspaces {
            workspaceIdsByName[spec.name] = try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: spec.name, createIfMissing: true)
            )
        }
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        self.controller = controller
        self.monitors = monitors
        self.focusRecorder = focusRecorder
        self.workspaceIdsByName = workspaceIdsByName
    }

    static func monitor(displayId: UInt32, x: CGFloat = 0, width: CGFloat = 1_200, height: CGFloat = 800) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: x, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: x, y: 0, width: width, height: height),
            hasNotch: false,
            name: "Gather \(displayId)"
        )
    }

    var manager: WorkspaceManager {
        controller.workspaceManager
    }

    var engine: NiriLayoutEngine {
        controller.niriEngine!
    }

    var handler: NiriLayoutHandler {
        controller.niriLayoutHandler
    }

    func workspace(_ name: String) -> WorkspaceDescriptor.ID {
        workspaceIdsByName[name]!
    }

    func token(_ id: Int) -> WindowToken {
        WindowToken(pid: 73_000 + pid_t(id), windowId: 73_000 + id)
    }

    func layout(_ workspaceId: WorkspaceDescriptor.ID) -> [[Int]] {
        engine.columns(in: workspaceId).map { $0.windowNodes.map { $0.token.windowId - 73_000 } }
    }

    func node(_ id: Int, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        engine.findNode(for: token(id), in: workspaceId)
    }

    func add(_ ids: [Int], to workspaceId: WorkspaceDescriptor.ID, minHeight: CGFloat = 1) {
        for id in ids {
            _ = WindowAdmissionTestSupport.track(token(id), in: workspaceId, controller: controller)
        }
        guard manager.activeLayoutKind(for: workspaceId) == .niri else {
            manager.withEngineMutationScope {
                for id in ids {
                    _ = controller.dwindleEngine?.addWindow(token: token(id), to: workspaceId, activeWindowFrame: nil)
                }
            }
            return
        }
        manager.withEngineMutationScope {
            for id in ids {
                _ = engine.addWindow(token: token(id), to: workspaceId, afterSelection: nil)
                engine.updateWindowConstraints(
                    for: token(id),
                    constraints: WindowSizeConstraints(
                        minSize: CGSize(width: 1, height: minHeight),
                        maxSize: .zero,
                        isFixed: false
                    ),
                    in: workspaceId,
                    motion: .disabled
                )
            }
        }
    }

    func stack(_ id: Int, onto target: Int, in workspaceId: WorkspaceDescriptor.ID) {
        manager.withEngineMutationScope(in: workspaceId) {
            guard let node = node(id, in: workspaceId),
                  let source = engine.findColumn(containing: node, in: workspaceId),
                  let targetNode = self.node(target, in: workspaceId),
                  let column = engine.findColumn(containing: targetNode, in: workspaceId)
            else { return XCTFail("missing fixture columns") }
            engine.moveWindowToColumn(node, from: source, to: column, in: workspaceId)
            source.remove()
        }
    }

    func select(_ id: Int, in workspaceId: WorkspaceDescriptor.ID) {
        let nodeId = node(id, in: workspaceId)?.id
        manager.withNiriViewportState(for: workspaceId) { $0.selectedNodeId = nodeId }
    }

    func request(
        _ ids: [Int],
        into destination: WorkspaceDescriptor.ID,
        nativeFocus: Int? = nil
    ) -> NiriGatherRequest {
        let monitor = manager.monitor(for: destination)!
        return NiriGatherRequest(
            tokens: ids.map(token),
            sourceWorkspaceIds: Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                manager.workspace(for: token(id)).map { (token(id), $0) }
            }),
            destinationWorkspaceId: destination,
            geometry: NiriSizingGeometry(
                workingFrame: controller.niriWorkingFrame(for: monitor),
                gaps: controller.innerGap(for: monitor),
                orientation: .horizontal
            ),
            nativeFocusToken: nativeFocus.map(token)
        )
    }

    func gather(_ ids: [Int], from reach: NiriGatherReach) throws -> NiriGatherOutcome {
        try handler.gatherWindows(ids.map(token), from: reach, into: XCTUnwrap(handler.gatherDestination()))
    }

    func lastTraceSequence() -> UInt64 {
        manager.reconcileTraceDump().split(separator: "\n").compactMap { traceSequence(of: String($0)) }.max() ?? 0
    }

    func traceLines(after sequence: UInt64) -> [String] {
        manager.reconcileTraceDump().split(separator: "\n").map(String.init).filter { line in
            traceSequence(of: line).map { $0 > sequence } ?? false
        }
    }

    private func traceSequence(of line: String) -> UInt64? {
        guard line.hasPrefix("#") else { return nil }
        return UInt64(line.dropFirst().prefix { $0 != " " })
    }
}

extension NiriGatherPlan {
    func patch(in workspaceId: WorkspaceDescriptor.ID) -> WorkspacePatch? {
        workspaces.first { $0.workspaceId == workspaceId }
    }

    func selection(in workspaceId: WorkspaceDescriptor.ID) -> NodeId? {
        patch(in: workspaceId)?.selectedNodeId
    }

    func activeColumnIndex(in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        patch(in: workspaceId)?.activeColumnIndex
    }
}
