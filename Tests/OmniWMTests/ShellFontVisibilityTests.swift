// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellWidgetPackage {
    fileprivate func rootFont() -> UInt32? {
        guard let instance = script?.instances.values.first else { return nil }
        var count = 0
        guard let bytes = omni_instance_output(instance, OMNI_VIEW_BAR, &count),
              count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride
        else { return nil }
        let node = UnsafeRawPointer(bytes).loadUnaligned(
            fromByteOffset: MemoryLayout<omni_wire_header>.stride,
            as: omni_wire_node.self
        )
        return (UInt32(node.style) & OMNI_STYLE_FONT_MASK) >> OMNI_STYLE_FONT_SHIFT
    }

    fileprivate func reloads(forFonts folders: [URL]) async -> Bool {
        guard let script else { return false }
        var source = ShellWidgetSource(chunk: loadedChunk, main: loadedMain, modules: [])
        source.fontFolders = folders
        await updateComponents(source, in: script)
        return reloadRequested
    }
}

@MainActor
final class ShellFontVisibilityTests: XCTestCase {
    private let main = "function render(ctx) return ui.text{ text = 'Grotesk', font = 'Space Grotesk' } end"

    private func package(_ folders: [URL]) async -> ShellWidgetPackage {
        let package = ShellWidgetPackage(name: "fonts", generation: 1, outbox: ShellWidgetOutbox { _ in })
        var source = ShellWidgetSource(chunk: "=fonts", main: main, modules: [])
        source.fontFolders = folders
        let failure = await package.load(source)
        XCTAssertNil(failure)
        return package
    }

    func testAPackageResolvesAFamilyOnlyThroughItsOwnFontFolders() async throws {
        let id = try ShellFontFixture.id()
        var fonts: [UInt32?] = []
        for folders in [try ShellFontFixture.folders(), [], try ShellFontFixture.folders()] {
            let package = await package(folders)
            await package.receive(.bars([ShellBarKey(monitor: Monitor.ID(displayId: 94300)): ShellBarData()]))
            fonts.append(await package.rootFont())
            await package.close()
        }
        XCTAssertEqual(fonts, [UInt32(id), 0, UInt32(id)])
    }

    func testAChangedFontSetReloadsTheIslandRootInsteadOfPatchingIt() async throws {
        let package = await package(try ShellFontFixture.folders())
        let unchanged = await package.reloads(forFonts: try ShellFontFixture.folders())
        XCTAssertFalse(unchanged)
        let changed = await package.reloads(forFonts: [])
        XCTAssertTrue(changed)
        await package.close()
    }

    func testNativeInputsUseTheFaceTheTextStoreMeasures() throws {
        _ = NSApplication.shared
        let id = try ShellFontFixture.id()
        let widget = try ShellRenderedWidget(
            name: "font-input",
            source: """
            function render(ctx)
                return ui.input{ key = 'query', w = 160, h = 24, text = 'Grotesk', font = 'Space Grotesk',
                    weight = 'bold', size = 14 }
            end
            """,
            fonts: try ShellFontFixture.fonts()
        )
        widget.surface.view.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        widget.render(ShellBarData())
        let input = try XCTUnwrap(widget.surface.textInputs.values.first)
        let native = try XCTUnwrap(input.field?.font) as CTFont
        let style = UInt32(id) << OMNI_STYLE_FONT_SHIFT | 7 << OMNI_STYLE_WEIGHT_SHIFT | 1400 << OMNI_STYLE_SIZE_SHIFT
        let measured = widget.text.font(style)
        XCTAssertEqual(CTFontCopyFamilyName(native) as String, ShellFontFixture.family)
        XCTAssertEqual(CTFontCopyPostScriptName(native) as String, CTFontCopyPostScriptName(measured) as String)
        XCTAssertEqual(ShellFontFixture.variation(native), ShellFontFixture.variation(measured))
        XCTAssertEqual(ShellFontFixture.variation(native)[ShellTextStyle.tag("wght")], 700)
        XCTAssertEqual(CTFontGetSize(native), 14)
    }
}
