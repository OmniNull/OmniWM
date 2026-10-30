// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellSettingsPreviewNativeRasterTests: XCTestCase {
    func testNativeGlassPreviewKeepsTopDownCoordinatesScaleAndSceneParent() async throws {
        let widget = try ShellRenderedWidget(name: "preview-native-glass", source: """
        function render(ctx)
            return ui.stack{w=120,h=80,align='topLeading',
                ui.glass{w=40,h=20,dx=8,dy=10,align='topLeading',fill='#2030605c',
                    shadow='#00000000',ui.shape{w=40,h=20,radius=4}},
                ui.box{w=10,h=10,dx=90,dy=60,align='topLeading',fill='#ff0000'}}
        end
        """)
        widget.render(ShellBarData())
        let scene = widget.surface.scene
        let parent = scene.container.superlayer
        for scale: CGFloat in [1, 2] {
            let image = try await ShellSettingsPreviewRaster.raster(
                scene,
                size: CGSize(width: 120, height: 80),
                scale: scale
            )
            XCTAssertEqual(image.width, Int(120 * scale))
            XCTAssertEqual(image.height, Int(80 * scale))
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = Int(CGFloat(y) * scale) * image.bytesPerRow + Int(CGFloat(x) * scale) * 4
                return Array(bytes[offset ..< offset + 4])
            }
            XCTAssertGreaterThan(pixel(28, 20)[3], 80)
            XCTAssertEqual(pixel(28, 60)[3], 0)
            XCTAssertEqual(pixel(95, 65), [0, 0, 255, 255])
            XCTAssertEqual(pixel(95, 15)[3], 0)
            ShellLayerScene.engineQueue.sync {
                XCTAssertTrue(scene.container.superlayer === parent)
                XCTAssertTrue(scene.rasterCompletions.isEmpty)
            }
        }
    }
}
