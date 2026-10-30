// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    func testAZeroPositionalIndexFormatsAsAMissingArgument() {
        let value = "x"
        XCTAssertEqual(ShellLocalizer.format("%0$@", [.text(value)]), ShellLocalizer.format("%@", []))
        let strings = ShellStrings(["Greeting": "%0$@ %1$@"])
        XCTAssertEqual(ShellLocalizer.string("Greeting", [.text(value)], strings: strings), " \(value)")
    }

    func testKeysResolveThroughTheShellTableAndUnknownKeysPassThrough() {
        XCTAssertEqual(ShellLocalizer.string("Wind %@", [.text("5 km/h")]), "Wind 5 km/h")
        XCTAssertEqual(ShellLocalizer.string("Not a %@ key", [.text("x")]), "Not a %@ key")
    }

    func testWidgetsLocalizeThroughTheHost() throws {
        let speed = "5 km/h"
        XCTAssertTrue(try rendered(speed).contains(ShellLocalizer.string("Wind %@", [.text(speed)])))
    }

    func testWidgetsLocalizeThroughTheirStyleStringsBeforeTheAppTable() throws {
        let speed = "5 km/h"
        let template = "Breeze %@"
        let strings = ShellStrings(["Wind %@": template])
        XCTAssertTrue(try rendered(speed, strings: strings).contains(ShellLocalizer.format(template, [.text(speed)])))
    }

    func testTheVMKeepsItsStringsUntilItIsDestroyed() throws {
        weak var released: ShellStrings?
        let vm = try XCTUnwrap({ () -> OpaquePointer? in
            let strings = ShellStrings(["Greeting": "Hello"])
            released = strings
            return ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit, strings: strings)
        }())
        XCTAssertNotNil(released)
        XCTAssertEqual(omni_vm_destroy(vm), OMNI_OK)
        XCTAssertNil(released)
    }

    private func rendered(_ speed: String, strings: ShellStrings = .empty) throws -> [String] {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit, strings: strings))
        defer { _ = omni_vm_destroy(vm) }
        let source = "function render(ctx) return ui.text{ text = omniwm.l10n(\"Wind %@\", \"\(speed)\") } end"
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_vm_load(vm, "=l10n", source, source.utf8.count, ShellWidgetPackage.loadBudget, &error, error.count),
            OMNI_OK
        )
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        var stats = omni_render_stats()
        XCTAssertEqual(
            omni_instance_render(instance, OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count),
            OMNI_OK
        )
        var size = 0
        let bytes = Array(UnsafeBufferPointer(
            start: try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &size)),
            count: size
        ))
        let text = ShellTextStore()
        text.ingest(wire: bytes)
        return text.strings
    }
}
