// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarBorderClearanceTests: XCTestCase {
    private let monitor = Monitor(
        id: .init(displayId: 95_803), displayId: 95_803,
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
        hasNotch: false, name: "Border clearance"
    )

    func testOverlappingBarClearsExternalBorderWithSmallTopGapAndOffsets() {
        let controller = makeController()
        controller.settings.gaps.outerGapTop = 8
        for fullWidth in [false, true] {
            controller.settings.workspaceBar.fullWidth = fullWidth
            for height in [24.0, 32, 40] {
                controller.settings.workspaceBar.height = height
                for offset in [-5.0, 0, 5] {
                    controller.settings.workspaceBar.yOffset = offset
                    for scale: CGFloat in [1, 2] {
                        for fullscreenUsesOuterGaps in [false, true] {
                            controller.settings.gaps.fullscreenUsesOuterGaps = fullscreenUsesOuterGaps
                            assertBordersClearBar(controller, scale: scale)
                        }
                    }
                }
            }
        }
    }

    func testAllReservedEdgesClearTiledAndFillBorders() {
        let controller = makeController()
        for position in WorkspaceBarPosition.allCases {
            controller.settings.workspaceBar.position = position
            for fullscreenUsesOuterGaps in [false, true] {
                controller.settings.gaps.fullscreenUsesOuterGaps = fullscreenUsesOuterGaps
                assertBordersClearBar(controller, scale: 2)
            }
        }
    }

    func testLargerOuterGapsDoNotGainAnotherBorderWidth() {
        let controller = makeController()
        controller.settings.gaps.outerGapTop = 64
        controller.settings.gaps.outerGapBottom = 16
        controller.settings.gaps.outerGapLeft = 16
        controller.settings.gaps.outerGapRight = 16
        for position in WorkspaceBarPosition.allCases {
            controller.settings.workspaceBar.position = position
            controller.settings.borders.enabled = false
            let withoutBorders = controller.layoutFrames(for: monitor, scale: 2).workingFrame
            controller.settings.borders.enabled = true
            XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 2).workingFrame, withoutBorders, "\(position)")
        }
    }

    func testOverlayBarsKeepExistingBorderClearance() {
        let controller = makeController()
        for position in WorkspaceBarPosition.allCases {
            controller.settings.workspaceBar.position = position
            controller.settings.workspaceBar.enabled = false
            let baseline = controller.layoutFrames(for: monitor, scale: 2)
            controller.settings.workspaceBar.enabled = true
            for autoHide in [false, true] {
                controller.settings.workspaceBar.autoHide = autoHide
                controller.settings.workspaceBar.reserveLayoutSpace = autoHide
                let overlay = controller.layoutFrames(for: monitor, scale: 2)
                XCTAssertEqual(overlay.workingFrame, baseline.workingFrame, "\(position), autoHide=\(autoHide)")
                XCTAssertEqual(overlay.borderSafeFillFrame, baseline.borderSafeFillFrame)
                XCTAssertEqual(overlay.fullscreenLayoutFrame, baseline.fullscreenLayoutFrame)
            }
        }
    }

    func testExplicitRoomEdgesKeepTheirWindowDistances() throws {
        let controller = makeController()
        controller.settings.island.enabled = true
        controller.settings.workspaceBar.height = 40
        let room = WorkspaceBarRoom(edges: [
            .left: .init(value: 16, mode: .total), .right: .init(value: 16, mode: .total),
            .top: .init(value: 48, mode: .total), .bottom: .init(value: 16, mode: .total)
        ], displays: .all)
        controller.settings.workspaceBar.profileOverride = WorkspaceBarProfileOverride(
            profile: "room", settings: MonitorBarSettings(monitorName: ""), room: room
        )
        let expected = try room.envelope(on: monitor)
        for bordersEnabled in [false, true] {
            controller.settings.borders.enabled = bordersEnabled
            for position in WorkspaceBarPosition.allCases {
                controller.settings.workspaceBar.position = position
                for fullscreenUsesOuterGaps in [false, true] {
                    controller.settings.gaps.fullscreenUsesOuterGaps = fullscreenUsesOuterGaps
                    let frames = controller.layoutFrames(for: monitor, scale: 2)
                    XCTAssertEqual(frames.workingFrame, expected, "\(position), borders=\(bordersEnabled)")
                    XCTAssertEqual(frames.borderSafeFillFrame, expected)
                }
            }
        }
    }

    func testRoomOnAnotherEdgeKeepsBarBorderClearance() {
        let controller = makeController()
        controller.settings.island.enabled = true
        controller.settings.workspaceBar.profileOverride = WorkspaceBarProfileOverride(
            profile: "room", settings: MonitorBarSettings(monitorName: ""),
            room: WorkspaceBarRoom(edges: [.left: .init(value: 16, mode: .total)], displays: .all)
        )
        assertBordersClearBar(controller, scale: 2)
    }

    private func assertBordersClearBar(
        _ controller: WMController,
        scale: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolved = controller.settings.workspaceBar.resolved(for: monitor)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        var barFrame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)
        barFrame.origin.y = WorkspaceBarGeometry.constrainedOriginY(
            barFrame.minY, height: barFrame.height, screenFrame: monitor.frame
        )
        let frames = controller.layoutFrames(for: monitor, scale: scale)
        let border = BorderConfig(enabled: true, width: CGFloat(controller.settings.borders.width))
        for frame in [frames.workingFrame, frames.borderSafeFillFrame] {
            let paintedFrame = border.resolvedGeometry(for: frame, scale: scale).surfaceFrame
            XCTAssertFalse(
                paintedFrame.intersects(barFrame),
                "\(resolved.position), fullWidth=\(resolved.fullWidth), height=\(resolved.height), "
                    + "offset=\(resolved.yOffset), scale=\(scale): border \(paintedFrame), bar \(barFrame)",
                file: file, line: line
            )
        }
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarBorderTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.borders.enabled = true
        settings.borders.width = 2.25
        settings.gaps.outerGapTop = 0
        settings.gaps.outerGapBottom = 0
        settings.gaps.outerGapLeft = 0
        settings.gaps.outerGapRight = 0
        settings.workspaceBar.enabled = true
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.autoHide = false
        settings.workspaceBar.revealModifier = .off
        settings.workspaceBar.position = .overlappingMenuBar
        settings.workspaceBar.notchMode = .off
        settings.workspaceBar.height = 32
        return WMController(settings: settings)
    }
}
