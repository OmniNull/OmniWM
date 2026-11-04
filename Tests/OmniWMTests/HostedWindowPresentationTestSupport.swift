// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class HostedPresentationFixture {
    let management: HostedManagementFixture
    var notes: HostedWindowMetadata {
        HostedWindowMetadata(
            appId: "notes", title: "Hosted Notes", minimumSize: management.definition.minimumContentSize,
            icon: "note.text"
        )
    }

    var timer: HostedWindowMetadata {
        HostedWindowMetadata(
            appId: "timer", title: "Hosted Timer", minimumSize: management.definition.minimumContentSize, icon: "timer"
        )
    }

    let externalBundle = "org.omniwm.presentation.external"
    let externalTitle = "External document"

    var controller: WMController {
        management.controller
    }

    var world: WorkspaceManager {
        management.world
    }

    var workspace: WorkspaceDescriptor.ID {
        management.source
    }

    init(layout: LayoutType = .dwindle) throws {
        management = try HostedManagementFixture(layout: layout)
        world.removeWindow(pid: management.external.pid, windowId: management.external.windowId)
    }

    func add(_ metadata: HostedWindowMetadata) throws -> WindowState {
        let window = management.manager.makeWindow(management.definition)
        window.title = "Native title differs from declared presentation"
        let token = try XCTUnwrap(management.manager.admit(window, metadata: metadata, to: workspace))
        return try XCTUnwrap(world.entry(for: token))
    }

    func addExternal() throws -> WindowState {
        let window = management.manager.makeWindow(management.definition)
        window.title = externalTitle
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        _ = world.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid, windowId: token.windowId, to: workspace,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: externalBundle, workspaceId: workspace, mode: .tiling,
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                title: externalTitle, windowLevel: .zero, parentWindowId: nil, frame: window.frame
            )
        )
        return try XCTUnwrap(world.entry(for: token))
    }

    func projector(overrides: [String: String] = [:], image: NSImage? = nil) -> WorkspaceBarWindowProjector {
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: controller.settings.settingsFileURL,
            imageLoader: { _ in image }, unavailableLogger: { _ in }
        )
        resolver.synchronize(overrides: overrides)
        return WorkspaceBarWindowProjector(
            workspaceManager: world, appInfoCache: controller.appInfoCache, iconResolver: resolver
        )
    }

    func close() {
        management.close()
    }
}

@MainActor
extension XCTestCase {
    func assertHostedSymbol(
        _ image: NSImage?, named reference: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try XCTUnwrap(image, file: file, line: line)
        let expected = try XCTUnwrap(
            NSImage(systemSymbolName: reference, accessibilityDescription: nil), file: file, line: line
        )
        let actualPixels = try XCTUnwrap(actual.tiffRepresentation, file: file, line: line)
        let expectedPixels = try XCTUnwrap(expected.tiffRepresentation, file: file, line: line)
        XCTAssertEqual(actualPixels, expectedPixels, file: file, line: line)
    }

    func presentationSubviews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { presentationSubviews(type, in: $0) }
    }
}
