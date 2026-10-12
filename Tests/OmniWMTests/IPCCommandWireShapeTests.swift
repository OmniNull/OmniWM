// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCCommandWireShapeTests: XCTestCase {
    func testEveryCommandConstructionPreservesWireShapeAndRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var coveredNames: Set<IPCCommandName> = []

        for fixture in Self.commandFixtures {
            let data = Data(fixture.utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rawName = try XCTUnwrap(object["name"] as? String)
            let name = try XCTUnwrap(IPCCommandName(rawValue: rawName))
            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: name))
            let request = try IPCCommandRequest(
                name: name,
                argumentValues: descriptor.arguments.map { argument($0.kind) }
            )

            XCTAssertTrue(coveredNames.insert(name).inserted, rawName)
            XCTAssertEqual(request.name, name)
            XCTAssertEqual(String(decoding: try encoder.encode(request), as: UTF8.self), fixture, rawName)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request, rawName)
        }

        XCTAssertEqual(coveredNames, Set(IPCCommandName.allCases))
    }

    private func argument(_ kind: IPCCommandArgumentKind) -> IPCCommandArgumentValue {
        switch kind {
        case .direction:
            .direction(.left)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .scratchpadIndex:
            .integer(2)
        case .layout:
            .layout(.niri)
        case .paletteMode:
            .paletteMode(.clipboard)
        case .resizeAxis:
            .resizeAxis(.horizontal)
        case .resizeOperation:
            .resizeOperation(.grow)
        case .sizeChange:
            .sizeChange(.setProportion(0.5))
        }
    }

    private static let commandFixtures = [
        #"{"arguments":{"direction":"left"},"name":"focus"}"#,
        #"{"name":"focus-previous"}"#,
        #"{"name":"focus-down-or-left"}"#,
        #"{"name":"focus-up-or-right"}"#,
        #"{"arguments":{"windowIndex":2},"name":"focus-window-in-column"}"#,
        #"{"name":"focus-window-top"}"#,
        #"{"name":"focus-window-bottom"}"#,
        #"{"name":"focus-window-down-or-top"}"#,
        #"{"name":"focus-window-up-or-bottom"}"#,
        #"{"name":"focus-window-or-workspace-down"}"#,
        #"{"name":"focus-window-or-workspace-up"}"#,
        #"{"arguments":{"columnIndex":2},"name":"focus-column"}"#,
        #"{"name":"focus-column-first"}"#,
        #"{"name":"focus-column-last"}"#,
        #"{"name":"center-column"}"#,
        #"{"name":"center-visible-columns"}"#,
        #"{"arguments":{"direction":"left"},"name":"move"}"#,
        #"{"name":"move-window-down"}"#,
        #"{"name":"move-window-up"}"#,
        #"{"name":"move-window-down-or-to-workspace-down"}"#,
        #"{"name":"move-window-up-or-to-workspace-up"}"#,
        #"{"name":"consume-or-expel-window-left"}"#,
        #"{"name":"consume-or-expel-window-right"}"#,
        #"{"name":"consume-window-into-column"}"#,
        #"{"name":"expel-window-from-column"}"#,
        #"{"arguments":{"workspaceNumber":2},"name":"switch-workspace"}"#,
        #"{"name":"switch-workspace-next"}"#,
        #"{"name":"switch-workspace-previous"}"#,
        #"{"name":"switch-workspace-back-and-forth"}"#,
        #"{"arguments":{"workspaceNumber":2},"name":"switch-workspace-anywhere"}"#,
        #"{"arguments":{"slotNumber":2},"name":"switch-workspace-slot"}"#,
        #"{"arguments":{"slotNumber":2},"name":"move-to-workspace-slot"}"#,
        #"{"arguments":{"workspaceNumber":2},"name":"move-to-workspace"}"#,
        #"{"name":"move-to-workspace-up"}"#,
        #"{"name":"move-to-workspace-down"}"#,
        #"{"arguments":{"direction":"left","workspaceNumber":2},"name":"move-to-workspace-on-monitor"}"#,
        #"{"arguments":{"direction":"left"},"name":"move-to-monitor"}"#,
        #"{"name":"focus-monitor-previous"}"#,
        #"{"name":"focus-monitor-next"}"#,
        #"{"name":"focus-monitor-last"}"#,
        #"{"arguments":{"direction":"left"},"name":"move-column"}"#,
        #"{"name":"move-column-to-first"}"#,
        #"{"name":"move-column-to-last"}"#,
        #"{"arguments":{"columnIndex":2},"name":"move-column-to-index"}"#,
        #"{"arguments":{"workspaceNumber":2},"name":"move-column-to-workspace"}"#,
        #"{"name":"move-column-to-workspace-up"}"#,
        #"{"name":"move-column-to-workspace-down"}"#,
        #"{"name":"toggle-column-tabbed"}"#,
        #"{"name":"cycle-size-forward"}"#,
        #"{"name":"cycle-size-backward"}"#,
        #"{"name":"cycle-window-primary-span-forward"}"#,
        #"{"name":"cycle-window-primary-span-backward"}"#,
        #"{"name":"cycle-window-secondary-span-forward"}"#,
        #"{"name":"cycle-window-secondary-span-backward"}"#,
        #"{"name":"toggle-container-full-primary-span"}"#,
        #"{"name":"expand-container-to-available-primary-span"}"#,
        #"{"name":"reset-window-secondary-span"}"#,
        #"{"arguments":{"change":{"kind":"set-proportion","value":0.5}},"name":"set-container-primary-span"}"#,
        #"{"arguments":{"change":{"kind":"set-proportion","value":0.5}},"name":"set-window-primary-span"}"#,
        #"{"arguments":{"change":{"kind":"set-proportion","value":0.5}},"name":"set-window-secondary-span"}"#,
        #"{"arguments":{"direction":"left"},"name":"swap-workspace-with-monitor"}"#,
        #"{"name":"balance-sizes"}"#,
        #"{"name":"move-to-root"}"#,
        #"{"name":"toggle-split"}"#,
        #"{"name":"swap-split"}"#,
        #"{"arguments":{"axis":"horizontal","operation":"grow"},"name":"resize"}"#,
        #"{"arguments":{"operation":"grow"},"name":"resize-focused"}"#,
        #"{"arguments":{"direction":"left"},"name":"preselect"}"#,
        #"{"name":"preselect-clear"}"#,
        #"{"name":"open-command-palette"}"#,
        #"{"arguments":{"mode":"clipboard"},"name":"open-command-palette-mode"}"#,
        #"{"name":"raise-all-floating-windows"}"#,
        #"{"name":"toggle-floating-focus"}"#,
        #"{"name":"rescue-offscreen-windows"}"#,
        #"{"name":"toggle-workspace-layout"}"#,
        #"{"arguments":{"layout":"niri"},"name":"set-workspace-layout"}"#,
        #"{"name":"toggle-fullscreen"}"#,
        #"{"name":"toggle-native-fullscreen"}"#,
        #"{"name":"toggle-overview"}"#,
        #"{"name":"toggle-system-stats"}"#,
        #"{"name":"toggle-quake-terminal"}"#,
        #"{"name":"toggle-workspace-bar"}"#,
        #"{"name":"hidden-bar-panel"}"#,
        #"{"name":"toggle-focused-window-floating"}"#,
        #"{"name":"close-focused-window"}"#,
        #"{"arguments":{"scratchpadIndex":2},"name":"scratchpad-assign"}"#,
        #"{"arguments":{"scratchpadIndex":2},"name":"scratchpad-toggle"}"#,
        #"{"name":"open-menu-anywhere"}"#
    ]
}
