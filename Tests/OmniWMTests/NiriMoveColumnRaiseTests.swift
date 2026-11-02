// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriMoveColumnRaiseTests: XCTestCase {
    func testWithNaturalWindowDragMovingAStackedColumnBringsEveryWindowForwardWithTheFocusedOneOnTop() throws {
        var ordered: [pid_t] = []
        let controller = makeController { element in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            ordered.append(pid)
        }
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokens = (0 ..< 3).map { index in
            controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(880_301 + pid_t(index)), windowId: 880_401 + index),
                pid: 880_301 + pid_t(index),
                windowId: 880_401 + index,
                to: workspaceId
            )
        }
        var previous: NodeId?
        for token in tokens {
            previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous).id
        }
        let focused = try XCTUnwrap(controller.workspaceManager.handle(for: tokens[0]))
        _ = controller.niriLayoutHandler.consumeWindowIntoColumn(containing: focused)
        XCTAssertEqual(engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token) }.first?.count, 2)
        let mate = try XCTUnwrap(engine.columns(in: workspaceId).first?.windowNodes.first { $0.token != tokens[0] })
        controller.settings.niri.naturalWindowDrag = false
        ordered = []

        _ = controller.niriLayoutHandler.moveColumn(containing: focused, direction: .right)

        XCTAssertEqual(engine.columns(in: workspaceId).last?.windowNodes.contains { $0.token == tokens[0] }, true)
        XCTAssertEqual(ordered, [])

        controller.settings.niri.naturalWindowDrag = true
        _ = controller.niriLayoutHandler.moveColumn(containing: focused, direction: .left)

        XCTAssertEqual(engine.columns(in: workspaceId).first?.windowNodes.contains { $0.token == tokens[0] }, true)
        XCTAssertEqual(ordered, [mate.token.pid, tokens[0].pid])
    }

    private func makeController(raiseWindow: @escaping (AXUIElement) -> Void) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NiriMoveColumnRaiseTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: raiseWindow
            )
        )
    }
}
