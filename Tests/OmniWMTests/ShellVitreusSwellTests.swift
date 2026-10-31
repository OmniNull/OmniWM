// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusSwellTests: XCTestCase {
    private func widget(_ settings: [String: ShellComponentValue]) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        VitreusFixture.settings(widget, settings)
        VitreusFixture.show(widget)
        return widget
    }

    private func spectrum(_ widget: ShellRenderedWidget, _ key: String) -> ShellSpectrumShapeRecipe? {
        VitreusFixture.find(widget, key: key).flatMap {
            ShellSpectrumShapeRecipe(widget.text.string(widget.surface.layout.core.content(of: $0).text))
        }
    }

    private func listens(_ widget: ShellRenderedWidget) -> Bool {
        widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).flags & OMNI_WIRE_AUDIO != 0 }
    }

    func testTheBarSwellsOnlyWhileTheVisualiserShowsAndRestsUnderAnOpenDrawer() throws {
        let off = try widget([:])
        XCTAssertNil(spectrum(off, "shell"))
        XCTAssertFalse(listens(off))
        let other = VitreusFixture.bar(VitreusFixture.monitor(id: VitreusFixture.monitor().displayId + 1)).monitorId
        let elsewhere = try widget(["visualiser": .bool(true), "mon": .string(other)])
        XCTAssertNil(spectrum(elsewhere, "shell"))
        XCTAssertFalse(listens(elsewhere))

        let bar = try widget(["visualiser": .bool(true)])
        let recipe = try XCTUnwrap(spectrum(bar, "shell"))
        XCTAssertNotNil(recipe.swell)
        XCTAssertGreaterThan(recipe.gain, 0)
        XCTAssertTrue(listens(bar))
        XCTAssertTrue(try bar.surface.layout.core.content(of: VitreusFixture.element(bar, key: "shell")).glassHit)
        VitreusFixture.trigger(bar.instance, "drawer-calendar", VitreusFixture.bar().monitorId)
        VitreusFixture.show(bar)
        XCTAssertEqual(spectrum(bar, "shell")?.gain, 0)
    }
}
