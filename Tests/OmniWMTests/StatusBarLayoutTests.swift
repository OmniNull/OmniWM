// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class StatusBarLayoutTests: XCTestCase {
    func testDisabledLayoutPreservesTheExistingTitle() {
        let title = StatusBarController.statusButtonTitle(workspaceLabel: "Code", focusedAppName: "Xcode")
        let rendered = StatusBarController.statusButtonAttributedTitle(
            title,
            layout: nil,
            font: .menuBarFont(ofSize: 0)
        )
        XCTAssertEqual(rendered.string, " Code \u{2013} Xcode")
        XCTAssertNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testBothLayoutsRenderAlongsideWorkspaceAndKeyboardModes() throws {
        for layout in [ActiveLayoutKind.niri, .dwindle] {
            for workspace in [nil, "Code"] as [String?] {
                for mode in [nil, "Paused"] as [String?] {
                    let title = StatusBarController.statusButtonTitle(
                        workspaceLabel: workspace, focusedAppName: nil, modeTitle: mode
                    )
                    let rendered = StatusBarController.statusButtonAttributedTitle(
                        title, layout: layout, font: .menuBarFont(ofSize: 0)
                    )
                    XCTAssertEqual(rendered.string, title + " \u{FFFC}")
                    let attachment = try XCTUnwrap(rendered.attribute(
                        .attachment, at: rendered.length - 1, effectiveRange: nil
                    ) as? NSTextAttachment)
                    XCTAssertNotNil(attachment.image)
                    XCTAssertGreaterThan(attachment.bounds.width, 0)
                    XCTAssertGreaterThan(attachment.bounds.height, 0)
                }
            }
        }
        XCTAssertEqual(
            StatusBarController.statusButtonTitle(workspaceLabel: nil, focusedAppName: nil, modeTitle: "Paused"),
            " Paused"
        )
    }

    func testLayoutAccessibilityRetainsExistingStateInformation() {
        for layout in [ActiveLayoutKind.niri, .dwindle] {
            let name = StatusBarController.layoutDisplayName(layout)
            XCTAssertEqual(
                StatusBarController.statusButtonAccessibilityValue(
                    workspaceLabel: nil, focusedAppName: nil,
                    isRecording: false, isSecureInputActive: false, layout: layout
                ),
                name
            )
            XCTAssertEqual(
                StatusBarController.statusButtonAccessibilityValue(
                    workspaceLabel: "Code", focusedAppName: "Xcode",
                    isRecording: true, isSecureInputActive: true, layout: layout
                ),
                "Recording diagnostics, Secure Input is on, Workspace Code, Focused app Xcode, " + name
            )
        }
    }

    func testLayoutOnlyKeepsTheStatusItemRefreshConsumerEnabled() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StatusBarLayout")
        controller.settings.workspaceBar.enabled = false
        let statusBar = StatusBarController(
            settings: controller.settings, controller: controller, hiddenBarController: controller.hiddenBarController
        )
        controller.statusBarController = statusBar
        XCTAssertFalse(controller.statusBarRefreshIsEnabled)
        controller.settings.statusBar.showLayout = true
        XCTAssertTrue(controller.statusBarRefreshIsEnabled)
        XCTAssertTrue(controller.hasWorkspaceBarDataConsumers)
        controller.settings.statusBar.showLayout = false
        XCTAssertFalse(controller.statusBarRefreshIsEnabled)
    }
}
