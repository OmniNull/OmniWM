// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private enum MarqueeFixture {
    static let glyphWidth: Float = 10
    static let lineHeight: Float = 12
}

@MainActor
final class ShellMarqueeCoreTests: XCTestCase {
    private var glyphWidth: Float {
        MarqueeFixture.glyphWidth
    }

    private let viewportCap: Float = 25
    private let iconSize: Float = 18
    private let gap: Float = 5
    private let viewportKey: UInt64 = 3
    private let textKey: UInt64 = 4

    private func tree(text: UInt32, marquee: Bool = true) -> [TreeNode] {
        [
            TreeNode(kind: .group, subtreeEnd: 4, key: 1, layout: LayoutStyle(axis: .row, gap: gap)),
            TreeNode(kind: .box, subtreeEnd: 2, key: 2, layout: LayoutStyle(width: iconSize, height: iconSize)),
            TreeNode(
                kind: .group, subtreeEnd: 4, key: viewportKey, layout: LayoutStyle(axis: .row),
                content: Content(maxWidth: viewportCap, scrolls: true, marquee: marquee)
            ),
            TreeNode(kind: .label, subtreeEnd: 4, key: textKey, content: Content(text: text))
        ]
    }

    private func apply(_ tree: [TreeNode], to core: inout SurfaceCore, patches: inout PatchBuffer) {
        patches.removeAll()
        let measure: MeasureText = { _, text, _, _, _, width, height in
            width.pointee = Float(text) * MarqueeFixture.glyphWidth
            height.pointee = MarqueeFixture.lineHeight
        }
        tree.withUnsafeBufferPointer { core.apply($0, measure: measure, context: nil, into: &patches) }
    }

    func testMarqueeCapsOnlyItsViewportAndKeepsNaturalDemandWhenLimited() throws {
        for text: UInt32 in [1, 4] {
            var core = SurfaceCore(capacity: 4)
            var patches = PatchBuffer(capacity: 16)
            apply(tree(text: text), to: &core, patches: &patches)
            let viewport = try XCTUnwrap(core.firstHandle(withKey: viewportKey))
            let label = try XCTUnwrap(core.firstHandle(withKey: textKey))
            let textWidth = Float(text) * glyphWidth
            let preferred = min(viewportCap, textWidth)
            let naturalWidth = iconSize + gap + preferred
            XCTAssertEqual(core.rootSize, Size2(width: naturalWidth, height: iconSize))
            XCTAssertEqual(core.layoutFrame(of: viewport).width, preferred)
            XCTAssertEqual(core.layoutFrame(of: label).width, textWidth)
            XCTAssertEqual(core.content(of: label).maxWidth, 0)

            let reduced = preferred / 2
            core.setRootLimit(Size2(width: iconSize + gap + reduced, height: iconSize), into: &patches)
            XCTAssertEqual(core.rootSize, Size2(width: naturalWidth, height: iconSize))
            XCTAssertEqual(core.rootFrame.width, iconSize + gap + reduced)
            XCTAssertEqual(core.layoutFrame(of: viewport).width, reduced)
            XCTAssertEqual(core.layoutFrame(of: label).width, textWidth)
            let icon = try XCTUnwrap(core.firstHandle(withKey: 2))
            XCTAssertEqual(core.layoutFrame(of: icon).width, iconSize)

            core.setRootLimit(Size2(width: .infinity, height: .infinity), into: &patches)
            XCTAssertEqual(core.rootFrame.width, naturalWidth)
            XCTAssertEqual(core.layoutFrame(of: viewport).width, preferred)
        }
    }

    func testMarqueeFlagChangesInvalidateMeasurementAndPublishPaint() throws {
        let text: UInt32 = 4
        var core = SurfaceCore(capacity: 4)
        var patches = PatchBuffer(capacity: 16)
        apply(tree(text: text), to: &core, patches: &patches)
        let viewport = try XCTUnwrap(core.firstHandle(withKey: viewportKey))
        func hasPaint() -> Bool {
            for index in 0 ..< patches.count {
                if case let .setPaint(handle, _) = patches.op(at: index), handle == viewport { return true }
            }
            return false
        }
        XCTAssertTrue(hasPaint())
        apply(tree(text: text, marquee: false), to: &core, patches: &patches)
        XCTAssertTrue(hasPaint())
        XCTAssertFalse(core.content(of: viewport).marquee)
        XCTAssertEqual(core.rootFrame.width, iconSize + gap + Float(text) * glyphWidth)
    }

