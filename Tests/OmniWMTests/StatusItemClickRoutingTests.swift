// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

final class StatusItemClickRoutingTests: XCTestCase {
    func testHiddenMenuBarIconReturnsWhileRecordingOrSecureInputIsShown() {
        XCTAssertEqual(StatusBarController.labeledImagePosition(showIcon: true, hasStateIcon: false), .imageLeft)
        XCTAssertEqual(StatusBarController.labeledImagePosition(showIcon: false, hasStateIcon: false), .noImage)
        XCTAssertEqual(StatusBarController.labeledImagePosition(showIcon: false, hasStateIcon: true), .imageLeft)
    }

    func testRightClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: true, optionHeld: false), .hiddenIconsBar)
    }

    func testOptionLeftClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: false, optionHeld: true), .hiddenIconsBar)
    }

    func testOptionRightClickOpensHiddenIconsBar() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: true, optionHeld: true), .hiddenIconsBar)
    }

    func testPlainLeftClickOpensMenu() {
        XCTAssertEqual(StatusBarController.clickRoute(isRightClick: false, optionHeld: false), .menu)
    }

    func testAccessibilityValueIncludesWorkspaceAppAndRecordingState() {
        XCTAssertEqual(
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: "Code",
                focusedAppName: "Xcode",
                isRecording: true,
                isSecureInputActive: false
            ),
            "Recording diagnostics, Workspace Code, Focused app Xcode"
        )
        XCTAssertEqual(
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: "Code",
                focusedAppName: nil,
                isRecording: false,
                isSecureInputActive: true
            ),
            "Secure Input is on, Workspace Code"
        )
    }

    func testAccessibilityValueHasStableFallback() {
        XCTAssertEqual(
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: nil,
                focusedAppName: nil,
                isRecording: false,
                isSecureInputActive: false
            ),
            "Window manager controls"
        )
    }
}
