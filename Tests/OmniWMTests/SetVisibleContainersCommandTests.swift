// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import XCTest

@MainActor
final class SetVisibleContainersCommandTests: XCTestCase {
    private let counts = IPCVisibleContainerCounts.range

    func testTheCLIAcceptsEveryCountInRangeAndNothingElse() {
        for count in counts {
            XCTAssertEqual(
                IPCCommandRequest(commandWords: ["set-visible-containers", "\(count)"]),
                .sizing(.setVisibleContainers(count: count))
            )
        }
        let outside = [["\(counts.upperBound + 1)"], ["\(counts.lowerBound - 1)"]]
        let malformed = [["two"], ["off"], [], ["\(counts.lowerBound)", "\(counts.upperBound)"]]
        for words in outside + malformed {
            XCTAssertNil(IPCCommandRequest(commandWords: ["set-visible-containers"] + words), "\(words)")
        }
    }

    func testAJSONRequestOutsideTheCountRangeIsRejected() throws {
        let valid = Data(
            #"{"arguments":{"visibleContainerCount":\#(counts.upperBound)},"name":"set-visible-containers"}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(IPCCommandRequest.self, from: valid),
            .sizing(.setVisibleContainers(count: counts.upperBound))
        )
        for count in [counts.lowerBound - 1, counts.upperBound + 1] {
            let invalid = Data(
                #"{"arguments":{"visibleContainerCount":\#(count)},"name":"set-visible-containers"}"#.utf8
            )
            XCTAssertThrowsError(try JSONDecoder().decode(IPCCommandRequest.self, from: invalid), "\(count)")
        }
    }

    func testOneCommandReachesShortcutsThePaletteTheCLIAndLuau() async throws {
        let count = counts.upperBound
        let request = IPCCommandRequest.sizing(.setVisibleContainers(count: count))
        XCTAssertEqual(HotkeyCommand(direct: request), .sizing(.setVisibleContainers(count)))
        let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: .sizing(.setVisibleContainers)))
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.visibleContainerCount])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertEqual(IPCCommandArgumentKind.visibleContainerCount.literalValues, counts.map(String.init))

        let specs = ActionCatalog.allSpecs().filter { $0.id.hasPrefix("setVisibleContainers.") }
        XCTAssertEqual(specs.map(\.id), counts.map { "setVisibleContainers.\($0)" })
        XCTAssertEqual(specs.map(\.command), counts.map { .sizing(.setVisibleContainers($0)) })
        XCTAssertEqual(specs.first?.localizedTitle, "Set Visible Containers to Off")
        XCTAssertEqual(specs.last?.localizedTitle, "Set Visible Containers to \(counts.upperBound)")
        for spec in specs {
            XCTAssertEqual(spec.defaultBinding, .unassigned, spec.id)
            XCTAssertEqual(spec.layoutCompatibility, .shared, spec.id)
            XCTAssertEqual(spec.visibility, .normal, spec.id)
            XCTAssertEqual(spec.ipcCommandName, .sizing(.setVisibleContainers), spec.id)
        }

        let evaluation = try await ConfigScriptLoader().evaluate(
            Data("omniwm.keymap.set('Hyper+\(count)', omniwm.cmd.setVisibleContainers('\(count)'))".utf8),
            hyperMask: HyperKeyModifiers.default.carbonMask
        )
        XCTAssertEqual(evaluation.bindings.map(\.command), [.sizing(.setVisibleContainers(count))])
    }
}
