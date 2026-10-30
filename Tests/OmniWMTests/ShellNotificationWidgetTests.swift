// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellNotificationWidgetTests: XCTestCase {
    private func write(_ value: Any, into writer: inout ShellValueWriter) {
        switch value {
        case let value as String: writer.string(value)
        case let value as Bool: writer.bool(value)
        case let value as Int: writer.number(Double(value))
        case let value as Double: writer.number(value)
        case let value as Data: writer.string(bytes: value)
        case let value as [Any]:
            writer.array(value.count)
            for item in value { write(item, into: &writer) }
        case let value as [String: Any]:
            writer.map(value.count)
            for key in value.keys.sorted() {
                writer.key(key)
                if let item = value[key] { write(item, into: &writer) }
            }
        default: writer.null()
        }
    }

    private func set(
        _ widget: ShellRenderedWidget,
        state: String,
        items: [[String: Any]] = [],
        complete: Bool = true,
        action: [String: Any]? = nil,
        dismissAll: [String: Any]? = nil,
        dispatched: [String] = [],
        kept: Int = 0
    ) {
        widget.set("notifications") {
            var value: [String: Any] = [
                "state": state, "complete": complete, "items": items, "dispatched": dispatched, "kept": kept,
                "apps": [["bundle": "com.example.fixture", "name": "Fixture App"]]
            ]
            if let action { value["action"] = action }
            if let dismissAll { value["dismissAll"] = dismissAll }
            write(value, into: &$0)
        }
    }

    private func item(_ id: String = "fixture", body: String = "Fixture body") -> [String: Any] {
        let binary = Data("DO-NOT-DISPLAY-BINARY".utf8)
        return [
            "id": id, "bundle": "com.example.fixture", "title": "Fixture title ✓", "subtitle": "Fixture subtitle",
            "body": body, "date": 1_000_000.0, "requestId": "request-1", "thread": "conversation-1",
            "category": "message", "attachments": [[
                "id": "image-1",
                "type": "public.png",
                "available": false,
                "path": "/fixture/retained.png"
            ]],
            "actions": [[
                "id": "reply",
                "title": "Reply ✓",
                "options": 0,
                "textInputButtonTitle": "Send reply",
                "textInputPlaceholder": "Write a reply"
            ]],
            "userInfo": ["nested": ["value": "preserved", "type": "data", "title": "Ordinary data title"]],
            "communication": [
                "sender": ["displayName": "Fixture Sender"],
                "displayName": "Fixture Conversation",
                "identifier": "conversation-1",
                "recipients": [["displayName": "Fixture Recipient"]]
            ],
            "metadata": [
                "blob": ["type": "data", "byteLength": binary.count, "bytes": binary],
                "unknownBinary": Data([0xFF, 0, 0x80])
            ]
        ]
    }

    func testFailuresRemainDistinctFromAnEmptyRetainedList() throws {
        let widget = try ShellRenderedWidget("notifications")
        for state in ["accessDenied", "unavailable", "queryError", "malformed", "incomplete"] {
            set(widget, state: state, complete: state != "incomplete")
            let tree = widget.renderPopout()
            XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
                "No retained notifications",
                []
            )))
            XCTAssertTrue(tree.map { widget.text.string($0.content.action) }.contains("notifications settings"))
        }
        set(widget, state: "empty")
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("No retained notifications", [])))
    }

    func testCardsKeepReadableCommunicationAndHideRawMetadata() throws {
        let widget = try ShellRenderedWidget("notifications")
        set(widget, state: "ready", items: [item()])
        widget.layoutPopout()
        let strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(strings.contains("Fixture Sender"))
        XCTAssertTrue(strings.contains("Fixture Conversation"))
        XCTAssertFalse(strings.contains(ShellLocalizer.string("Attachment", [])))
        for hidden in [
            "Fixture Recipient", "/fixture/retained.png", "public.png", "conversation-1", "request-1",
            "DO-NOT-DISPLAY-BINARY", "Ordinary data title", "Details", "Refresh"
        ] {
            XCTAssertFalse(strings.contains { $0.contains(hidden) }, hidden)
        }
        var retained = item()
        retained["communication"] = [
            "sender": ["displayName": "Fixture title ✓"],
            "conversation": ["displayName": "Fixture subtitle"],
            "identifier": "DO-NOT-DISPLAY-ID"
        ]
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).filter { $0 == "Fixture title ✓" }.count, 1)
        XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).filter { $0 == "Fixture subtitle" }.count, 1)
        retained["communication"] = ["sender": ["identifier": "RAW-SENDER"], "conversationIdentifier": "RAW-GROUP"]
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains { $0.contains("RAW-") })
        retained["communication"] = [
            "sender": ["displayName": "", "name": 42, "handle": "sender@example.com"],
            "displayName": "Project group"
        ]
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("sender@example.com"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Project group"))
    }

    func testAttachmentsWithoutReadyHostImageResourcesKeepReadableIndicators() throws {
        let widget = try ShellRenderedWidget("notifications")
        var retained = item()
        retained["attachments"] = [
            ["available": true, "image": "/fixture/private.png", "path": "/fixture/private.png", "type": "public.png"],
            ["available": true, "image": ["id": "fake", "kind": "image", "state": "ready"]],
            ["available": false]
        ]
        set(widget, state: "ready", items: [retained])
        let tree = widget.renderPopout()
        XCTAssertEqual(tree.filter { $0.kind == .image }.count, 1)
        XCTAssertFalse(tree.contains { $0.kind == .bitmap })
        let strings = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertEqual(strings.filter { $0 == ShellLocalizer.string("Attachment", []) }.count, 1)
        XCTAssertFalse(strings.contains("Attachment unavailable"))
        retained["attachments"] = [["available": false], ["available": false]]
        set(widget, state: "ready", items: [retained])
        _ = widget.renderPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Attachment", [])))
        XCTAssertFalse(strings.contains { $0.contains("/fixture/") || $0.contains("public.png") })
    }

    func testShortWideGlyphBodyKeepsAllWrappedLinesReachable() throws {
        let widget = try ShellRenderedWidget("notifications")
        let body = String(repeating: "W", count: 150)
        set(widget, state: "ready", items: [item(body: body)])
        let tree = widget.renderPopout()
        let text = try XCTUnwrap(tree.first { widget.text.string($0.content.text) == body })
        XCTAssertEqual(text.content.lines, 255)
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Show More", [])))
        widget.layoutPopout()
        let handle = try XCTUnwrap(widget.surface.layout.core.elements { widget.text.string($0.text) == body }.first)
        let frame = try reveal(handle, in: widget)
        XCTAssertGreaterThan(frame.height, 3 * 13)
    }

    func testShowMoreUsesCodePointsAndExceedsThreeExplicitLines() throws {
        let widget = try ShellRenderedWidget("notifications")
        for body in ["On my way\nSee you soon", "One\nTwo\nThree", String(repeating: "界", count: 61)] {
            set(widget, state: "ready", items: [item(body: body)])
            let tree = widget.renderPopout()
            let text = try XCTUnwrap(tree.first { widget.text.string($0.content.text) == body })
            XCTAssertEqual(text.content.lines, 255, body)
            XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Show More", [])), body)
        }
        set(widget, state: "ready", items: [item(body: "One\nTwo\nThree\nFour")])
        widget.layoutPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Show More", [])))
        XCTAssertEqual(try click(ShellLocalizer.string("Show More", []), in: widget), [])
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("One\nTwo\nThree\nFour"))
        var invalid = item()
        invalid["id"] = "invalid-body"
        invalid["body"] = Data([0xFF, 0xFE])
        set(widget, state: "ready", items: [invalid])
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Data (2 bytes)"))
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Show More", [])))
    }

    func testComposerPaddingGapUnusedWidthAndErrorClicksStayInsideReply() throws {
        let widget = try ShellRenderedWidget("notifications")
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        set(widget, state: "ready", items: [item(id)])
        widget.layoutPopout()
        XCTAssertEqual(try click(ShellLocalizer.string("Reply", []), in: widget), [])
        let draft = "Keep this reply"
        let input = try edit(draft, in: widget)
        let composer = widget.surface.layout.core.parent(of: input.handle)
        let composerFrame = try reveal(composer, in: widget)
        let inputFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: input.handle))
        let cancelLabel = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.text) == ShellLocalizer.string("Cancel", [])
        }.first)
        let cancelFrame = CGRect(widget.surface.layout.core.absoluteFrame(of: cancelLabel))
        for point in [
            CGPoint(x: composerFrame.minX + 2, y: composerFrame.midY),
            CGPoint(x: inputFrame.midX, y: inputFrame.maxY + 3),
            CGPoint(x: composerFrame.maxX - 8, y: cancelFrame.midY)
        ] {
            XCTAssertTrue(composerFrame.contains(point))
            XCTAssertFalse(inputFrame.contains(point))
            XCTAssertEqual(try deliver(at: point, in: widget), [])
            XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, draft)
        }
        try edit(" \t", in: widget)
        XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [])
        XCTAssertEqual(try click(ShellLocalizer.string("Reply cannot be empty.", []), in: widget), [])
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, " \t")
    }

    func testRelativeAgeAndBatchCountsAreFormattedAndCancellationHasOneMessage() throws {
        let widget = try ShellRenderedWidget("notifications")
        widget.set("seconds") { $0.number(1_000_300) }
        for (state, failed, outcome, expected) in [
            ("pending", 0, "dispatched", "Clearing notifications: 1 of 1"),
            ("partial", 1, "dispatched", "Clear All finished. Failed: 1"),
            ("completed", 0, "dispatched", "Dismissal requested: 1"),
            ("cancelled", 0, "cancelled", "Clear All cancelled. Processed 1 of 1; 0 failed.")
        ] {
            set(widget, state: "ready", items: [item()], dismissAll: [
                "active": state == "pending", "total": 1, "completed": 1, "failed": failed,
                "state": state, "outcome": outcome
            ])
            _ = widget.renderPopout()
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            XCTAssertTrue(strings.contains("5 min ago"), state)
            XCTAssertTrue(strings.contains(expected), state)
            XCTAssertFalse(strings.contains { $0.contains("%lld") }, state)
            if state == "cancelled" {
                XCTAssertEqual(strings.filter { $0.contains("cancelled") }.count, 1)
                XCTAssertFalse(strings.contains(ShellLocalizer.string("Notification action cancelled.", [])))
            }
        }
    }

    func testShowMoreAndTextPagingReachEveryUnicodeBodyCharacter() throws {
        let widget = try ShellRenderedWidget("notifications")
        let body = String(repeating: "Body ✓ 中文 العربية 👩🏽‍💻 e\u{301}\n", count: 1000) + "END-fixture"
        set(widget, state: "ready", items: [item(body: body)])
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains { $0.contains("END-fixture") })
        XCTAssertEqual(try click(ShellLocalizer.string("Show More", []), in: widget), [])
        var observed = ""
        repeat {
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            observed += strings.filter { $0.contains("Body ✓") || $0.contains("END-fixture") }.joined()
            XCTAssertLessThan(widget.renderPopout().count, 256)
            if observed.contains("END-fixture") { break }
            XCTAssertEqual(try click(ShellLocalizer.string("Next Text", []), in: widget), [])
        } while observed.utf8.count <= body.utf8.count
        XCTAssertEqual(observed, body)
        XCTAssertEqual(try click(ShellLocalizer.string("Show Less", []), in: widget), [])
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains { $0.contains("END-fixture") })
    }

    func testCardBackgroundOpensAppAndNestedControlsConsumeTheClick() throws {
        let widget = try ShellRenderedWidget("notifications")
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let retained = item(id, body: String(repeating: "Long notification body. ", count: 20))
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertEqual(try click("Fixture title ✓", in: widget), ["notifications open com.example.fixture"])
        XCTAssertEqual(try click(ShellLocalizer.string("Show More", []), in: widget), [])
        XCTAssertEqual(try click("×", in: widget), ["notifications dismiss com.example.fixture \(id)"])
        XCTAssertEqual(try click(ShellLocalizer.string("Reply", []), in: widget), [])
        let input = try XCTUnwrap(widget.surface.textInputs.values.first)
        let frame = try reveal(input.handle, in: widget)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertNil(widget.surface.command(at: point))
        let delivered = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.actions.count, delivered + 1)
        XCTAssertEqual(widget.invoke(try XCTUnwrap(widget.actions.last), view: OMNI_VIEW_POPOUT), [])
        let edited = try edit("Draft survives batch updates", in: widget)
        let editedFrame = try reveal(edited.handle, in: widget)
        let editedPoint = CGPoint(x: editedFrame.midX, y: editedFrame.midY)
        let beforeDraftClick = widget.actions.count
        widget.surface.press(at: editedPoint)
        widget.surface.release(at: editedPoint)
        XCTAssertEqual(widget.actions.count, beforeDraftClick + 1)
        XCTAssertEqual(widget.invoke(try XCTUnwrap(widget.actions.last), view: OMNI_VIEW_POPOUT), [])
        widget.layoutPopout()
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "Draft survives batch updates")
        XCTAssertEqual(try click(ShellLocalizer.string("Cancel", []), in: widget), [])
        XCTAssertEqual(try click(ShellLocalizer.string("Reply", []), in: widget), [])
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "Draft survives batch updates")
        set(widget, state: "ready", items: [retained], dismissAll: [
            "active": true, "total": 1, "completed": 0, "failed": 0, "state": "pending"
        ])
        widget.layoutPopout()
        XCTAssertEqual(try click("×", in: widget), [])
        XCTAssertEqual(try click(ShellLocalizer.string("Reply", []), in: widget), [])
        XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [])
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "Draft survives batch updates")
    }

    func testClearAllHeaderTracksProgressCancellationAndFailureWithoutRemovingItems() throws {
        let widget = try ShellRenderedWidget("notifications")
        let retained = item()
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertEqual(try click(ShellLocalizer.string("Clear All", []), in: widget), ["notifications dismiss-all"])
        for state in ["pending", "cancelling", "cancelled", "partial", "completed", "failed"] {
            let active = ["pending", "cancelling"].contains(state)
            set(widget, state: "ready", items: [retained], dismissAll: [
                "active": active, "total": 12, "completed": 9, "failed": 2, "state": state,
                "outcome": "failedPanelOpen"
            ])
            widget.layoutPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Fixture title ✓"), state)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
                "The action failed. Close Notification Center and try again.", []
            )), state)
            XCTAssertEqual(
                try click(ShellLocalizer.string("Clear All", []), in: widget),
                active ? [] : ["notifications dismiss-all"], state
            )
            if active {
                XCTAssertEqual(
                    try click(ShellLocalizer.string("Cancel", []), in: widget),
                    state == "cancelling" ? [] : ["notifications cancel-dismiss-all"], state
                )
            }
        }
        set(widget, state: "incomplete", items: [retained], complete: false)
        widget.layoutPopout()
        XCTAssertEqual(try click(ShellLocalizer.string("Clear All", []), in: widget), [])
        XCTAssertEqual(try click("×", in: widget), [])
        set(widget, state: "empty")
        widget.layoutPopout()
        XCTAssertEqual(try click(ShellLocalizer.string("Clear All", []), in: widget), [])
    }

    func testDispatchedCardsDisappearFromEveryPageAndBarCountUntilKeptPublication() throws {
        let widget = try ShellRenderedWidget("notifications")
        let items = (0 ..< 10).map { item("item-\($0)", body: "Retained body \($0)") }
        set(widget, state: "ready", items: items)
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("10"))
        set(widget, state: "ready", items: items, dispatched: ["ITEM-0", "item-8"])
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("8"))
        widget.layoutPopout()
        let visible = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertFalse(visible.contains("Retained body 0"))
        XCTAssertFalse(visible.contains("Retained body 8"))
        XCTAssertTrue(visible.contains("Retained body 9"))
        XCTAssertFalse(visible.contains(ShellLocalizer.string("Next", [])))
        set(widget, state: "ready", items: items, dispatched: (0 ..< 10).map { "item-\($0)" })
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains("10"))
        XCTAssertFalse(widget.strings().contains("0"))
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains { $0.hasPrefix("Retained body") })
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("No retained notifications", [])))
        try assertButton(ShellLocalizer.string("Clear All", []), enabled: false, in: widget)
        set(widget, state: "ready", items: items, kept: 1)
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("10"))
        widget.layoutPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Retained body 0"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("macOS kept notifications: 1"))
        try assertButton(ShellLocalizer.string("Clear All", []), enabled: true, in: widget)
    }

    func testHiddenSuccessfulActionKeepsPanelRestorationGuidanceOutsideCards() throws {
        let widget = try ShellRenderedWidget("notifications")
        let id = "a2345678-9abc-def0-1234-56789abcdef0"
        let retained = item(id)
        set(widget, state: "ready", items: [retained])
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("1"))
        let guidance = "Action submitted. Close Notification Center to continue."
        set(
            widget, state: "ready", items: [retained],
            action: nativeAction(id.uppercased(), state: "dispatchedPanelOpen", kind: "dismiss"),
            dispatched: [id]
        )
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains("1"))
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Fixture title ✓"))
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Fixture body"))
        XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).filter { $0 == guidance }.count, 1)
        let note = try XCTUnwrap(widget.surface.layout.core.elements { widget.text.string($0.text) == guidance }.first)
        let frame = try reveal(note, in: widget)
        XCTAssertNil(widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)))
        set(
            widget, state: "ready", items: [retained],
            action: nativeAction(id, state: "dispatchedPanelOpen", kind: "dismiss"),
            dismissAll: [
                "active": false, "total": 1, "completed": 1, "failed": 0, "state": "completed",
                "outcome": "dispatchedPanelOpen"
            ],
            dispatched: [id.uppercased()]
        )
        widget.layoutPopout()
        XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).filter { $0 == guidance }.count, 1)
        set(
            widget, state: "ready", items: [retained],
            action: nativeAction(id, state: "dispatchedPanelOpen", kind: "reply"), dispatched: [id]
        )
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Fixture title ✓"))
        XCTAssertEqual(widget.strings(OMNI_VIEW_POPOUT).filter { $0 == guidance }.count, 1)
    }

    func testClearAllStaysInHeaderWhileCancelSitsBesideProgressAndDimsDuringCancellation() throws {
        let widget = try ShellRenderedWidget("notifications")
        let retained = item()
        set(widget, state: "ready", items: [retained], dismissAll: [
            "active": true, "total": 1, "completed": 0, "failed": 0, "state": "pending"
        ])
        widget.layoutPopout()
        try assertButton(ShellLocalizer.string("Clear All", []), enabled: false, in: widget)
        try assertButton(ShellLocalizer.string("Cancel", []), enabled: true, in: widget)
        let clear = try control(ShellLocalizer.string("Clear All", []), in: widget)
        let cancel = try control(ShellLocalizer.string("Cancel", []), in: widget)
        let progress = try XCTUnwrap(widget.surface.layout.core.elements {
            widget.text.string($0.text) == "Clearing notifications: 0 of 1"
        }.first)
        XCTAssertNotEqual(widget.surface.layout.core.parent(of: clear), widget.surface.layout.core.parent(of: cancel))
        XCTAssertEqual(widget.surface.layout.core.parent(of: progress), widget.surface.layout.core.parent(of: cancel))
        let clearFrame = try reveal(clear, in: widget)
        let cancelFrame = try reveal(cancel, in: widget)
        XCTAssertLessThanOrEqual(clearFrame.maxY, cancelFrame.minY)
        XCTAssertEqual(try click(ShellLocalizer.string("Cancel", []), in: widget), ["notifications cancel-dismiss-all"])
        set(widget, state: "ready", items: [retained], dismissAll: [
            "active": true, "total": 1, "completed": 0, "failed": 0, "state": "cancelling"
        ])
        widget.layoutPopout()
        try assertButton(ShellLocalizer.string("Clear All", []), enabled: false, in: widget)
        try assertButton(ShellLocalizer.string("Cancel", []), enabled: false, in: widget)
        set(widget, state: "ready", items: [retained], dismissAll: [
            "active": false, "total": 1, "completed": 1, "failed": 0, "state": "completed"
        ])
        widget.layoutPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Cancel", [])))
    }

    func testEveryProfileDimsBusyActionsWithoutHoverWhileConsumingTheirClicks() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        for profile in ShellProfiles.names(in: shell) {
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            let widget = try styledWidget(config, shell: shell)
            var bar = ShellBarData()
            bar.style.height = config.barOverride?.settings.height ?? 24
            widget.render(bar)
            set(widget, state: "ready", items: [item(id)])
            widget.layoutPopout()
            try assertButton(ShellLocalizer.string("Clear All", []), enabled: true, in: widget)
            XCTAssertEqual(try click(ShellLocalizer.string("Reply", []), in: widget), [])
            try edit("Retained draft", in: widget)
            set(widget, state: "ready", items: [item(id)], dismissAll: [
                "active": true, "total": 1, "completed": 0, "failed": 0, "state": "pending"
            ])
            widget.layoutPopout()
            for title in ["Clear All", "Reply", "Send"] {
                try assertButton(ShellLocalizer.string(title, []), enabled: false, in: widget)
            }
            try assertButton("×", enabled: false, in: widget)
            XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "Retained draft", profile)
            try export(widget, name: "\(profile)-dismiss-disabled")
        }
    }

    func testPaginationReachesEveryRetainedItem() throws {
        let widget = try ShellRenderedWidget("notifications")
        let items = (0 ..< 9).map { item("item-\($0)", body: "Item body \($0)") }
        set(widget, state: "ready", items: items)
        let first = widget.renderPopout()
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains("Item body 8"))
        let next = try XCTUnwrap(first.last { $0.content.action & OMNI_ACTION_HANDLER != 0 })
        _ = widget.invoke(next.content.action, view: OMNI_VIEW_POPOUT)
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Item body 8"))
    }

    private func styledWidget(
        _ config: ShellConfig,
        shell: URL,
        scale: CGFloat = 2,
        dark: Bool = false
    ) throws -> ShellRenderedWidget {
        let sourceURL = try XCTUnwrap(config.widget("notifications"))
        let source = try ShellWidgetSourceLoader.build(.init(
            name: "notifications", shellDirectory: shell, sourceURL: sourceURL,
            directories: config.directories, profile: config.profile
        ))
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.palette.refresh(
            theme: config.theme,
            appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        )
        return try ShellRenderedWidget(
            name: "notifications", source: source.main, directories: config.directories,
            modules: source.modules, chunk: source.chunk, scale: scale, resources: resources
        )
    }

    private func export(_ widget: ShellRenderedWidget, name: String, dark: Bool = false) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        try ShellBundledWidgetTests.writeSnapshot(
            widget.surface,
            name: "notifications-\(name)",
            dark: dark,
            directory: directory
        )
    }

    @discardableResult
    private func click(_ title: String, in widget: ShellRenderedWidget, last: Bool = false) throws -> [String] {
        let labels = widget.surface.layout.core.elements { widget.text.string($0.text) == title }.sorted {
            CGRect(widget.surface.layout.core.absoluteFrame(of: $0)).minY
                < CGRect(widget.surface.layout.core.absoluteFrame(of: $1)).minY
        }
        let label = try XCTUnwrap(last ? labels.last : labels.first, title)
        var target = label
        while widget.surface.layout.core.content(of: target).action == 0 {
            target = widget.surface.layout.core.parent(of: target)
            guard target.slot >= 0 else {
                XCTFail("No action for \(title)")
                return []
            }
        }
        let action = widget.surface.layout.core.content(of: target).action
        let frame = try reveal(label, in: widget)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return try deliver(at: point, in: widget, expected: action)
    }

    private func deliver(
        at point: CGPoint,
        in widget: ShellRenderedWidget,
        expected: UInt32? = nil
    ) throws -> [String] {
        let delivered = widget.actions.count
        widget.surface.press(at: point)
        widget.surface.release(at: point)
        XCTAssertEqual(widget.actions.count, delivered + 1)
        let action = try XCTUnwrap(widget.actions.last)
        if let expected { XCTAssertEqual(action, expected) }
        let requests: [String]
        if action & OMNI_ACTION_HANDLER != 0 {
            requests = widget.invoke(action, view: OMNI_VIEW_POPOUT)
        } else {
            let command = widget.text.string(action)
            XCTAssertNotNil(ShellAction(command))
            requests = [command]
        }
        widget.layoutPopout()
        return requests
    }

    private func reveal(_ target: ElementHandle, in widget: ShellRenderedWidget) throws -> CGRect {
        var frame = CGRect(widget.surface.layout.core.absoluteFrame(of: target))
        let bounds = CGRect(origin: .zero, size: widget.surface.size)
        if !bounds.contains(frame) {
            let scroll = try XCTUnwrap(widget.surface.layout.core.elements { $0.scrolls }.first)
            let viewport = CGRect(widget.surface.layout.core.absoluteFrame(of: scroll)).intersection(bounds)
            XCTAssertTrue(widget.surface.scroll(
                at: CGPoint(x: viewport.midX, y: viewport.midY), event: ShellEvent(button: .none),
                content: CGPoint(x: 0, y: frame.midY - viewport.midY)
            ))
            frame = CGRect(widget.surface.layout.core.absoluteFrame(of: target))
        }
        XCTAssertTrue(bounds.contains(frame))
        return frame
    }

    private func control(_ title: String, in widget: ShellRenderedWidget) throws -> ElementHandle {
        var target = try XCTUnwrap(widget.surface.layout.core.elements { widget.text.string($0.text) == title }.first)
        while widget.surface.layout.core.content(of: target).action == 0 {
            let parent = widget.surface.layout.core.parent(of: target)
            target = try XCTUnwrap(parent.slot >= 0 ? parent : nil, title)
        }
        return target
    }

    private func action(_ title: String, in widget: ShellRenderedWidget) throws -> UInt32 {
        widget.surface.layout.core.content(of: try control(title, in: widget)).action
    }

    private func assertButton(_ title: String, enabled: Bool, in widget: ShellRenderedWidget) throws {
        let target = try control(title, in: widget)
        let content = widget.surface.layout.core.content(of: target)
        XCTAssertEqual(widget.surface.layout.core.paint(of: target).opacity, enabled ? 1 : 0.4, accuracy: 0.001, title)
        XCTAssertEqual(content.hasHoverEffect, enabled, title)
        if !enabled {
            XCTAssertNotEqual(content.action & OMNI_ACTION_HANDLER, 0, title)
            XCTAssertEqual(try click(title, in: widget), [], title)
        }
    }

    @discardableResult
    private func edit(_ draft: String, in widget: ShellRenderedWidget) throws -> ShellTextInput {
        let input = try XCTUnwrap(widget.surface.textInputs.values.first)
        var events: [ShellClick] = []
        widget.surface.onAction = { events.append($0) }
        input.beganEditing()
        let editor = try XCTUnwrap(input.editor)
        editor.string = draft
        input.changed()
        widget.surface.onAction = { [unowned widget] click in
            widget.actions.append(click.action)
            widget.clicks.append((widget.text.string(click.action), click.event.button))
        }
        for event in events {
            XCTAssertEqual(widget.invoke(event.action, view: OMNI_VIEW_POPOUT, event: event.event), [])
        }
        widget.layoutPopout()
        return input
    }

    private func nativeAction(_ id: String, state: String, kind: String = "reply") -> [String: Any] {
        ["id": id, "bundle": "com.example.fixture", "kind": kind, "state": state]
    }

    func testNativeReplyPreservesDraftOnFailuresAndWaitsForAuthoritativeDispatch() throws {
        let widget = try ShellRenderedWidget("notifications")
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let retained = item(id)
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        XCTAssertEqual(
            widget.text.string(try action("×", in: widget)),
            "notifications dismiss com.example.fixture \(id)"
        )
        try click(ShellLocalizer.string("Reply", []), in: widget)
        let draft = "Reply ✓ 中文 العربية 👩🏽‍💻 e\u{301}\n\"quoted\" \\ slash"
        let input = try edit(draft, in: widget)
        let command = "notifications reply com.example.fixture \(id) "
            + draft.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [command])
        XCTAssertEqual(input.text, draft)
        XCTAssertTrue(widget.surface.textInputs.values.contains { $0 === input })
        var unrelated = nativeAction(id, state: "dispatched")
        unrelated["bundle"] = "com.example.other"
        set(widget, state: "ready", items: [retained], action: unrelated)
        widget.layoutPopout()
        XCTAssertEqual(input.text, draft)
        set(widget, state: "ready", items: [retained], action: nativeAction(id, state: "pending"))
        widget.layoutPopout()
        XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [])
        XCTAssertEqual(try click("×", in: widget), [])
        XCTAssertEqual(input.text, draft)
        for state in ["notFound", "denied", "ambiguous", "failed", "timeout", "failedPanelOpen"] {
            set(widget, state: "ready", items: [retained], action: nativeAction(id, state: state))
            widget.layoutPopout()
            XCTAssertEqual(input.text, draft, state)
            XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [command], state)
        }
        set(widget, state: "ready", items: [retained], action: nativeAction(id, state: "dispatchedPanelOpen"))
        widget.layoutPopout()
        XCTAssertTrue(widget.surface.textInputs.isEmpty)
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Fixture body"))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Action submitted. Close Notification Center to continue.", []
        )))
        try click(ShellLocalizer.string("Reply", []), in: widget)
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "")
        try edit("Discard when the retained item disappears", in: widget)
        set(widget, state: "empty")
        widget.layoutPopout()
        XCTAssertTrue(widget.surface.textInputs.isEmpty)
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        try click(ShellLocalizer.string("Reply", []), in: widget)
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, "")
    }

    func testNativeReplyRequiresAnUnambiguousActionAndBoundsUTF8WithoutLosingTheDraft() throws {
        let widget = try ShellRenderedWidget("notifications")
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        var retained = item(id)
        let reply = try XCTUnwrap((retained["actions"] as? [[String: Any]])?.first)
        let ambiguous: [[[String: Any]]] = [[], [reply, reply], [reply, ["title": "Reply ✓"]]]
        for actions in ambiguous {
            retained["actions"] = actions
            set(widget, state: "ready", items: [retained])
            widget.layoutPopout()
            XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Reply", [])))
        }
        retained["actions"] = [reply]
        set(widget, state: "incomplete", items: [retained], complete: false)
        widget.layoutPopout()
        XCTAssertEqual(try click("×", in: widget), [])
        XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string("Reply", [])))
        set(widget, state: "ready", items: [retained])
        widget.layoutPopout()
        try click(ShellLocalizer.string("Reply", []), in: widget)
        for (invalid, message) in [
            (" \t\n\u{00A0}\u{2003}", "Reply cannot be empty."),
            ("Reply\0text", "Reply contains unsupported characters.")
        ] {
            let input = try edit(invalid, in: widget)
            XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [])
            XCTAssertEqual(input.text, invalid)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(message, [])))
        }
        let draft = String(repeating: "e\u{301}\u{301}\u{301}\u{301}", count: 600)
        XCTAssertLessThan(draft.count, 1024)
        XCTAssertGreaterThan(draft.utf8.count, 4096)
        let input = try edit(draft, in: widget)
        XCTAssertEqual(try click(ShellLocalizer.string("Send", []), in: widget), [])
        XCTAssertEqual(input.text, draft)
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(
            "Reply exceeds the 4096-byte limit.",
            []
        )))
        try click(ShellLocalizer.string("Cancel", []), in: widget)
        XCTAssertTrue(widget.surface.textInputs.isEmpty)
        try click(ShellLocalizer.string("Reply", []), in: widget)
        XCTAssertEqual(try XCTUnwrap(widget.surface.textInputs.values.first).text, draft)
    }

    func testNativeReplyCommandsReachTheParserWhole() throws {
        let id = try XCTUnwrap(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef"))
        let ascii = String(repeating: "a", count: 300)
        let unicode = String(repeating: "Reply ✓ 中文 العربية 👩🏽‍💻 e\u{301}\n", count: 12)
        let maximum = String(repeating: "👩🏽‍💻", count: 273) + "a"
        let longest = "com." + String(repeating: "a", count: 251)
        XCTAssertEqual(maximum.utf8.count, 4096)
        XCTAssertEqual(longest.utf8.count, 255)
        for (bundle, draft) in [
            ("com.example.fixture", ascii),
            ("com.example.fixtures", ascii),
            ("com.example.fixtures", unicode),
            (longest, maximum)
        ] {
            let widget = try ShellRenderedWidget("notifications")
            var retained = item(id.uuidString.lowercased())
            retained["bundle"] = bundle
            set(widget, state: "ready", items: [retained])
            widget.layoutPopout()
            try click(ShellLocalizer.string("Reply", []), in: widget)
            try edit(draft, in: widget)
            XCTAssertEqual(
                try click(ShellLocalizer.string("Send", []), in: widget).compactMap(ShellAction.init),
                [.notifications(.reply(bundle: bundle, id: id, text: draft))],
                bundle
            )
        }
    }

    func testEveryNotificationProfileKeepsNativeReplyControlsInsideTheCard() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        for profile in ShellProfiles.names(in: shell) {
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            for dark in [false, true] {
                let widget = try styledWidget(config, shell: shell, dark: dark)
                var bar = ShellBarData()
                bar.style.height = config.barOverride?.settings.height ?? 24
                widget.render(bar)
                set(widget, state: "ready", items: [item(id)])
                widget.layoutPopout()
                widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
                widget.surface.view.layoutSubtreeIfNeeded()
                try click(ShellLocalizer.string("Reply", []), in: widget)
                let input = try edit("Reply ✓ 中文 العربية 👩🏽‍💻", in: widget)
                let frame = try reveal(input.handle, in: widget)
                let parent = widget.surface.layout.core.parent(of: input.handle)
                XCTAssertTrue(CGRect(widget.surface.layout.core.absoluteFrame(of: parent)).contains(frame), profile)
                XCTAssertFalse(input.view.isHidden, profile)
                XCTAssertEqual(input.text, "Reply ✓ 中文 العربية 👩🏽‍💻", profile)
                XCTAssertNotNil(input.editor, profile)
                XCTAssertEqual(input.editor?.placeholder, "Write a reply", profile)
                input.view.displayIfNeeded()
                try export(widget, name: "\(profile)-reply-\(dark ? "dark" : "light")", dark: dark)
                let targetID = try XCTUnwrap(UUID(uuidString: id))
                XCTAssertEqual(
                    try click(ShellLocalizer.string("Send", []), in: widget).compactMap(ShellAction.init),
                    [.notifications(.reply(bundle: "com.example.fixture", id: targetID, text: "Reply ✓ 中文 العربية 👩🏽‍💻"))],
                    profile
                )
                XCTAssertEqual(try click(ShellLocalizer.string("Cancel", []), in: widget), [], profile)
                XCTAssertTrue(widget.surface.textInputs.isEmpty, profile)
            }
        }
    }

    func testNotificationProfilesFitBaseAndEnlargedBarsAtBothScalesAndOrientations() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        let profiles = ShellProfiles.names(in: shell)
        XCTAssertEqual(profiles.count, 8)
        let counts = (0 ..< 256).map { item("item-\($0)") }
        for profile in profiles {
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            guard (config.leading + config.center + config.trailing).contains("notifications") else {
                XCTAssertEqual(profile, "vitreus")
                continue
            }
            let base = config.barOverride?.settings.height ?? 24
            for dark in [false, true] {
                for scale in [CGFloat(1), 2] {
                    let widget = try styledWidget(config, shell: shell, scale: scale, dark: dark)
                    set(widget, state: "ready", items: counts)
                    for height in [base, base * 1.5] {
                        for vertical in [false, true] {
                            var bar = ShellBarData()
                            bar.style.height = height
                            bar.style.vertical = vertical
                            bar.style.position = vertical ? "left" : "top"
                            widget.render(bar)
                            let name = "\(profile)-\(height)-\(vertical ? "vertical" : "horizontal")-\(scale)-\(dark ? "dark" : "light")"
                            let bounds = CGRect(origin: .zero, size: widget.surface.size)
                            XCTAssertTrue(bounds.width.isFinite && bounds.height.isFinite, name)
                            XCTAssertGreaterThan(bounds.width, 0, name)
                            XCTAssertGreaterThan(bounds.height, 0, name)
                            XCTAssertLessThanOrEqual(vertical ? bounds.width : bounds.height, height, name)
                            for leaf in widget.surface.layout.core.elements(matching: { $0.text != 0 }) {
                                let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: leaf))
                                XCTAssertTrue(bounds.contains(frame), name)
                            }
                            let target = try XCTUnwrap(widget.surface.layout.core
                                .elements { $0.action == OMNI_ACTION_POPOUT }.first)
                            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: target))
                            widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
                            widget.surface.release(at: CGPoint(x: frame.midX, y: frame.midY))
                            XCTAssertEqual(widget.actions.last, UInt32(OMNI_ACTION_POPOUT), name)
                            XCTAssertTrue(widget.strings().contains("256"), name)
                            if scale == 2, height == base { try export(widget, name: name, dark: dark) }
                        }
                    }
                }
            }
        }
    }

    func testNotificationProfilesKeepStorageStatesAndDeliveredCardPaging() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
        for profile in ShellProfiles.names(in: shell) {
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
            XCTAssertEqual(problems, [], profile)
            let widget = try styledWidget(config, shell: shell)
            var bar = ShellBarData()
            bar.style.height = config.barOverride?.settings.height ?? 24
            widget.render(bar)
            for state in ["accessDenied", "empty"] {
                set(widget, state: state)
                widget.layoutPopout()
                let strings = widget.strings(OMNI_VIEW_POPOUT)
                XCTAssertEqual(
                    strings.contains(ShellLocalizer.string("No retained notifications", [])),
                    state == "empty",
                    profile
                )
                XCTAssertFalse(strings.contains(ShellLocalizer.string("Refresh", [])))
                for action in ["notifications settings"] {
                    let target = try XCTUnwrap(widget.surface.layout.core
                        .elements { widget.text.string($0.action) == action }.first)
                    let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: target))
                    XCTAssertTrue(CGRect(origin: .zero, size: widget.surface.size).contains(frame), profile)
                    widget.surface.press(at: CGPoint(x: frame.midX, y: frame.midY))
                    widget.surface.release(at: CGPoint(x: frame.midX, y: frame.midY))
                    XCTAssertEqual(widget.clicks.last?.action, action, profile)
                }
                try export(widget, name: "\(profile)-\(state)")
            }
            var items = (0 ..< 9).map { item("item-\($0)", body: "Notification body \($0) ✓ 中文 العربية 👩🏽‍💻") }
            items[0]["metadata"] = Dictionary(uniqueKeysWithValues: (0 ..< 40).map { (
                String(format: "field%02d", $0),
                "Metadata \($0)"
            ) })
            set(widget, state: "ready", items: items)
            widget.layoutPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Notification body 0 ✓ 中文 العربية 👩🏽‍💻"), profile)
            let bounds = CGRect(origin: .zero, size: widget.surface.size)
            XCTAssertGreaterThanOrEqual(bounds.width, 392, profile)
            XCTAssertLessThanOrEqual(bounds.width, 480, profile)
            try export(widget, name: "\(profile)-ready")
            XCTAssertEqual(
                try click(ShellLocalizer.string("Clear All", []), in: widget),
                ["notifications dismiss-all"],
                profile
            )
            XCTAssertFalse(widget.strings(OMNI_VIEW_POPOUT).contains { $0.contains("metadata.field") })
            XCTAssertEqual(
                try click("Fixture title ✓", in: widget), ["notifications open com.example.fixture"], profile
            )
            try click(ShellLocalizer.string("Next", []), in: widget, last: true)
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("Notification body 8 ✓ 中文 العربية 👩🏽‍💻"), profile)
            try export(widget, name: "\(profile)-last-page")
        }
    }
}
