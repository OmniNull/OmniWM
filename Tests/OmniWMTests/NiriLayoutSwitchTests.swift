// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriLayoutSwitchTests: XCTestCase {
    func testWithMacOSFusionAWorkspaceSwitchedToDwindleForgetsItsNiriStrip() throws {
        for fusion in [false, true] {
            let controller = makeController()
            controller.settings.niri.macOSFusion = fusion
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            controller.enableDwindleLayout()
            let engine = try XCTUnwrap(controller.niriEngine)
            var previous: NodeId?
            for index in 0 ..< 2 {
                let token = controller.workspaceManager.addWindow(
                    AXWindowRef(
                        element: AXUIElementCreateApplication(881_301 + pid_t(index)),
                        windowId: 881_401 + index
                    ),
                    pid: 881_301 + pid_t(index),
                    windowId: 881_401 + index,
                    to: workspaceId
                )
                previous = engine.addWindow(token: token, to: workspaceId, afterSelection: previous).id
            }
            XCTAssertEqual(engine.columns(in: workspaceId).count, 2)

            XCTAssertTrue(controller.commandHandler.setWorkspaceLayout(.dwindle, forWorkspaceNamed: "1"))
            controller.workspaceManager.withBatchedLayoutBuild {
                controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
            }

            XCTAssertEqual(engine.root(for: workspaceId) == nil, fusion, "fusion=\(fusion)")
        }
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NiriLayoutSwitchTests-\(UUID().uuidString)", isDirectory: true)
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
                raiseWindow: { _ in }
            )
        )
    }
}
