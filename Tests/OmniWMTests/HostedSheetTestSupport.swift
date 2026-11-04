// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
struct HostedSheetSnapshot {
    let token: WindowToken
    let window: NSWindow
    let metadata: HostedWindowMetadata
    let slot: ShellAppRuntime.Slot
}

extension ShellWidgetPackage {
    func hostedSheetRootIDs() -> Set<UUID> {
        Set(script?.instances.keys.compactMap { key in
            switch key {
            case let .window(id): id
            case .bar: nil
            }
        } ?? [])
    }
}

@MainActor
extension XCTestCase {
    func hostedSheetLabels(_ surface: ShellWidgetSurface) -> [String] {
        surface.layout.core.elements { $0.text != 0 }.map { handle in
            surface.text?.string(surface.layout.core.content(of: handle).text) ?? ""
        }
    }

    func hostedSheetAction(_ label: String, surface: ShellWidgetSurface) throws -> () -> Void {
        let text = try XCTUnwrap(surface.layout.core.elements { $0.text != 0 }.first { handle in
            surface.text?.string(surface.layout.core.content(of: handle).text) == label
        }, "Missing authored button label \(label)")
        let button = surface.layout.core.parent(of: text)
        XCTAssertTrue(surface.layout.core.contains(button))
        let capture = surface.capture(button)
        let action = surface.layout.core.content(of: button).action
        XCTAssertNotEqual(action, 0)
        return {
            surface.emit(action, capture: capture, point: capture.origin, event: ShellEvent())
        }
    }

    func hostedSheetEvent(
        _ runtime: ShellAppRuntime,
        description: String,
        completed: @escaping @MainActor () -> Bool,
        action: () -> Void
    ) async {
        let publication = expectation(description: description)
        let completionFailureDeadline: TimeInterval = 10
        runtime.onRender = { [weak runtime] in
            guard let runtime, runtime.failure != nil || completed() else { return }
            runtime.onRender = nil
            publication.fulfill()
        }
        action()
        await fulfillment(of: [publication], timeout: completionFailureDeadline)
        runtime.onRender = nil
        XCTAssertNil(runtime.failure)
        XCTAssertTrue(completed(), description)
    }

    func openHostedSheet(
        _ parent: HostedManagementInstance,
        fixture: HostedManagementFixture,
        button: String = "Delete"
    ) async throws -> HostedSheetSnapshot {
        await readyHosted(parent.session)
        let action = try hostedSheetAction(button, surface: parent.session.surface)
        await hostedSheetEvent(parent.session, description: "The native child root publishes its content", completed: {
            guard let token = fixture.manager.activeSheet(for: parent.token),
                  let slot = fixture.manager.slot(for: token) else { return false }
            return slot.renderedSequence > 0
        }, action: action)
        let token = try XCTUnwrap(fixture.manager.activeSheet(for: parent.token))
        return try HostedSheetSnapshot(
            token: token,
            window: XCTUnwrap(fixture.manager.windows[token]),
            metadata: XCTUnwrap(fixture.world.entry(for: token)?.target.hostedMetadata),
            slot: XCTUnwrap(fixture.manager.slot(for: token))
        )
    }

    func closeHostedSheet(
        _ sheet: HostedSheetSnapshot,
        button: String,
        parent: HostedManagementInstance,
        fixture: HostedManagementFixture,
        expectedResult: String? = nil
    ) async throws {
        let action = try hostedSheetAction(button, surface: sheet.slot.surface)
        await hostedSheetEvent(
            parent.session,
            description: "The authored child action retires its native root",
            completed: {
                fixture.manager.windows[sheet.token] == nil && parent.session.slots[sheet.metadata.rootID] == nil
                    && (expectedResult.map { self.hostedSheetLabels(parent.session.surface).contains($0) } ?? true)
            },
            action: action
        )
    }
}
