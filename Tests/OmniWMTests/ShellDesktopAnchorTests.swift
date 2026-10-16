// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellDesktopAnchorTests: XCTestCase {
    func testStructuralPathSelectsOneSiblingAndLaterPublicationInvalidatesGeometry() throws {
        let widget = try ShellRenderedWidget(name: "anchor", source: """
        function render()
            return ui.row{key='root',w=100,h=30,
                ui.box{key='a',w=40,h=30,ui.text{key='same',text='a',w=20,h=20}},
                ui.box{key='b',w=40,h=30,ui.text{key='same',text='b',w=20,h=20}}}
        end
        """)
        widget.surface.view.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        widget.render(ShellBarData())
        let labels = widget.surface.layout.core.elements { $0.text != 0 }
            .sorted {
                widget.surface.layout.core.absoluteFrame(of: $0).x < widget.surface.layout.core.absoluteFrame(of: $1).x
            }
        XCTAssertEqual(labels.count, 2)
        let root = widget.surface.layout.core.rootHandle
        let parent = widget.surface.layout.core.parent(of: labels[1])
        let path: [ElementPathStep] = [
            .init(
                kind: widget.surface.layout.core.kind(of: root),
                key: widget.surface.layout.core.key(of: root),
                child: 0
            ),
            .init(
                kind: widget.surface.layout.core.kind(of: parent),
                key: widget.surface.layout.core.key(of: parent),
                child: 1
            ),
            .init(
                kind: widget.surface.layout.core.kind(of: labels[1]),
                key: widget.surface.layout.core.key(of: labels[1]),
                child: 0
            )
        ]
        XCTAssertEqual(widget.surface.layout.core.resolve(path: path), labels[1])
        let anchor = try XCTUnwrap(widget.surface.desktopAnchor(ShellDesktopAnchorResolution(sequence: 0, path: path)))
        XCTAssertTrue(anchor.isCurrent())
        widget.surface.sequence = 1
        XCTAssertFalse(anchor.isCurrent())
        XCTAssertNil(widget.surface.desktopAnchor(ShellDesktopAnchorResolution(sequence: 0, path: path)))
        var wrong = path
        wrong[1].key = widget.surface.layout.core.key(of: widget.surface.layout.core.parent(of: labels[0]))
        XCTAssertEqual(widget.surface.layout.core.resolve(path: wrong), .none)
    }

    func testRequestDecoderKeepsOpaqueLocatorAndRejectsMalformedListsAndIndices() throws {
        let id = ShellServiceID(owner: ShellServiceOwner(generation: 1, owner: 0, epoch: 1), request: 1)
        let resource = ShellResourceID()
        let bytes = withUnsafeBytes(of: resource.value.uuid) { Array($0) }
        let locator = omni_desktop_anchor(epoch: 2, unit: 7, key: 123)
        let opaque = withUnsafeBytes(of: locator) { Array($0) }
        func request(_ fields: [String: ShellServiceValue]) throws -> ShellDesktopRequest {
            var writer = ShellValueWriter()
            ShellServiceValue.object(fields).write(to: &writer)
            return try ShellDesktopRequest(id: id, bytes: writer.bytes)
        }
        let sharing = try request([
            "op": .text("share"),
            "resources": .array([.bytes(bytes)]),
            "anchor": .bytes(opaque)
        ])
        XCTAssertEqual(sharing.anchor?.unit, 7)
        guard case let .share(resources, service) = sharing.action else { return XCTFail("wrong share payload") }
        XCTAssertEqual(resources, [resource])
        XCTAssertNil(service)
        XCTAssertThrowsError(try request([
            "op": .text("share"),
            "resources": .array([.bytes(bytes), .bytes(bytes)]),
            "anchor": .bytes(opaque)
        ]))
        XCTAssertThrowsError(try request([
            "op": .text("share"),
            "resources": .array([.bytes(bytes)]),
            "anchor": .text("forged")
        ]))
        XCTAssertThrowsError(try request([
            "op": .text("quicklook"),
            "resources": .array([.bytes(bytes)]),
            "index": .number(1.5)
        ]))
    }
}
