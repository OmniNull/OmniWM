// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
struct HostedUtilitySnapshot {
    let token: WindowToken
    let window: NSWindow
    let metadata: HostedWindowMetadata
    let slot: ShellAppRuntime.Slot
}

@MainActor
extension XCTestCase {
    func openHostedUtility(
        _ parent: HostedManagementInstance, fixture: HostedManagementFixture
    ) async throws -> HostedUtilitySnapshot {
        await readyHosted(parent.session)
        let action = try hostedSheetAction("Preferences", surface: parent.session.surface)
        let handler = try XCTUnwrap(parent.session.onWindowRequest)
        var opened = false
        parent.session.onWindowRequest = { request in
            let error = handler(request)
            if request.operation == .open, request.childID == "preferences", error == nil { opened = true }
            return error
        }
        defer { parent.session.onWindowRequest = handler }
        let childToken = {
            fixture.manager.childTokens(of: parent.token).first {
                fixture.world.entry(for: $0)?.target.hostedMetadata?.role.declarationID == "preferences"
            }
        }
        await hostedSheetEvent(parent.session, description: "The utility publishes its declared view", completed: {
            guard opened, let token = childToken(), let slot = fixture.manager.slot(for: token) else { return false }
            return slot.renderedSequence > 0
        }, action: action)
        let token = try XCTUnwrap(childToken())
        return try HostedUtilitySnapshot(
            token: token, window: XCTUnwrap(fixture.manager.windows[token]),
            metadata: XCTUnwrap(fixture.world.entry(for: token)?.target.hostedMetadata),
            slot: XCTUnwrap(fixture.manager.slot(for: token))
        )
    }

    func editHostedHeading(
        _ heading: String, in utility: HostedUtilitySnapshot, parent: HostedManagementInstance
    ) async throws {
        let input = try XCTUnwrap(utility.slot.surface.textInputs.values.first)
        await hostedSheetEvent(parent.session, description: "Both roots publish the shared heading", completed: {
            self.hostedSheetLabels(parent.session.surface).contains(heading) && input.text == heading
        }, action: {
            input.field?.stringValue = heading
            input.changed()
        })
    }
}
