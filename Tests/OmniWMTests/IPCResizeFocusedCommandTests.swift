// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCResizeFocusedCommandTests: XCTestCase {
    func testConstructionRejectsMissingArgument() {
        XCTAssertThrowsError(try IPCCommandRequest(name: .dwindle(.resizeFocused), argumentValues: []))
    }

    func testJSONRoundTrip() throws {
        let original = IPCCommandRequest(.dwindle(.resizeFocused(operation: .shrink)))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCCommandRequest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testManifestResolvesPublicCommand() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["resize-focused", "grow"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .dwindle(.resizeFocused) })
        XCTAssertEqual(descriptor.commandWords, ["resize-focused"])
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.resizeOperation])
        let request = try IPCCommandRequest(name: descriptor.name, argumentValues: [.resizeOperation(.grow)])
        XCTAssertEqual(request, .init(.dwindle(.resizeFocused(operation: .grow))))
    }
}
