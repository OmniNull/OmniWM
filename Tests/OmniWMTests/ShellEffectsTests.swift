// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellEffectsTests: XCTestCase {
    private func gallery() throws -> ShellRenderedWidget {
        let folder = try XCTUnwrap(ShellDefaults.bundled)
        let source = try ShellWidgetSourceLoader.build(.init(
            name: "effects-lab", shellDirectory: folder,
            sourceURL: folder.appendingPathComponent("widgets/effects-lab/init.luau"),
            directories: [folder], profile: "default"
        ))
        let widget = try ShellRenderedWidget(
            name: "effects-lab", source: source.main,
            directories: [folder.appendingPathComponent("shaders")],
            modules: source.modules, chunk: source.chunk
        )
        widget.surface.assetFolders = source.assetPackages
        widget.resources.images.onAssetChange = { [weak surface = widget.surface] url in
            surface?.refreshAssets(at: url)
        }
        widget.resources.shaders.onChange = { [weak surface = widget.surface] in surface?.refreshShaders() }
        return widget
    }

    private func click(_ help: String, _ widget: ShellRenderedWidget, value: Double? = nil) throws {
        let node = try XCTUnwrap(widget.renderPopout().first { widget.text.string($0.content.help) == help }, help)
        let action = try XCTUnwrap(node.content.action == 0 ? nil : node.content.action, help)
        var event = ShellEvent()
        event.value = value
        event.kind = value == nil ? .click : .slider
        widget.invoke(action, view: OMNI_VIEW_POPOUT, event: event)
    }

    func testMotionRecipesAreIndependentAndAllEffectsEncodeThroughThePublicAPI() throws {
        let module = try String(contentsOf: XCTUnwrap(ShellDefaults.bundledFile("lib/effects.luau")), encoding: .utf8)
        let widget = try ShellRenderedWidget(name: "recipes", source: """
        local effects = require("../lib/effects")
        local props = { w = 100, h = 60, key = "custom" }
        local first = effects.motion("pop", props)
        first.animate.response = 2
        first.appear.scale = 0.1
        local second = effects.motion("pop", props)
        assert(second.animate.response == 0.32 and second.appear.scale == 0.5)
        assert(props.animate == nil and props.appear == nil and second.key == "custom")
        assert(not pcall(function() effects.motion("missing") end))
        function render(ctx)
            local rows = {}
            for _, name in { "fade", "slide", "pop", "spring", "stretch", "indicator" } do
                rows[#rows + 1] = ui.box(effects.motion(name, { w = 100, h = 60 }))
            end
            for _, name in { "aurora", "sheen", "glow", "ring" } do
                rows[#rows + 1] = effects.shader(name, { w = 100, h = 60 })
            end
            for _, name in { "circle", "wipe", "dissolve" } do
                rows[#rows + 1] = ui.stack{ w = 100, h = 60, effects.mask(name) }
            end
            return ui.column(rows)
        end
        """, modules: [.init(path: "lib/effects.luau", source: module)], chunk: "@widgets/recipes/init.luau")
        widget.render(ShellBarData())
        let shaders = widget.tree().filter { $0.kind == .shader }
        XCTAssertEqual(shaders.count, 7)
        XCTAssertEqual(shaders.map(\.content.rate), [30, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(shaders.filter(\.paint.masks).count, 3)
        for node in shaders {
            XCTAssertNotNil(ShellDefaults.bundledFile("shaders/" + widget.text.string(node.content.text)))
        }
        XCTAssertEqual(widget.tree().filter(\.content.trail).count, 1)
    }

    func testGalleryControlsChooseMotionShadersMasksAndNativeMaterials() throws {
        let widget = try gallery()
        widget.render(ShellBarData())
        XCTAssertTrue(widget.tree().first?.content.opensPopout == true)
        XCTAssertEqual(widget.renderPopout().first?.paint.material, UInt8(OMNI_MATERIAL_GLASS))
        try click("Glass", widget)
        XCTAssertEqual(widget.renderPopout().first?.paint.material, 3)
        try click("Frosted", widget)
        XCTAssertEqual(widget.renderPopout().first?.paint.material, UInt8(OMNI_MATERIAL_GLASS))
        try click("Light", widget)
        var shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
        XCTAssertEqual(widget.text.string(shader.content.text), "effects-aurora.metal")
        XCTAssertEqual(shader.content.rate, 30)
        try click("Freeze", widget)
        XCTAssertEqual(widget.renderPopout().first { $0.kind == .shader }?.content.rate, 0)
        try click("Animate", widget)
        XCTAssertEqual(widget.renderPopout().first { $0.kind == .shader }?.content.rate, 30)
        for (label, name) in [("Sheen", "sheen"), ("Inner glow", "glow"), ("Gradient ring", "ring")] {
            try click(label, widget)
            shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
            XCTAssertEqual(widget.text.string(shader.content.text), "effects-\(name).metal")
            XCTAssertEqual(shader.content.rate, 0)
        }
        try click("Masks", widget)
        for (label, name) in [
            ("Circle", "circle"),
            ("Wipe", "wipe"),
            ("Dissolve", "dissolve"),
            ("Burn", "burn"),
            ("Smoke", "smoke")
        ] {
            try click(label, widget)
            shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
            XCTAssertEqual(widget.text.string(shader.content.text), "effects-\(name).metal")
            XCTAssertTrue(shader.paint.masks)
        }
        try click("Reveal progress", widget, value: 0.25)
        XCTAssertEqual(widget.renderPopout().first { $0.kind == .shader }?.content.params.w, 0.25)
    }

    func testGalleryExposesBlurTexturesAndAnimatedReveals() throws {
        let widget = try gallery()
        try click("Light", widget)
        try click("Rotating border", widget)
        XCTAssertEqual(widget.renderPopout().first { $0.kind == .shader }?.content.rate, 30)
        try click("Blur", widget)
        XCTAssertEqual(widget.renderPopout().first?.paint.material, UInt8(OMNI_MATERIAL_CLEAR))
        try click("Blur radius", widget, value: 0)
        try click("Saturation", widget, value: 1)
        let preview = try XCTUnwrap(widget.renderPopout().first { $0.paint.material == 3 })
        XCTAssertEqual(preview.paint.blurRadius, 0)
        XCTAssertEqual(preview.paint.saturation, 3)
        try click("Reset blur", widget)
        XCTAssertEqual(widget.renderPopout().first { $0.paint.material == 3 }?.paint.blurRadius, 20)
        try click("Texture", widget)
        var shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
        XCTAssertEqual(widget.text.string(shader.content.text), "effects-pixelate.metal")
        XCTAssertEqual(widget.text.string(shader.content.textureRef), "@omni-asset:effects-lab/sample.png")
        try click("Play preview", widget)
        shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
        XCTAssertEqual(shader.content.params.w, -2)
        XCTAssertEqual(shader.content.rate, 30)
        try click("Reveal progress", widget, value: 0.4)
        XCTAssertEqual(widget.renderPopout().first { $0.kind == .shader }?.content.params.w, 0.4)
        try click("Genie", widget)
        try click("Genie anchor", widget, value: 0.25)
        try click("Anchor: bottom", widget)
        shader = try XCTUnwrap(widget.renderPopout().first { $0.kind == .shader })
        XCTAssertEqual(shader.content.params.x, 0.25)
        XCTAssertEqual(shader.content.params.y, 1)
        try click("Masks", widget)
        try click("Burn", widget)
        XCTAssertEqual(widget.renderPopout().filter { $0.kind == .shader }.count, 2)
    }

    func testGalleryTabsFitAndRenderInBothAppearances() async throws {
        for dark in [false, true] {
            let widget = try gallery()
            widget.resources.palette.refresh(
                theme: .native, appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            for (tab, selection) in [
                ("Motion", "Pop"),
                ("Light", "Rotating border"),
                ("Masks", "Burn"),
                ("Masks", "Smoke"),
                ("Blur", ""),
                ("Texture", "Pixelation"),
                ("Texture", "Genie")
            ] {
                try click(tab, widget)
                if !selection.isEmpty { try click(selection, widget) }
                widget.layoutPopout()
                XCTAssertEqual(widget.surface.size.width, 392)
                XCTAssertLessThan(widget.surface.size.height, 700)
                await until { widget.surface.shaders.values.allSatisfy { !$0.program.isCompiling } }
                XCTAssertNil(widget.surface.failedShader)
                if ["Blur", "Texture"].contains(tab) {
                    await until {
                        widget.resources.images.image(
                            "@omni-asset:effects-lab/sample.png",
                            folders: [],
                            packages: widget.surface.assetFolders
                        ) != nil
                    }
                }
                if tab == "Texture", let slot = widget.surface.shaders.keys.first {
                    let scene = widget.surface.scene
                    await until {
                        ShellLayerScene.engineQueue.sync {
                            (scene.shaders?.alpha(slot, at: CGPoint(x: 180, y: 120)) ?? 0) > 0
                        }
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] {
                    try ShellBundledWidgetTests.writeSnapshot(
                        widget.surface, name: "lab-\(tab)-\(selection)-\(dark ? "dark" : "light")",
                        dark: dark, directory: directory
                    )
                }
            }
        }
    }

    func testGalleryMotionVisibilityAndIndicatorRetargetWithoutTimers() throws {
        let widget = try gallery()
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Make it yours"))
        try click("Hide", widget)
        _ = widget.renderPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Make it yours"))
        try click("Show", widget)
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Make it yours"))
        for name in ["Slide", "Fade", "Spring", "Stretch", "Pop"] {
            try click(name, widget)
            XCTAssertFalse(widget.renderPopout().isEmpty)
        }
        try click("Indicator", widget)
        let before = try XCTUnwrap(widget.renderPopout().first { $0.content.trail })
        try click("Move", widget)
        let after = try XCTUnwrap(widget.renderPopout().first { $0.content.trail })
        XCTAssertEqual(before.key, after.key)
        XCTAssertNotEqual(before.layout.dx, after.layout.dx)
    }

    func testLibraryAndGalleryAreInstalledAndDiscoverableWithoutChangingLanes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ShellDefaults.sync(into: directory), [])
        let layout = try ShellBarLayout.load(shellDirectory: directory).get()
        XCTAssertTrue(layout.addable.contains { $0.name == "effects-lab" })
        XCTAssertFalse((layout.leading + layout.center + layout.trailing).contains("effects-lab"))
        XCTAssertEqual(ShellBarLayout.title(of: "effects-lab"), "Effects Lab")
        let config = ShellConfig.resolve(shellDirectory: directory)
        let source = try ShellWidgetSourceLoader.build(.init(
            name: "effects-lab", shellDirectory: directory,
            sourceURL: XCTUnwrap(config.widget("effects-lab")),
            directories: config.directories, profile: config.profile
        ))
        XCTAssertTrue(source.modules.contains { $0.path == "default/lib/effects.luau" })
    }
}
