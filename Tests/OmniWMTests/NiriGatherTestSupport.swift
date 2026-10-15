// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
struct NiriGatherFixture {
    struct WorkspaceSpec {
        let name: String
        var layoutType: LayoutType = .niri
        var monitor: Monitor?
    }

    let controller: WMController
    let monitors: [Monitor]
    private let workspaceIdsByName: [String: WorkspaceDescriptor.ID]

    init(prefix: String, monitors: [Monitor], workspaces: [WorkspaceSpec]) throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: prefix)
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

    func request(_ ids: [Int], into destination: WorkspaceDescriptor.ID) -> NiriGatherRequest {
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
            )
        )
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
