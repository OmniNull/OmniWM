// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceLayoutFormulaCommandTests: XCTestCase {
    func testLayoutCommandsRespectFormulaConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SettingsFilePersistence(directory: root, startWatching: false)
        let workspace = WorkspaceConfiguration(name: "1", layoutType: .niri)
        let source = """
        local layout = "\(workspace.layoutType.rawValue)"
        return { workspaces = { { id = "\(workspace.id)", name = "\(workspace.name)",
            monitorAssignment = { type = "main" }, layoutType = layout } } }
        """
        try Data(source.utf8).write(to: persistence.fileURL)
        let settings = SettingsStore(
            persistence: persistence, runtimeState: RuntimeStateStore(directory: root, deferSaves: false)
        )
        let controller = WMController(settings: settings)
        let handler = controller.commandHandler
        _ = controller.workspaceManager.focusWorkspace(named: workspace.name)
        defer { controller.layoutRefreshController.resetState() }
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(controller.activeWorkspace()?.name, workspace.name)
        controller.layoutRefreshController.resetState()

        for command in [WorkspaceAction.setLayout(.dwindle), .toggleLayout] {
            XCTAssertEqual(handler.performCommand(.workspace(command)), .workspaceStateConflict)
            XCTAssertEqual(settings.workspaces.configurations, [workspace])
            XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
            guard case let .invalidRejected(reason) = settings.configNotice else {
                XCTFail("Expected a formula confirmation notice")
                continue
            }
            XCTAssertTrue(reason.contains("Changing a formula requires confirmation in Settings"))
        }
        XCTAssertEqual(try String(contentsOf: persistence.fileURL, encoding: .utf8), source)

        settings.formulaConfirmation.canPresent = { true }
        XCTAssertEqual(handler.performCommand(.workspace(.toggleLayout)), .noChange)
        persistence.flushNow()
        let question = try XCTUnwrap(settings.formulaConfirmation.question)
        XCTAssertEqual(settings.workspaces.configurations, [workspace])
        settings.formulaConfirmation.answer(question.id, replace: true)
        XCTAssertEqual(settings.workspaces.configurations, [workspace.with(layoutType: .dwindle)])
        XCTAssertEqual(
            try SettingsLuauDocument(Data(contentsOf: persistence.fileURL)).export.workspaceConfigurations,
            settings.workspaces.configurations
        )
    }
}
