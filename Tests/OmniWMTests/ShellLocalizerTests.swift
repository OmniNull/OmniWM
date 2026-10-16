// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellLocalizerTests: XCTestCase {
    func testFormattingCoercesArgumentsToTheirSpecifiers() {
        XCTAssertEqual(ShellLocalizer.format("%lld%% chance of rain", [.number(40.7)]), "40% chance of rain")
        XCTAssertEqual(ShellLocalizer.format("%2$@ then %1$@", [.text("a"), .text("b")]), "b then a")
        XCTAssertEqual(ShellLocalizer.format("%@ and %lld", [.number(3), .text("7")]), "3 and 7")
        XCTAssertEqual(ShellLocalizer.format("%.1f", [.number(2.25)]).first, "2")
        XCTAssertEqual(ShellLocalizer.format("Wind %@", []), "Wind ")
        XCTAssertEqual(ShellLocalizer.format("a%n%sb", [.text("x"), .text("y")]), "ab")
    }

    func testKeysResolveThroughTheShellTableAndUnknownKeysPassThrough() {
        XCTAssertEqual(ShellLocalizer.string("Wind %@", [.text("5 km/h")]), "Wind 5 km/h")
        XCTAssertEqual(ShellLocalizer.string("Not a %@ key", [.text("x")]), "Not a %@ key")
    }

    func testWidgetsLocalizeThroughTheHost() throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        let source = "function render(ctx) return ui.text{ text = omniwm.l10n(\"Wind %@\", \"5 km/h\") } end"
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(omni_vm_load(vm, "=l10n", source, source.utf8.count, 100_000_000, &error, error.count), OMNI_OK)
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        XCTAssertEqual(omni_instance_render(instance, OMNI_VIEW_BAR, 8_000_000, &stats, &error, error.count), OMNI_OK)
        var size = 0
        let bytes = Array(UnsafeBufferPointer(
            start: try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &size)),
            count: size
        ))
        let text = ShellTextStore()
        text.ingest(wire: bytes)
        XCTAssertTrue(text.strings.contains("Wind 5 km/h"))
    }
}
