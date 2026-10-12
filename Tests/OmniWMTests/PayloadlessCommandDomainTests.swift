// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class PayloadlessCommandDomainTests: XCTestCase {
    func testFullscreenActionsPreserveMetadataAndBindings() throws {
        try assertSpec(
            command: .fullscreen(.managed),
            id: "toggleFullscreen",
            title: "Toggle OmniWM Fullscreen",
            binding: KeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey)),
            ipcName: .fullscreen(.managed)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "toggleFullscreen")?.category, .layout)
        try assertSpec(
            command: .fullscreen(.native),
            id: "toggleNativeFullscreen",
            title: "Toggle Native Fullscreen",
            binding: .unassigned,
            ipcName: .fullscreen(.native)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "toggleNativeFullscreen")?.category, .layout)
    }

    func testWindowStateActionsPreserveMetadataAndBindings() throws {
        try assertSpec(
            command: .windowState(.toggleFloating),
            id: "toggleFocusedWindowFloating",
            title: "Toggle Focused Window Floating",
            binding: .unassigned,
            ipcName: .windowState(.toggleFloating)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "toggleFocusedWindowFloating")?.category, .layout)
        try assertSpec(
            command: .windowState(.close),
            id: "closeFocusedWindow",
            title: "Close Focused Window",
            binding: .unassigned,
            ipcName: .windowState(.close)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "closeFocusedWindow")?.category, .focus)
    }

    func testMonitorFocusActionsPreserveMetadataAndBindings() throws {
        try assertSpec(
            command: .monitorFocus(.previous),
            id: "focusMonitorPrevious",
            title: "Focus Previous Monitor in Order",
            binding: .unassigned,
            ipcName: .monitorFocus(.previous)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "focusMonitorPrevious")?.category, .monitor)
        try assertSpec(
            command: .monitorFocus(.next),
            id: "focusMonitorNext",
            title: "Focus Next Monitor in Order",
            binding: KeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey | cmdKey)),
            ipcName: .monitorFocus(.next)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "focusMonitorNext")?.category, .monitor)
        try assertSpec(
            command: .monitorFocus(.last),
            id: "focusMonitorLast",
            title: "Focus Last Active Monitor",
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | cmdKey)),
            ipcName: .monitorFocus(.last)
        )
        XCTAssertEqual(ActionCatalog.spec(for: "focusMonitorLast")?.category, .monitor)
    }

    func testCompleteDomainRegistrationKeepsItsOriginalCatalogPositions() throws {
        let ids: Set<String> = [
            "focusMonitorNext", "focusMonitorPrevious", "focusMonitorLast",
            "toggleFullscreen", "toggleNativeFullscreen", "toggleFocusedWindowFloating", "closeFocusedWindow"
        ]
        let specs = ActionCatalog.allSpecs().filter { ids.contains($0.id) }
        XCTAssertEqual(specs.map(\.id), [
            "focusMonitorNext", "focusMonitorPrevious", "focusMonitorLast",
            "toggleFullscreen", "toggleNativeFullscreen", "toggleFocusedWindowFloating", "closeFocusedWindow"
        ])
        XCTAssertEqual(Set(specs.map(\.command)).count, ids.count)
        XCTAssertEqual(ActionCatalog.spec(for: "toggleFocusedWindowFloating")?.keywords, [
            "float", "floating", "Toggle Focused Window Floating", "toggleFocusedWindowFloating"
        ])
        XCTAssertEqual(ActionCatalog.spec(for: "closeFocusedWindow")?.keywords, [
            "close", "quit", "window", "Close Focused Window", "closeFocusedWindow"
        ])
    }

    func testDomainHotkeyAndIPCCodecsPreserveActionIDsAndNames() throws {
        let ids = [
            "focusMonitorNext", "focusMonitorPrevious", "focusMonitorLast",
            "toggleFullscreen", "toggleNativeFullscreen", "toggleFocusedWindowFloating", "closeFocusedWindow"
        ]
        for id in ids {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: id))
            let binding = HotkeyBinding(id: id, command: spec.command, binding: spec.defaultBinding)
            let data = try JSONEncoder().encode(binding)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["id", "binding"])
            XCTAssertEqual(object["id"] as? String, id)
            XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data), binding)
            let name = try XCTUnwrap(spec.ipcCommandName)
            let request = try IPCCommandRequest(name: name, argumentValues: [])
            let encoded = try JSONEncoder().encode(request)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(wire["name"] as? String, name.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: encoded), request)
        }
    }

    private func assertSpec(
        command: HotkeyCommand,
        id: String,
        title: String,
        binding: KeyBinding,
        ipcName: IPCCommandName
    ) throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
        XCTAssertEqual(ActionCatalog.spec(for: id), spec)
        XCTAssertEqual(HotkeyBindingRegistry.command(for: id), command)
        XCTAssertEqual(spec.id, id)
        XCTAssertEqual(spec.title, title)
        XCTAssertEqual(command.displayName, title)
        XCTAssertEqual(command.layoutCompatibility, .shared)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(spec.visibility, .normal)
        XCTAssertEqual(spec.defaultBinding, binding)
        XCTAssertEqual(spec.ipcCommandName, ipcName)
    }
}
