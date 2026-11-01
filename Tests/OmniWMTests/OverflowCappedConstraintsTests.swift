// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class OverflowCappedConstraintsTests: XCTestCase {
    private let workArea = CGSize(width: 2560, height: 1410)

    private func constraints(minWidth: CGFloat = 100, minHeight: CGFloat = 100) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: CGSize(width: minWidth, height: minHeight),
            maxSize: .zero,
            isFixed: false
        )
    }

    private func capped(
        _ constraints: WindowSizeConstraints,
        layoutReason: LayoutReason = .standard,
        horizontalNeighbor: Bool = false,
        verticalNeighbor: Bool = false
    ) -> WindowSizeConstraints {
        LayoutRefreshController.overflowCappedConstraints(
            constraints,
            layoutReason: layoutReason,
            workArea: workArea,
            cappedAxes: MonitorNeighborAxes(horizontal: horizontalNeighbor, vertical: verticalNeighbor)
        )
    }

    func testMinIsKeptWithoutNeighbors() {
        for (label, width, height) in [("fitting", CGFloat(800), CGFloat(600)), ("oversized", 3000, 2000)] {
            let result = capped(constraints(minWidth: width, minHeight: height))
            XCTAssertEqual(result.minSize.width, width, label)
            XCTAssertEqual(result.minSize.height, height, label)
        }
    }

    func testOversizedMinWidthCappedByHorizontalNeighbor() {
        let result = capped(constraints(minWidth: 3000, minHeight: 2000), horizontalNeighbor: true)
        XCTAssertEqual(result.minSize.width, workArea.width)
        XCTAssertEqual(result.minSize.height, 2000)
    }

    func testOversizedMinHeightCappedByVerticalNeighbor() {
        let result = capped(constraints(minWidth: 3000, minHeight: 2000), verticalNeighbor: true)
        XCTAssertEqual(result.minSize.width, 3000)
        XCTAssertEqual(result.minSize.height, workArea.height)
    }

    func testFittingMinIsNotAffectedByNeighbors() {
        let result = capped(
            constraints(minWidth: 800, minHeight: 600),
            horizontalNeighbor: true,
            verticalNeighbor: true
        )
        XCTAssertEqual(result.minSize.width, 800)
        XCTAssertEqual(result.minSize.height, 600)
    }

    func testFixedConstraintsPassThrough() {
        let fixed = WindowSizeConstraints.fixed(size: CGSize(width: 3000, height: 2000))
        let result = capped(fixed, horizontalNeighbor: true, verticalNeighbor: true)
        XCTAssertTrue(result.isFixed)
        XCTAssertEqual(result.minSize.width, 3000)
        XCTAssertEqual(result.minSize.height, 2000)
    }

    func testNativeFullscreenPassesThrough() {
        let result = capped(
            constraints(minWidth: 3000, minHeight: 2000),
            layoutReason: .nativeFullscreen,
            horizontalNeighbor: true,
            verticalNeighbor: true
        )
        XCTAssertEqual(result.minSize.width, 3000)
        XCTAssertEqual(result.minSize.height, 2000)
    }
}

final class MonitorNeighborAxesTests: XCTestCase {
    private func monitor(id: UInt32, frame: CGRect) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Test\(id)"
        )
    }

    func testMonitorNeighborAxes() {
        let main = monitor(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let cases: [(String, [Monitor], Bool, Bool)] = [
            ("single", [main], false, false),
            (
                "side by side",
                [main, monitor(id: 2, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080))],
                true,
                false
            ),
            ("stacked", [main, monitor(id: 2, frame: CGRect(x: 300, y: 1440, width: 1920, height: 1080))], false, true),
            ("offset", [main, monitor(id: 2, frame: CGRect(x: 2560, y: 1000, width: 1920, height: 1080))], true, false)
        ]
        for (label, monitors, horizontal, vertical) in cases {
            let axes = main.neighborAxes(among: monitors)
            XCTAssertEqual(axes.horizontal, horizontal, label)
            XCTAssertEqual(axes.vertical, vertical, label)
        }
    }
}

final class ObservedMinSizeCapTests: XCTestCase {
    @MainActor
    func testObservedOversizedMinCannotOverrideNoBleedCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMObservedMinCapTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
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
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let primary = Monitor(
            id: .init(displayId: 811),
            displayId: 811,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Primary"
        )
        let neighbor = Monitor(
            id: .init(displayId: 812),
            displayId: 812,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Neighbor"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([primary, neighbor])

        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(811_001), windowId: 811_101),
            pid: 811_001,
            windowId: 811_101,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(minSize: CGSize(width: 5000, height: 500)),
            for: token
        ))

        let input = try XCTUnwrap(
            controller.layoutRefreshController.buildRefreshInput(
                workspaceId: workspaceId,
                monitor: primary,
                resolveConstraints: true,
                isActiveWorkspace: true
            )
        )
        let snapshot = try XCTUnwrap(input.windows.first { $0.token == token })

        XCTAssertEqual(snapshot.constraints.minSize.width, input.monitor.workingFrame.width, accuracy: 0.5)
        XCTAssertEqual(snapshot.constraints.minSize.height, 500, accuracy: 0.5)

        controller.workspaceManager.setCachedConstraints(.unconstrained, for: token)
        let hints = ObservedPackingHints(height: ObservedAxisHint(requested: 300, observed: 306))
        XCTAssertTrue(controller.workspaceManager.setObservedSizeEvidence(
            ObservedSizeEvidence(hints: hints),
            for: token
        ))
        let hinted = try XCTUnwrap(
            controller.layoutRefreshController.buildRefreshInput(
                workspaceId: workspaceId,
                monitor: primary,
                resolveConstraints: true,
                isActiveWorkspace: true
            )?.windows.first { $0.token == token }
        )
        XCTAssertEqual(hinted.constraints, .unconstrained)
        XCTAssertEqual(hinted.packingHints, hints)
    }
}
