// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Metal
@testable import OmniWM
import QuartzCore
import XCTest

final class ShellOffscreenRenderer {
    private let raster: ShellLayerRaster

    init(root: CALayer, width: Int, height: Int) throws {
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        raster = try ShellLayerRaster(root: root, width: width, height: height)
    }

    func encode(paused time: CFTimeInterval? = nil) throws -> any MTLCommandBuffer {
        try raster.encode(paused: time)
    }

    func render(paused time: CFTimeInterval? = nil) throws -> [UInt8] {
        try finish(encode(paused: time))
    }

    func finish(_ marker: any MTLCommandBuffer) throws -> [UInt8] {
        marker.commit()
        marker.waitUntilCompleted()
        XCTAssertEqual(marker.status, .completed)
        guard marker.status == .completed else {
            throw ShellScriptFailure(
                kind: .runtime, message: marker.error?.localizedDescription ?? "The layer preview GPU render failed."
            )
        }
        return raster.pixels()
    }
}
