// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class PresentationActionContractTests: XCTestCase {
    func testPresentationMetadataAndCommandIdentityRemainDistinct() throws {
        let cases = PresentationExpectation.all()
        XCTAssertEqual(cases.map(\.ipc), IPCPresentationCommand.allCases)
        XCTAssertEqual(Set(cases.map(\.command)).count, cases.count)
        for expected in cases {
            let (ipc, command) = (expected.ipc, expected.command)
            let (id, title) = (expected.id, expected.title)
            let translated = HotkeyCommand.presentation(ipc)
            XCTAssertEqual(translated, command)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            XCTAssertEqual(ActionCatalog.spec(for: id), spec)
            XCTAssertEqual(spec.id, id)
            XCTAssertEqual(spec.title, title)
            XCTAssertEqual(command.displayName, title)
            XCTAssertEqual(command.layoutCompatibility, .shared)
            XCTAssertEqual(spec.defaultBinding, expected.binding)
            XCTAssertEqual(spec.category, .focus)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(spec.ipcCommandName, .presentation(ipc))
        }
    }

    func testPresentationRegistrationKeepsInterleavedWorkspaceLayoutOrder() {
        XCTAssertEqual(Array(ActionCatalog.allSpecs().suffix(6).map(\.id)), [
            "toggleWorkspaceBarVisibility", "toggleHiddenBarPanel", "toggleQuakeTerminal",
            "toggleWorkspaceLayout", "toggleOverview", "toggleSystemStats"
        ])
        XCTAssertEqual(
            ActionCatalog.spec(for: "toggleOverview")?.keywords,
            ["overview", "Toggle Overview", "toggleOverview"]
        )
        XCTAssertEqual(ActionCatalog.spec(for: "toggleHiddenBarPanel")?.keywords, [
            "hidden bar", "icons", "menu bar", "Toggle Hidden Icons Panel", "toggleHiddenBarPanel"
        ])
    }

    func testSavedPresentationBindingsEncodeOnlyActionIDAndTrigger() throws {
        for ipc in IPCPresentationCommand.allCases {
            let command = HotkeyCommand.presentation(ipc)
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            let binding = HotkeyBinding(id: spec.id, command: command, binding: spec.defaultBinding)
            let encoded = try JSONEncoder().encode(binding)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["id", "binding"])
            XCTAssertEqual(object["id"] as? String, spec.id)
            XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: encoded), binding)
            let persisted = PersistedHotkeyBinding(id: spec.id, trigger: binding.binding)
            let saved = try JSONEncoder().encode(persisted)
            XCTAssertEqual(try JSONDecoder().decode(PersistedHotkeyBinding.self, from: saved), persisted)
        }
    }

    func testPresentationInputDiagnosticsUseRegisteredTitlesAndActionIDs() {
        let expected = PresentationExpectation.all()
        let bindings = expected.map { item in
            HotkeyBinding(
                id: item.id,
                command: item.command,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_ANSI_A),
                    modifiers: KeySymbolMapper.hyperModifiers,
                    sidedModifiers: SidedModifiers(left: KeySymbolMapper.hyperModifiers)
                )
            )
        }
        let facts = HotkeyCenter.bindingFacts(for: bindings)
        XCTAssertEqual(facts.map(\.command), expected.map(\.title))
        XCTAssertEqual(facts.map(\.route), Array(repeating: "unregistered(duplicateBinding)", count: expected.count))
        let issues = SidedHyperBindingDetector.issues(currentBindings: bindings)
        XCTAssertEqual(issues.map(\.id), expected.map { "hotkey-sided-hyper:\($0.id)" })
        XCTAssertEqual(issues.map(\.title), expected.map { "Hyper shortcut may not fire: \($0.title)" })
    }

    func testPresentationIPCEncodingAndUnregisteredFallbackAreUnchanged() throws {
        for command in IPCPresentationCommand.allCases {
            let request = IPCCommandRequest.presentation(command)
            let encoded = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["name"] as? String, command.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: encoded), request)
        }
        let unregistered = HotkeyCommand.workspace(.swapWithMonitor(.left))
        XCTAssertNil(ActionCatalog.spec(for: unregistered))
        XCTAssertEqual(unregistered.displayName, String(describing: unregistered))
        XCTAssertNil(ActionCatalog.spec(for: HotkeyCommand.workspace(.moveWorkspaceToMonitor(.left)))?.ipcCommandName)
    }
}

private struct PresentationExpectation {
    let ipc: IPCPresentationCommand
    let command: HotkeyCommand
    let id: String
    let title: String
    let binding: KeyBinding

    static func all() -> [PresentationExpectation] {
        [
            PresentationExpectation(
                ipc: .overview,
                command: .presentation(.overview),
                id: "toggleOverview",
                title: "Toggle Overview",
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | shiftKey))
            ),
            PresentationExpectation(
                ipc: .systemStats,
                command: .presentation(.systemStats),
                id: "toggleSystemStats",
                title: "Toggle System Stats",
                binding: .unassigned
            ),
            PresentationExpectation(
                ipc: .quakeTerminal,
                command: .presentation(.quakeTerminal),
                id: "toggleQuakeTerminal",
                title: "Toggle Quake Terminal",
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey))
            ),
            PresentationExpectation(
                ipc: .workspaceBar,
                command: .presentation(.workspaceBar),
                id: "toggleWorkspaceBarVisibility",
                title: "Toggle Workspace Bar",
                binding: .unassigned
            ),
            PresentationExpectation(
                ipc: .hiddenBar,
                command: .presentation(.hiddenBar),
                id: "toggleHiddenBarPanel",
                title: "Toggle Hidden Icons Panel",
                binding: .unassigned
            )
        ]
    }
}