    func testMarqueeWireUsesTheViewportCapAndAnUncappedPassiveLabel() throws {
        let cap = 30
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.row{scroll=true, marquee=true, maxWidth=\(cap), ui.text{text='A long title'}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let strings = ShellTextStore()
        strings.ingest(wire: script.output)
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(script.output, text: strings))
        let root = layout.core.rootHandle
        XCTAssertTrue(layout.core.content(of: root).marquee)
        XCTAssertTrue(layout.core.content(of: root).scrolls)
        XCTAssertEqual(layout.core.content(of: root).maxWidth, Float(cap))
        let label = layout.core.firstDescendant(of: root) { $0.text != 0 }
        XCTAssertNotEqual(label, .none)
        XCTAssertEqual(layout.core.content(of: label).maxWidth, 0)
        XCTAssertTrue(layout.core.content(of: label).decorative)
    }

    func testDefaultTitleKeepsTheWholeTextInsideItsConfiguredViewport() throws {
        let cap: CGFloat = 40
        let title = String(repeating: "window title ", count: 8)
        let widget = try ShellRenderedWidget("active-window")
        widget.set("app") { $0.string("Example") }
        widget.set("bundle") { $0.string("com.example.title") }
        widget.set("title") { $0.string(title) }
        widget.set("settings") { writer in
            writer.map(1)
            writer.key("maxWidth")
            writer.number(Double(cap))
        }
        widget.render(ShellBarData())
        func inspect(_ core: borrowing SurfaceCore) throws {
            let viewport = try XCTUnwrap(core.elements { $0.marquee }.first)
            let label = core.firstDescendant(of: viewport) { $0.text != 0 }
            XCTAssertNotEqual(label, .none)
            XCTAssertEqual(core.layoutFrame(of: viewport).width, Float(cap))
            XCTAssertGreaterThan(core.layoutFrame(of: label).width, Float(cap))
            XCTAssertEqual(core.content(of: label).maxWidth, 0)
            XCTAssertEqual(widget.text.string(core.content(of: label).text), title)
        }
        try inspect(widget.surface.layout.core)
    }

    func testActiveWindowStyleOverrideKeepsItsOwnPlainClippingContent() throws {
        let source = try ShellRenderedWidget.bundledSource("active-window")
        let override = """
        return {activeWindowBar = function(ctx, m)
            return ui.row{ui.text{text=m.title,maxWidth=m.maxWidth}}
        end}
        """
        let modules = source.modules.map { module in
            module.path.hasSuffix("lib/look.luau")
                ? ShellWidgetSource.Module(path: module.path, source: override) : module
        }
        let widget = try ShellRenderedWidget(
            name: "active-window", source: source.main, modules: modules, chunk: source.chunk
        )
        let cap = 40
        widget.set("settings") { writer in
            writer.map(1)
            writer.key("maxWidth")
            writer.number(Double(cap))
        }
        widget.set("app") { $0.string("Example") }
        widget.set("title") { $0.string(String(repeating: "long title ", count: 8)) }
        widget.render(ShellBarData())
        XCTAssertFalse(widget.surface.hasMarquee)
        let label = widget.surface.layout.core
            .firstDescendant(of: widget.surface.layout.core.rootHandle) { $0.text != 0 }
        XCTAssertNotEqual(label, .none)
        XCTAssertEqual(widget.surface.layout.core.content(of: label).maxWidth, Float(cap))
    }

    func testMarqueeRejectsNonPassiveOrNonTextContent() throws {
        for source in [
            "ui.row{marquee=true,ui.text{text='x'}}",
            "ui.column{scroll=true,marquee=true,ui.text{text='x'}}",
            "ui.row{scroll=true,marquee=true,ui.box{w=10,h=10}}",
            "ui.row{scroll=true,marquee=true,ui.text{text='x'},ui.text{text='y'}}",
            "ui.row{scroll=true,marquee=true,ui.text{text='x',onClick='noop'}}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return \(source) end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, source)
            XCTAssertFalse(script.message.isEmpty)
        }
    }
}
