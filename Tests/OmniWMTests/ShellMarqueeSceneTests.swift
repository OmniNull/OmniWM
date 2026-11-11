// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import SwiftUI
import XCTest

@MainActor
final class ShellMarqueeSceneTests: XCTestCase {
    private let cap: CGFloat = 40
    private let icon: CGFloat = 18
    private let gap: CGFloat = 5
    private let textOpacity: Float = 0.5
    private let title = String(repeating: "Long window title ", count: 8)

    private func widget(marquee: Bool = true) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(name: "marquee-scene", source: """
        function render(ctx)
            if ctx.data.removed then return ui.box{w=0,h=0} end
            return ui.row{gap=\(Int(gap)), target='window ow_title', preview=true, onClick='focus left',
                ui.box{key='icon',w=\(Int(icon)),h=\(Int(icon))},
                ui.row{key='ticker',scroll=true,marquee=ctx.data.marquee ~= false,maxWidth=\(Int(cap)),
                    ui.text{text=ctx.data.title,size=13,opacity=\(textOpacity)}}}
        end
        """, resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)))
        widget.set("title") { $0.string(title) }
        widget.set("marquee") { $0.bool(marquee) }
        widget.render(ShellBarData())
        return widget
    }

    private func handles(_ widget: ShellRenderedWidget) throws -> (viewport: ElementHandle, label: ElementHandle) {
        let viewport = try XCTUnwrap(widget.surface.layout.handle(forKey: "ticker"))
        let label = widget.surface.layout.core.firstDescendant(of: viewport) { $0.text != 0 }
        XCTAssertNotEqual(label, .none)
        return (viewport, label)
    }

    private func assertLinear(_ timing: CAMediaTimingFunction?) throws {
        let timing = try XCTUnwrap(timing)
        let linear = CAMediaTimingFunction(name: .linear)
        for index in 1 ... 2 {
            var actual = [Float](repeating: 0, count: 2)
            var expected = actual
            timing.getControlPoint(at: index, values: &actual)
            linear.getControlPoint(at: index, values: &expected)
            XCTAssertEqual(actual, expected)
        }
    }

    func testTickerUsesTheFullTextAndOnlyDuplicatesItsRendering() throws {
        let widget = try widget()
        let handles = try handles(widget)
        let full = widget.surface.layout.core.layoutFrame(of: handles.label)
        let distance = CGFloat(full.width + full.height)
        XCTAssertEqual(widget.surface.naturalSize.width, icon + gap + cap)
        XCTAssertGreaterThan(CGFloat(full.width), cap)
        XCTAssertEqual(widget.surface.layout.core.content(of: handles.label).maxWidth, 0)
        XCTAssertEqual(widget.text.string(widget.surface.layout.core.content(of: handles.label).text), title)

        try ShellLayerScene.engineQueue.sync {
            let scene = widget.surface.scene
            XCTAssertNotNil(scene.marquees[handles.viewport.slot])
            let ticker = try XCTUnwrap(scene.marquees[handles.viewport.slot])
            let layer = try XCTUnwrap(scene.layers[handles.label.slot])
            let viewport = try XCTUnwrap(scene.layers[handles.viewport.slot])
            let animation = try XCTUnwrap(layer.animation(forKey: ShellMarquee.animationKey) as? CABasicAnimation)
            XCTAssertEqual(ticker.distance, distance)
            XCTAssertEqual(animation.keyPath, "transform.translation.x")
            XCTAssertEqual(animation.toValue as? CGFloat, -distance)
            XCTAssertEqual(animation.duration, distance / ShellMarquee.pointsPerSecond)
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertFalse(animation.isRemovedOnCompletion)
            try assertLinear(animation.timingFunction)
            XCTAssertTrue(ticker.copy.superlayer === layer)
            XCTAssertEqual(layer.opacity, textOpacity)
            XCTAssertEqual(viewport.sublayers?.count, 1)
            XCTAssertEqual(layer.sublayers?.count, 1)
            XCTAssertNil(ticker.copy.animationKeys())
            XCTAssertTrue((ticker.copy.contents as AnyObject?) === (layer.contents as AnyObject?))
            XCTAssertEqual(ticker.copy.position.x, distance)
        }
        let originalCopy = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(widget.surface.scene.marquees[handles.viewport.slot]).copy
        }
        widget.render(ShellBarData())
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.marquees[handles.viewport.slot]?.copy === originalCopy)
        }
    }

    func testReplacementFittingAndRemovalUpdateTheNativeTicker() throws {
        let widget = try widget()
        let handles = try handles(widget)
        let original = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(widget.surface.scene.layers[handles.label.slot])
        }
        let originalCopy = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(widget.surface.scene.marquees[handles.viewport.slot]).copy
        }
        let replacement = String(repeating: "Different title ", count: 10)
        widget.set("title") { $0.string(replacement) }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.text.string(widget.surface.layout.core.content(of: handles.label).text), replacement)
        try ShellLayerScene.engineQueue.sync {
            let ticker = try XCTUnwrap(widget.surface.scene.marquees[handles.viewport.slot])
            let label = try XCTUnwrap(widget.surface.scene.layers[handles.label.slot])
            XCTAssertTrue((ticker.copy.contents as AnyObject?) === (label.contents as AnyObject?))
            XCTAssertNotNil(label.animation(forKey: ShellMarquee.animationKey))
            XCTAssertFalse(ticker.copy === originalCopy)
            XCTAssertNil(originalCopy.superlayer)
            XCTAssertNil(originalCopy.animation(forKey: ShellMarquee.animationKey))
            XCTAssertEqual(ticker.distance, label.bounds.width + label.bounds.height)
        }

        widget.set("title") { $0.string("x") }
        widget.render(ShellBarData())
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.marquees.isEmpty)
            XCTAssertNil(original.animation(forKey: ShellMarquee.animationKey))
        }

        widget.set("title") { $0.string(title) }
        widget.render(ShellBarData())
        ShellLayerScene.engineQueue.sync {
            XCTAssertFalse(widget.surface.scene.marquees.isEmpty)
        }
        widget.set("removed") { $0.bool(true) }
        widget.render(ShellBarData())
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.marqueeSlots.isEmpty)
            XCTAssertTrue(widget.surface.scene.marquees.isEmpty)
            XCTAssertNil(original.animation(forKey: ShellMarquee.animationKey))
        }
    }

    private func place(
        _ widget: ShellRenderedWidget,
        lane: ShellLane,
        width: CGFloat
    ) -> NSHostingView<some View> {
        let natural = widget.surface.naturalSize
        let slot = ShellWidgetSlot(
            widget: WorkspaceBarShellWidget(id: "ticker", size: natural, lane: lane),
            view: widget.surface.view,
            cuttable: true
        )
        let host = NSHostingView(rootView: slot.frame(width: width, height: natural.height))
        host.frame = CGRect(x: 0, y: 0, width: natural.width * 2, height: natural.height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testStartKeepingSlotsLimitMarqueeReflowAndClearItWhenTheyFit() throws {
        let width = icon + gap + cap / 2
        for lane in [ShellLane.leading, .center] {
            let widget = try widget()
            let natural = CGSize(width: icon + gap + cap, height: icon)
            let cut = place(widget, lane: lane, width: width)
            XCTAssertEqual(widget.surface.size.width, width)
            XCTAssertEqual(widget.surface.naturalSize.width, natural.width)
            let iconHandle = try XCTUnwrap(widget.surface.layout.handle(forKey: "icon"))
            XCTAssertEqual(CGFloat(widget.surface.layout.core.layoutFrame(of: iconHandle).width), icon)
            let whole = place(widget, lane: lane, width: natural.width)
            XCTAssertEqual(widget.surface.size.width, natural.width)
            XCTAssertEqual(widget.surface.layout.core.rootLimit.width, .infinity)
            withExtendedLifetime((cut, whole)) {}
        }
    }

    func testTrailingAndNonMarqueeSlotsKeepThePlainClippingPath() throws {
        let trailing = try widget()
        let shown = icon + gap + cap / 2
        let end = place(trailing, lane: .trailing, width: shown)
        XCTAssertEqual(trailing.surface.layout.core.rootLimit.width, .infinity)
        XCTAssertEqual(trailing.surface.size.width, icon + gap + cap)

        let ordinary = try widget(marquee: false)
        let handles = try handles(ordinary)
        let before = ordinary.surface.layout.core.layoutFrame(of: handles.viewport)
        let start = place(ordinary, lane: .leading, width: shown)
        XCTAssertFalse(ordinary.surface.hasMarquee)
        XCTAssertEqual(ordinary.surface.layout.core.rootLimit.width, .infinity)
        XCTAssertEqual(ordinary.surface.layout.core.layoutFrame(of: handles.viewport), before)
        withExtendedLifetime((end, start)) {}
    }

    func testFlagChangesRecomputeTheLimitUnderAnUnchangedCutSlot() throws {
        let widget = try widget()
        widget.set("title") { $0.string("xx") }
        widget.render(ShellBarData())
        let natural = widget.surface.naturalSize
        let shown = icon + gap + (natural.width - icon - gap) / 2
        let host = place(widget, lane: .leading, width: shown)
        XCTAssertEqual(widget.surface.size.width, shown)

        widget.set("marquee") { $0.bool(false) }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.surface.naturalSize, natural)
        XCTAssertEqual(widget.surface.layout.core.rootLimit.width, .infinity)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(widget.surface.scene.marqueeSlots.isEmpty)
        }

        widget.set("marquee") { $0.bool(true) }
        widget.render(ShellBarData())
        XCTAssertEqual(widget.surface.naturalSize, natural)
        XCTAssertEqual(widget.surface.size.width, shown)
        withExtendedLifetime(host) {}
    }

    func testBothInstanceBranchesReportNaturalDemandWhileTheirLayoutsAreLimited() throws {
        let widget = try widget()
        let limited = CGSize(width: icon + gap + cap / 2, height: icon)
        let natural = CGSize(width: icon + gap + cap, height: icon)
        let tree = ShellWidgetDelivery.Tree(nodes: widget.output(), sequence: 1)
        let mounted = ShellWidgetHost.InstanceState()
        widget.surface.setRootLimit(limited)
        mounted.surface = widget.surface
        XCTAssertTrue(mounted.apply(tree, text: widget.text))
        XCTAssertEqual(mounted.size.width, natural.width)
        XCTAssertEqual(widget.surface.size.width, limited.width)

        let unmounted = ShellWidgetHost.InstanceState()
        XCTAssertTrue(unmounted.apply(tree, text: widget.text))
        unmounted.unmountedLayout?.setRootLimit(Size2(width: Float(limited.width), height: Float(limited.height)))
        XCTAssertFalse(unmounted.apply(tree, text: widget.text))
        XCTAssertEqual(unmounted.size.width, natural.width)
        XCTAssertEqual(unmounted.unmountedLayout?.size.width, limited.width)
    }

    func testRootLimitRefreshesThePreviewAnchorUnderAStillPointer() throws {
        let widget = try widget()
        var previews: [ShellPreviewEvent] = []
        widget.surface.onPreview = { event in
            previews.append(event)
        }
        widget.surface.hover(at: CGPoint(x: icon / 2, y: icon / 2))
        XCTAssertEqual(previews.last?.anchor?.frame.width, icon + gap + cap)
        let shown = icon + gap + cap / 2
        widget.surface.setRootLimit(CGSize(width: shown, height: icon))
        XCTAssertEqual(previews.last?.anchor?.frame.width, shown)
    }
}
