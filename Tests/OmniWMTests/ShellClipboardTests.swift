// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellClipboardTests: XCTestCase {
    func testNamedPasteboardCopiesTextURLAndImageByValueWithoutTouchingGeneralClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ShellClipboard.copy(.text("editable note"), to: pasteboard))
        let text = try ShellClipboard.read(from: pasteboard)
        XCTAssertEqual(text.count, 1)
        XCTAssertEqual(text.first?.kind, "text")
        guard case let .text(value) = text.first?.source else { return XCTFail("missing text") }
        XCTAssertEqual(value, "editable note")
        let url = try XCTUnwrap(URL(string: "https://example.org/widget"))
        XCTAssertTrue(ShellClipboard.copy(.url(url), to: pasteboard))
        XCTAssertEqual(try ShellClipboard.read(from: pasteboard).first?.kind, "url")
        let bytes = Data([1, 2, 3])
        XCTAssertTrue(ShellClipboard.copy(.data(bytes, uti: "public.png"), to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), bytes)
        XCTAssertEqual(try ShellClipboard.read(from: pasteboard).first?.kind, "image")
        XCTAssertFalse(ShellClipboard.copy(.url(URL(fileURLWithPath: "/tmp/not-an-issued-resource")), to: pasteboard))
        XCTAssertFalse(ShellClipboard.copy(
            .data(Data(repeating: 0, count: (16 << 20) + 1), uti: "public.data"),
            to: pasteboard
        ))
        XCTAssertEqual(pasteboard.data(forType: .png), bytes)
        pasteboard.clearContents()
        XCTAssertTrue(try ShellClipboard.read(from: pasteboard).isEmpty)
    }

    func testResourceCopyRemainsUsableAfterOwnerRetirement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = ShellResourceStore(directory: directory)
        let owner = ShellServiceOwner(generation: 1, owner: 3, epoch: 1)
        try await resources.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "test", package: "clipboard", instance: "copy")
        )
        let item = ShellResourceDescriptor(id: ShellResourceID(), name: "Image.png", kind: "image", uti: "public.png")
        try resources.catalog.admit([item], owner: owner)
        try await resources.materialize([.bytes(Data([7, 8, 9]))], ids: [item.id], owner: owner)
        let value = try await resources.clipboardContent(item.id, owner: owner, operation: ShellResourceOperation())
        _ = await resources.retire(owner)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ShellClipboard.copy(value, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), Data([7, 8, 9]))
    }

    func testClipboardAndFileCapabilitiesAreIndependent() async throws {
        for files in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let package = ShellWidgetPackage(
                name: "clipboard",
                generation: 1,
                outbox: ShellWidgetOutbox { _ in },
                resourceStore: ShellResourceStore(directory: root)
            )
            let descriptor = ShellComponentDescriptor(
                widget: "child",
                title: "Child",
                icon: "",
                views: ["compact"],
                uses: [],
                options: [:],
                capabilities: ShellComponentCapabilities(files: files, clipboard: true),
                providerCommand: nil,
                folder: root.appendingPathComponent("child")
            )
            let source = ShellWidgetSource(
                chunk: "@look/widgets/clipboard/init.luau",
                main: "function render(ctx) return ui.component{id='child'} end",
                modules: [.init(
                    path: "look/widgets/child/component.luau",
                    source: "return {views={compact=function(ctx) return ui.box{w=30,h=20} end}}"
                )],
                moduleLimit: 512,
                components: [ShellComponentInstance(id: "child", widget: "child")],
                componentDescriptors: [descriptor]
            )
            let failure = await package.load(source)
            XCTAssertNil(failure)
            await package.receive(.bars([ShellBarKey(monitor: .init(displayId: 99501)): ShellBarData()]))
            let capabilities = await package.clipboardCapabilitiesForTest()
            XCTAssertEqual(capabilities?.0, true)
            XCTAssertEqual(capabilities?.1, files)
            await package.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private extension ShellWidgetPackage {
    func clipboardCapabilitiesForTest() -> (Bool, Bool)? {
        guard let script else { return nil }
        var owner = omni_owner_token()
        guard omni_vm_component_owner(script.vm, "child", 5, &owner) else { return nil }
        let token = ShellServiceOwner(owner)
        return (permitsClipboard(token, component: "child"), permitsFiles(token, component: "child"))
    }
}
