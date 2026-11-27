// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class ScratchpadCommandTests: XCTestCase {
    func testEverySlotRegistersBothActions() throws {
        for slot in ScratchpadIndex.range {
            let toggle = try XCTUnwrap(ActionCatalog.spec(for: .scratchpad(.toggle(slot))))
            XCTAssertEqual(toggle.id, "toggleScratchpad.\(slot)")
            XCTAssertEqual(toggle.title, "Toggle Scratchpad \(slot)")
            XCTAssertEqual(toggle.layoutCompatibility, .shared)
            XCTAssertEqual(toggle.defaultBinding, .unassigned)
            XCTAssertEqual(toggle.ipcCommandName, .scratchpad(.toggle))
            XCTAssertNotNil(toggle.ipcDescriptor)

            let assign = try XCTUnwrap(ActionCatalog.spec(for: .scratchpad(.assign(slot))))
            XCTAssertEqual(assign.id, "assignFocusedWindowToScratchpad.\(slot)")
            XCTAssertEqual(assign.title, "Toggle Scratchpad \(slot) Assignment for Focused Window")
            XCTAssertEqual(assign.ipcCommandName, .scratchpad(.assign))
        }
    }

    func testCommandJSONRoundTripCarriesIndex() throws {
        let cases: [(IPCCommandRequest, IPCCommandName)] = [
            (.init(.scratchpad(.assign(index: 2))), .scratchpad(.assign)),
            (.init(.scratchpad(.toggle(index: 10))), .scratchpad(.toggle)),
            (.init(.scratchpad(.assign(index: 4))), .scratchpad(.assign)),
            (.init(.scratchpad(.toggle(index: 4))), .scratchpad(.toggle))
        ]
        for (request, expectedName) in cases {
            XCTAssertEqual(request.name, expectedName)
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }
    }

    func testManifestResolvesIndexArgument() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["scratchpad", "toggle"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .scratchpad(.toggle) })

        XCTAssertEqual(descriptor.commandWords, ["scratchpad", "toggle"])
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.scratchpadIndex])
        XCTAssertEqual(
            try IPCCommandRequest(name: descriptor.name, argumentValues: [.integer(3)]),
            .init(.scratchpad(.toggle(index: 3)))
        )
        XCTAssertThrowsError(try IPCCommandRequest(name: descriptor.name, argumentValues: []))
    }

    func testCLIParsesSlotAndRejectsOutOfRange() throws {
        let parsed = try CLIParser.parse(
            arguments: ["omniwmctl", "command", "scratchpad", "toggle", "7"]
        )
        guard case let .command(request) = parsed.request.payload else {
            return XCTFail("expected a command payload")
        }
        XCTAssertEqual(request, .init(.scratchpad(.toggle(index: 7))))

        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "scratchpad", "toggle", "11"])
        )
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "scratchpad", "assign", "0"])
        )
    }

    @MainActor
    func testRouterRejectsOutOfRangeSlot() {
        let controller = WMController(settings: makeSettingsStore())
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.init(.scratchpad(.toggle(index: 11)))), .invalidArguments)
        XCTAssertEqual(router.handle(.init(.scratchpad(.assign(index: 0)))), .invalidArguments)
    }

    func testLabelsRoundTripThroughLuau() throws {
        XCTAssertTrue(SettingsExport.defaults().scratchpads.labels.isEmpty)

        var export = SettingsExport.defaults()
        export.scratchpads.labels = ["3": "COMMS"]
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("COMMS"))
        XCTAssertEqual(try SettingsLuauFixture.decode(data).scratchpads.labels, ["3": "COMMS"])
    }

    @MainActor
    func testLabelNormalizationDropsUnusableEntries() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.scratchpads.labels = ["1": " term ", "0": "low", "11": "high", "4": "   "]

        settings.applyExport(export)

        XCTAssertEqual(settings.scratchpadLabels, ["1": "term"])
        XCTAssertEqual(settings.scratchpadLabel(for: 1), "term")
        XCTAssertNil(settings.scratchpadLabel(for: 4))
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMScratchpadCommandTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SettingsStore(
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
    }
}
