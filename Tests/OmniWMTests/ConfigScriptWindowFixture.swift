// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
struct ConfigScriptWindowFixture {
    let base: NiriGatherFixture
    let script: ConfigScriptController

    init(monitors: [Monitor], layouts: [LayoutType]? = nil) throws {
        let specs = monitors.enumerated().map { index, monitor in
            NiriGatherFixture.WorkspaceSpec(
                name: String(index + 1), layoutType: layouts?[index] ?? .niri, monitor: monitor
            )
        }
        let base = try NiriGatherFixture(prefix: "placement", monitors: monitors, workspaces: specs)
        for (index, monitor) in monitors.enumerated() {
            XCTAssertTrue(base.manager.setActiveWorkspace(base.workspace(String(index + 1)), on: monitor.id))
        }
        self.init(base: base)
    }

    init(base: NiriGatherFixture) {
        self.base = base
        let controller = base.controller
        controller.settings.hotkeyBindings = []
        script = ConfigScriptController(
            fileURL: controller.settings.settingsFileURL.deletingLastPathComponent()
                .appendingPathComponent("init.luau"),
            settings: controller.settings,
            wmController: controller
        ) { [weak controller] rows in
            guard let controller else { return }
            controller.updateHotkeyBindings(controller.settings.hotkeyBindings, scriptResolution: rows)
        }
        controller.configScript = script
    }

    private var mask: UInt32 {
        base.controller.settings.hyperKeyModifiers.carbonMask
    }

    func id(_ window: Int) -> String {
        ConfigScriptWindowID.string(base.token(window), session: base.controller.scriptSession.identity)
    }

    var storeURL: URL {
        base.controller.settings.settingsFileURL.deletingLastPathComponent().appendingPathComponent("script-store.json")
    }

    func load(_ source: String) async throws {
        let loader = ConfigScriptLoader(store: ConfigScriptStore(fileURL: storeURL))
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
    }

    func focus(_ window: Int, on workspace: String) async throws {
        try await settle()
        let workspaceId = base.workspace(workspace)
        let monitor = try XCTUnwrap(base.manager.monitorId(for: workspaceId))
        base.select(window, in: workspaceId)
        _ = base.manager.confirmManagedFocus(
            base.token(window), in: workspaceId, onMonitor: monitor, activateWorkspaceOnMonitor: false
        )
        XCTAssertEqual(base.manager.nativeManagedFocusToken, base.token(window))
        XCTAssertEqual(base.manager.interactionMonitorID(), monitor)
    }

    private func settle() async throws {
        await WindowAdmissionTestSupport.drainLayoutRefreshes(base.controller)
        let pending = base.manager.focusSessionSnapshot.pendingManagedFocus
        guard let requestId = pending.requestId else { return }
        _ = base.manager.confirmManagedFocus(
            try XCTUnwrap(pending.token), in: try XCTUnwrap(pending.workspaceId), onMonitor: pending.monitorId,
            activateWorkspaceOnMonitor: false, requestId: requestId
        )
        XCTAssertEqual(base.manager.focusSessionSnapshot.pendingManagedFocus, .empty)
    }

    func press(_ chord: String) async throws {
        let binding = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(chord, hyperMask: mask))
        let command = try XCTUnwrap(script.effectiveBindings.first { $0.binding.chordBinding == binding }?.command)
        try await run(command)
    }

    func run(named name: String) async throws {
        let function = try XCTUnwrap(script.acceptedCommands.first { $0.name == name }?.function)
        try await run(.configFunction(function))
    }

    func inspect(_ body: [String], reads: [String] = ["placement"]) async throws {
        let list = reads.map { "'\($0)'" }.joined(separator: ", ")
        let source = ["omniwm.command('Inspect', function(ctx)"] + body + ["end, { reads = { \(list) } })"]
        try await load(source.joined(separator: "\n"))
        try await run(named: "Inspect")
    }

    static func recipe(_ title: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(
            contentsOf: root.appendingPathComponent("website/src/content/docs/config/init-luau.md"), encoding: .utf8
        )
        let heading = try XCTUnwrap(page.range(of: "**" + title))
        let start = try XCTUnwrap(page.range(of: "```lua\n", range: heading.upperBound ..< page.endIndex))
        let end = try XCTUnwrap(page.range(of: "\n```", range: start.upperBound ..< page.endIndex))
        return String(page[start.upperBound ..< end.lowerBound])
    }

    private func run(_ command: HotkeyCommand) async throws {
        XCTAssertEqual(
            base.controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: command)),
            .executed
        )
        await script.callbackQueue?.waitUntilParked()
        XCTAssertNil(script.diagnostic)
    }
}
