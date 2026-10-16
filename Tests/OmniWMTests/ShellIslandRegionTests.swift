// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellIslandRegionTests: XCTestCase {
    func testTransparentContainersAndCapsuleGapRemainUncovered() throws {
        let widget = try ShellRenderedWidget(name: "regions", source: """
        function render(ctx)
            return ui.row{
                gap = 20,
                ui.box{ w = 40, h = 30, fill = "accent", radius = 15 },
                ui.box{ w = 40, h = 30 },
                ui.box{ w = 40, h = 30, onClick = "focus left" },
            }
        end
        """)
        widget.surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        widget.render(ShellBarData())
        let regions = widget.surface.islandRegions()
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 20, y: 15)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 140, y: 15)) })
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: 50, y: 15)) })
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: 80, y: 15)) })
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: 200, y: 15)) })
    }

    func testFullyTransparentPaintDoesNotClaimArea() throws {
        let widget = try ShellRenderedWidget(name: "transparent", source: """
        function render(ctx)
            return ui.row{
                ui.box{ w = 40, h = 30, fill = "accent", opacity = 0 },
                ui.box{ w = 40, h = 30, fill = "accent" },
            }
        end
        """)
        widget.surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        widget.render(ShellBarData())
        XCTAssertEqual(widget.surface.islandRegions(), [CGRect(x: 40, y: 0, width: 40, height: 30)])
    }

    @MainActor
    private final class RegionState {
        var visible = true
        var regions: [CGRect] = []
    }

    func testRegistryUsesRegionListForBothPointerQueries() {
        let scene = SurfaceScene()
        let state = RegionState()
        state.regions = [
            CGRect(x: 100, y: 100, width: 40, height: 30),
            CGRect(x: 180, y: 100, width: 40, height: 30)
        ]
        scene.registerWindowNumber(node: SurfaceScene.SurfaceNode(
            id: "island",
            policy: SurfacePolicy(
                kind: .shellIsland,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            window: nil,
            windowObjectIdentifier: nil,
            windowNumber: 991,
            frameProvider: { CGRect(x: 0, y: 0, width: 1000, height: 500) },
            visibilityProvider: { state.visible },
            regionProvider: { state.regions }
        ))
        for point in [CGPoint(x: 160, y: 115), CGPoint(x: 800, y: 300)] {
            XCTAssertFalse(scene.containsInteractive(point: point))
            XCTAssertFalse(scene.containsGeometric(point: point))
        }
        XCTAssertTrue(scene.containsInteractive(point: CGPoint(x: 120, y: 115)))
        XCTAssertTrue(scene.containsGeometric(point: CGPoint(x: 200, y: 115)))
        state.regions.removeAll()
        XCTAssertFalse(scene.containsInteractive(point: CGPoint(x: 120, y: 115)))
        state.regions.append(CGRect(x: 100, y: 100, width: 40, height: 30))
        state.visible = false
        XCTAssertFalse(scene.containsGeometric(point: CGPoint(x: 120, y: 115)))
    }
}
