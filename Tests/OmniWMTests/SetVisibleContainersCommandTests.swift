// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class SetVisibleContainersCommandTests: XCTestCase {
    func testTheCLIAcceptsZeroToFiveAndNothingElse() {
        for count in 0 ... 5 {
            XCTAssertEqual(
                IPCCommandRequest(commandWords: ["set-visible-containers", "\(count)"]),
                .sizing(.setVisibleContainers(count: count))
            )
        }
        for words in [["6"], ["-1"], ["two"], ["off"], [], ["2", "3"]] {
            XCTAssertNil(IPCCommandRequest(commandWords: ["set-visible-containers"] + words), "\(words)")
        }
    }

    func testAJSONRequestOutsideZeroToFiveIsRejected() throws {
        let valid = Data(#"{"arguments":{"visibleContainerCount":5},"name":"set-visible-containers"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(IPCCommandRequest.self, from: valid),
            .sizing(.setVisibleContainers(count: 5))
        )
        for count in [-1, 6] {
            let invalid = Data(
                #"{"arguments":{"visibleContainerCount":\#(count)},"name":"set-visible-containers"}"#.utf8
            )
            XCTAssertThrowsError(try JSONDecoder().decode(IPCCommandRequest.self, from: invalid), "\(count)")
        }
    }

    func testOneCommandReachesShortcutsThePaletteTheCLIAndLuau() async throws {
        let request = IPCCommandRequest.sizing(.setVisibleContainers(count: 3))
        XCTAssertEqual(HotkeyCommand(direct: request), .sizing(.setVisibleContainers(3)))
        let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: .sizing(.setVisibleContainers)))
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.visibleContainerCount])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertEqual(IPCCommandArgumentKind.visibleContainerCount.literalValues, ["0", "1", "2", "3", "4", "5"])

        let specs = ActionCatalog.allSpecs().filter { $0.id.hasPrefix("setVisibleContainers.") }
        XCTAssertEqual(specs.map(\.id), (0 ... 5).map { "setVisibleContainers.\($0)" })
        XCTAssertEqual(specs.map(\.command), (0 ... 5).map { .sizing(.setVisibleContainers($0)) })
        XCTAssertEqual(specs.first?.localizedTitle, "Set Visible Containers to Off")
        XCTAssertEqual(specs.last?.localizedTitle, "Set Visible Containers to 5")
        for spec in specs {
            XCTAssertEqual(spec.defaultBinding, .unassigned, spec.id)
            XCTAssertEqual(spec.layoutCompatibility, .shared, spec.id)
            XCTAssertEqual(spec.visibility, .normal, spec.id)
            XCTAssertEqual(spec.ipcCommandName, .sizing(.setVisibleContainers), spec.id)
        }

        let evaluation = try await ConfigScriptLoader().evaluate(
            Data("omniwm.keymap.set('Hyper+3', omniwm.cmd('set-visible-containers', '3'))".utf8),
            hyperMask: HyperKeyModifiers.default.carbonMask
        )
        XCTAssertEqual(evaluation.bindings.map(\.command), [.sizing(.setVisibleContainers(3))])
    }
}
