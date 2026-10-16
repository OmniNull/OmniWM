// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellMenuWidgetTests: XCTestCase {
    private var shell: URL!

    override func setUp() async throws {
        shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: shell)
    }

    func testMenuWidgetsFitEveryProfileAndKeepTheirNativeClickAnchors() throws {
        for profile in ShellProfiles.names(in: shell) {
            _ = try ShellProfiles.select(profile, in: shell)
            let config = ShellConfig.resolve(shellDirectory: shell)
            let height = config.barOverride?.settings.height ?? 24
            for vertical in [false, true] {
                for scale in [CGFloat(1), 2] {
                    for dark in [false, true] {
                        try renderMenus(config, height: height, vertical: vertical, scale: scale, dark: dark)
                    }
                }
            }
        }
    }

    func testMenuWidgetsInheritEveryBundledPalette() throws {
        let themes = shell.appendingPathComponent("default/themes", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: themes.path)
            .filter { $0.hasSuffix(".toml") }.map { String($0.dropLast(5)) }.sorted()
        XCTAssertEqual(names.count, 14)
        for theme in names {
            _ = try ShellProfiles.selectTheme(theme, in: shell)
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], theme)
            for dark in [false, true] {
                try renderMenus(config, height: 32, vertical: false, scale: 2, dark: dark)
            }
        }
    }

    func testAppMenuUsesIconOverridesAndFallsBackToTheFocusedPID() throws {
        let config = ShellConfig.resolve(shellDirectory: shell)
        let override = NSImage(size: CGSize(width: 24, height: 24))
        var lookedUp: [String] = []
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false), iconOverride: { bundle in
            lookedUp.append(bundle)
            return override
        })
        let widget = try makeWidget("app-menu", config: config, scale: 2, resources: resources)
        setApp(widget, bundle: "com.apple.finder")
        widget.render(bar(config, height: 32, vertical: false))
        XCTAssertEqual(lookedUp, ["com.apple.finder"])
        let bundled = try XCTUnwrap(widget.tree().first { $0.kind == .image })
        XCTAssertEqual(bundled.content.iconSource, .bundle)
        XCTAssertEqual(widget.text.string(bundled.content.text), "com.apple.finder")
        XCTAssertFalse(bundled.content.color.isVisible)

        setApp(widget, bundle: "", pid: 42)
        widget.render(bar(config, height: 32, vertical: false))
        let fallback = try XCTUnwrap(widget.tree().first { $0.kind == .image })
        XCTAssertEqual(fallback.content.iconSource, .pid)
        XCTAssertEqual(widget.text.string(fallback.content.iconRef), "42")
        XCTAssertEqual(lookedUp, ["com.apple.finder"])
    }

    func testAppMenuDisappearsWhenNoApplicationIsAvailableAndReturnsWithAnApp() throws {
        let config = ShellConfig.resolve(shellDirectory: shell)
        let widget = try makeWidget("app-menu", config: config, scale: 2)
        let bar = bar(config, height: 32, vertical: false)
        widget.render(bar)
        XCTAssertEqual(widget.surface.size, .zero)
        setApp(widget, bundle: "com.apple.finder")
        widget.render(bar)
        XCTAssertGreaterThan(widget.surface.size.width, 0)
        widget.set("menuApp") { $0.null() }
        widget.render(bar)
        XCTAssertEqual(widget.surface.size, .zero)
        XCTAssertFalse(widget.tree().contains { widget.text.string($0.content.action) == "menu app" })
    }

    private func renderMenus(
        _ config: ShellConfig,
        height: Double,
        vertical: Bool,
        scale: CGFloat,
        dark: Bool
    ) throws {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.palette.refresh(
            theme: config.theme,
            appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        )
        let bar = bar(config, height: height, vertical: vertical)
        for (name, action) in [("apple-menu", "menu apple"), ("app-menu", "menu app")] {
            let widget = try makeWidget(name, config: config, scale: scale, resources: resources)
            setApp(widget, bundle: "com.apple.finder")
            widget.render(bar)
            let size = widget.surface.size
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertEqual(size.width, size.height)
            XCTAssertLessThanOrEqual(vertical ? size.width : size.height, height)
            let image = try XCTUnwrap(widget.tree().first { $0.kind == (name == "apple-menu" ? .symbol : .image) })
            XCTAssertLessThanOrEqual(image.layout.width, 24)
            XCTAssertLessThanOrEqual(image.layout.height, 24)
            if name == "apple-menu" {
                XCTAssertEqual(widget.text.string(image.content.text), "applelogo")
                if bar.style.solidBlack {
                    let color = try ShellRGBA(XCTUnwrap(resources.palette.color(image.content.color)))
                    XCTAssertGreaterThanOrEqual(color.contrast(ShellRGBA(CGColor(gray: 0, alpha: 1))), 4.5)
                }
            } else {
                XCTAssertEqual(image.content.iconSource, .bundle)
                XCTAssertEqual(widget.text.string(image.content.text), "com.apple.finder")
            }
            try click(widget, action: action)
            if dark, !vertical, scale == 2,
               let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"]
            {
                try ShellBundledWidgetTests.writeSnapshot(
                    widget.surface, name: "menus-\(config.profile)-\(config.themeName)-\(name)",
                    dark: dark, directory: directory,
                    background: bar.style.solidBlack ? CGColor(gray: 0, alpha: 1)
                        : resources.palette.color(Color(packed: 0), default: .background)
                )
            }
        }
    }

    private func click(_ widget: ShellRenderedWidget, action: String) throws {
        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 240, width: 160, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            widget.surface.view.removeFromSuperview()
            window.close()
        }
        let view = widget.surface.view
        view.frame.origin = CGPoint(x: 17, y: 13)
        try XCTUnwrap(window.contentView).addSubview(view)
        let element = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.action) == action
        }.first)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: element))
        let expected = window.convertToScreen(view.convert(frame, to: nil))
        var clicks: [ShellClick] = []
        widget.surface.onAction = { clicks.append($0) }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        let click = try XCTUnwrap(clicks.first)
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(widget.text.string(click.action), action)
        XCTAssertEqual(click.anchor.frame, expected)
        XCTAssertEqual(click.anchor.container, window.frame)
        XCTAssertEqual(click.source, element)
        XCTAssertEqual(click.event.button, .left)
    }

    private func makeWidget(
        _ name: String,
        config: ShellConfig,
        scale: CGFloat,
        resources: ShellResources? = nil
    ) throws -> ShellRenderedWidget {
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name, shellDirectory: shell, sourceURL: try XCTUnwrap(config.widget(name)),
            directories: config.directories, profile: config.profile
        ))
        return try ShellRenderedWidget(
            name: name, source: source.main, directories: config.directories, modules: source.modules,
            chunk: source.chunk, scale: scale, resources: resources
        )
    }

    private func setApp(_ widget: ShellRenderedWidget, bundle: String, pid: Int = 42) {
        widget.set("menuApp") {
            $0.map(3)
            $0.key("pid")
            $0.number(Double(pid))
            $0.key("name")
            $0.string("Finder")
            $0.key("bundle")
            $0.string(bundle)
        }
    }

    private func bar(_ config: ShellConfig, height: Double, vertical: Bool) -> ShellBarData {
        var bar = ShellBarData()
        let settings = config.barOverride?.settings
        bar.style.height = height
        bar.style.vertical = vertical
        bar.style.transparent = settings?.transparentBackground ?? false
        bar.style.backgrounds = settings?.showItemBackgrounds ?? true
        bar.style.solidBlack = settings?.solidBlackBackground ?? false
        return bar
    }
}
