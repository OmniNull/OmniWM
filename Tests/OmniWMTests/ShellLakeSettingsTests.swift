// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellLakeSettingsTests: XCTestCase {
    func testComponentControlsUseDeclaredTypesAndPublicActions() throws {
        for (help, number, flag) in [("Seconds", 0.0, true), ("Increase Size", 14.0, false), ("Next Face", 0.0, true)] {
            let widget = try fixture()
            widget.render(ShellBarData())
            widget.invoke(try action(help, in: widget))
            XCTAssertEqual(globalNumber("lastOperation", widget), 5)
            XCTAssertEqual(globalNumber("lastNumber", widget), number)
            XCTAssertEqual(globalBool("lastValueMatches", widget), flag)
            XCTAssertTrue(globalBool("lastIDMatches", widget))
        }
        let widget = try fixture()
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains("Edit in shell.toml"))
        let input = try textInput("Edit Zone", in: widget)
        XCTAssertEqual(input.content.inputMaxLength, 64)
        XCTAssertEqual(input.content.action, 0)
        XCTAssertTrue(input.content.inputMultiline)
    }

    func testComponentManagementAndEndedDragUseStableInstanceIDs() throws {
        let add = try fixture()
        add.render(ShellBarData())
        add.invoke(try action("Add widget", in: add))
        add.render(ShellBarData())
        add.invoke(try action("Add Clock", in: add))
        XCTAssertEqual(globalNumber("lastOperation", add), 1)
        XCTAssertTrue(globalBool("lastIDMatches", add))

        for (help, operation) in [("Remove Clock", 2.0), ("Disable Clock", 4.0)] {
            let widget = try fixture()
            widget.render(ShellBarData())
            widget.invoke(try action(help, in: widget))
            XCTAssertEqual(globalNumber("lastOperation", widget), operation)
            XCTAssertTrue(globalBool("lastIDMatches", widget))
        }

        let drag = try fixture()
        drag.render(ShellBarData())
        let node = try XCTUnwrap(drag.tree().first { drag.text.string($0.content.help) == "Drag to reorder Clock" })
        XCTAssertNotEqual(node.content.gestureTrack, 0)
        XCTAssertFalse(node.content.gesture.eventsAll)
        drag.invoke(node.content.gestureAction, event: ShellEvent(dy: 40, phase: .changed, kind: .gesture))
        XCTAssertEqual(globalNumber("lastOperation", drag), 0)
        drag.invoke(
            node.content.gestureAction,
            event: ShellEvent(dy: 40, phase: .ended, kind: .gesture, committed: true)
        )
        XCTAssertEqual(globalNumber("lastOperation", drag), 3)
        XCTAssertEqual(globalNumber("lastNumber", drag), 2)

        let region = try fixture()
        region.render(ShellBarData())
        region.invoke(try action("Choose where this component appears", in: region))
        XCTAssertEqual(globalNumber("lastOperation", region), 6)
        XCTAssertTrue(globalBool("lastValueMatches", region))
    }

    func testRootSchemaControlsAndMissingSchemaFallback() throws {
        for (pane, control, number, flag) in [
            ("Appearance settings", "Increase Expanded width", 540.0, false),
            ("Interaction settings", "Hover preview", 0.0, false),
            ("Motion settings", "Increase Expansion bounce", 0.2, false)
        ] {
            let widget = try fixture()
            widget.render(ShellBarData())
            widget.invoke(try action(pane, in: widget))
            widget.render(ShellBarData())
            widget.invoke(try action(control, in: widget))
            XCTAssertEqual(globalNumber("lastOperation", widget), 6)
            XCTAssertEqual(globalNumber("lastNumber", widget), number, accuracy: 0.000001)
            XCTAssertEqual(globalBool("lastValueMatches", widget), flag)
        }
        let absent = try fixture(schema: false)
        absent.render(ShellBarData())
        absent.invoke(try action("Appearance settings", in: absent))
        absent.render(ShellBarData())
        XCTAssertTrue(absent.strings().contains("Edit this profile’s settings in shell.toml."))
    }

    func testRootColorAndActionTargetsUseValidatedPublicWrites() throws {
        for (pane, help, value, flag) in [
            ("Appearance settings", "Edit Solid background color", "#11223344", "lastColorMatches"),
            ("Interaction settings", "Edit Click target", "component:two", "lastTargetMatches")
        ] {
            let widget = try fixture()
            widget.render(ShellBarData())
            widget.invoke(try action(pane, in: widget))
            widget.render(ShellBarData())
            let input = try textInput(help, in: widget)
            XCTAssertEqual(input.content.action, 0)
            var event = ShellEvent(kind: .textCommit)
            event.text = value
            widget.invoke(input.content.inputCommitAction, event: event)
            XCTAssertEqual(globalNumber("lastOperation", widget), 6)
            XCTAssertTrue(globalBool(flag, widget))
            widget.render(ShellBarData())
            XCTAssertTrue(widget.strings().contains("Saving…"))
        }
        for (pane, help, value, diagnostic) in [
            ("Appearance settings", "Edit Solid background color", "#xyz", "Use #RRGGBB or #RRGGBBAA for this color."),
            (
                "Interaction settings",
                "Edit Click target",
                "component:missing",
                "Choose toggle, expand, collapse, settings, next, previous, none, or component:<enabled ID>."
            )
        ] {
            let widget = try fixture()
            widget.render(ShellBarData())
            widget.invoke(try action(pane, in: widget))
            widget.render(ShellBarData())
            var event = ShellEvent(kind: .textCommit)
            event.text = value
            widget.invoke(try textInput(help, in: widget).content.inputCommitAction, event: event)
            XCTAssertEqual(globalNumber("lastOperation", widget), 0)
            widget.render(ShellBarData())
            XCTAssertTrue(widget.strings().contains(diagnostic))
        }
    }

    func testFocusedComponentRowDeclaresAndClosesWithEscape() throws {
        let widget = try fixture()
        widget.render(ShellBarData())
        let row = try XCTUnwrap(widget.tree().first { node in
            let keys = widget.text.string(node.content.keys)
            return node.content.focusable && keys.contains("up") && keys.contains("down")
        })
        XCTAssertTrue(widget.text.string(row.content.keys).split(separator: "\n").contains("escape"))
        widget.invoke(row.content.keyAction, event: ShellEvent(kind: .key, key: "escape"))
        XCTAssertTrue(globalBool("didCloseSettings", widget))
        XCTAssertEqual(globalNumber("lastOperation", widget), 0)
    }

    func testAdmissionAndPersistenceErrorsStayVisible() throws {
        let rejected = try fixture(reject: true)
        rejected.render(ShellBarData())
        rejected.invoke(try action("Seconds", in: rejected))
        rejected.render(ShellBarData())
        XCTAssertTrue(rejected.strings().contains("Configuration queue is full"))

        let pending = try fixture()
        pending.render(ShellBarData())
        pending.invoke(try action("Seconds", in: pending))
        pending.render(ShellBarData())
        XCTAssertTrue(pending.strings().contains("Saving…"))
        var writer = ShellValueWriter()
        writer.map(0)
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_trigger(pending.instance, $0.baseAddress, $0.count, 25_000_000, &error, error.count)
        }, OMNI_OK)
        pending.render(ShellBarData())
        XCTAssertTrue(pending.strings().contains("Disk is full"))
        XCTAssertFalse(pending.strings().contains("Saving…"))
    }

    func testCatalogPagesKeepTheSettingsTreeBounded() throws {
        let widget = try fixture(catalogCount: 512)
        widget.render(ShellBarData())
        widget.invoke(try action("Add widget", in: widget))
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("1 / 43"))
        XCTAssertLessThan(widget.tree().count, 1024)
        XCTAssertFalse(widget.strings().contains("Component 13"))
    }

    func testRegionPolicyAndKeyboardChoiceStayInEditableLuau() throws {
        let folder = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake/lib/lake")
        let preferences = try String(contentsOf: folder.appendingPathComponent("preferences.luau"), encoding: .utf8)
        let policy = try String(contentsOf: folder.appendingPathComponent("policy.luau"), encoding: .utf8)
        let widget = try ShellRenderedWidget(name: "regions", source: """
        local function loadPreferences()
            \(preferences)
        end
        local preferences = loadPreferences()
        local forbidActivity = false
        local function loadPolicy()
            local require = function() return preferences end
            local omniwm = { components = { activity = function()
                assert(not forbidActivity, "keyboard selection must not evaluate activity")
                return nil
            end } }
            \(policy)
        end
        local policy = loadPolicy()
        function render()
            local ctx = { state = {}, data = { settings = { regions = { "a:main", "b:side", "c:expanded" } }, components = {
                { id = "a", title = "A", enabled = true }, { id = "b", title = "B", enabled = true },
                { id = "c", title = "C", enabled = true }, { id = "d", title = "D", enabled = true },
            } } }
            local primary, secondary = policy.placed(policy.select(ctx), false)
            assert(primary.id == "a" and secondary.id == "b")
            ctx.state.primary = "c"
            ctx.state.expanded = true
            primary, secondary = policy.placed(policy.select(ctx), true)
            assert(primary.id == "c" and secondary.id == "b")
            ctx.state.expanded = false
            primary, secondary = policy.placed(policy.select(ctx), false)
            assert(primary.id == "a" and secondary.id == "b")
            forbidActivity = true
            policy.step(ctx, 1, "a")
            assert(ctx.state.primary == "d")
            local regions = preferences.assigningRegion(ctx, "b", "auto")
            assert(#regions == 2 and regions[1] == "a:main" and regions[2] == "c:expanded")
            return ui.text { text = "Regions stay in Luau" }
        end
        """)
        widget.render(ShellBarData())
        XCTAssertEqual(widget.strings(), ["Regions stay in Luau"])
    }

    func testStringOptionCommitAndCancelUseNativeEventTextWithoutPerKeystrokeHandlers() throws {
        let widget = try fixture()
        widget.render(ShellBarData())
        let input = try textInput("Edit Zone", in: widget)
        XCTAssertEqual(widget.text.string(input.content.text), "UTC")
        widget.invoke(input.content.inputCancelAction, event: ShellEvent(kind: .textCancel))
        XCTAssertEqual(globalNumber("lastOperation", widget), 0)
        widget.render(ShellBarData())
        XCTAssertEqual(widget.text.string(try textInput("Edit Zone", in: widget).content.text), "UTC")
        let current = try textInput("Edit Zone", in: widget)
        var event = ShellEvent(kind: .textCommit)
        event.text = "Asia/Tokyo"
        widget.invoke(current.content.inputCommitAction, event: event)
        XCTAssertEqual(globalNumber("lastOperation", widget), 5)
        XCTAssertTrue(globalBool("lastStringMatches", widget))
        XCTAssertTrue(globalBool("lastIDMatches", widget))
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Saving…"))
    }

    func testTextCancelPublishesAChangedIdentityAndRestoresNativeSavedText() throws {
        _ = NSApplication.shared
        for (root, list) in [(false, false), (true, true)] {
            let widget = try fixture()
            widget.surface.view.frame = CGRect(x: 0, y: 0, width: 760, height: 360)
            widget.render(ShellBarData())
            if root {
                widget.invoke(try action("Appearance settings", in: widget))
                widget.render(ShellBarData())
            }
            if list {
                widget.invoke(try action("Edit Aliases values", in: widget))
                widget.render(ShellBarData())
            }
            let help = list ? "Edit Aliases 2" : "Edit Zone"
            let saved = list ? "line\nbreak" : "UTC"
            var events: [ShellClick] = []
            widget.surface.onAction = { events.append($0) }
            defer { widget.surface.onAction = nil }
            for _ in 0 ..< 3 {
                XCTAssertFalse(renderPublished(widget))
                let input = try XCTUnwrap(widget.surface.textInputs.values.first {
                    widget.text.string($0.capture.content.help) == help
                })
                XCTAssertEqual(input.text, saved)
                XCTAssertEqual(input.capture.content.action, 0)
                input.beganEditing()
                let editor = try XCTUnwrap(input.editor)
                editor.string = "discard this draft"
                input.changed()
                XCTAssertTrue(events.isEmpty)
                XCTAssertEqual(globalNumber("lastOperation", widget), 0)
                input.finish(commit: false)
                XCTAssertEqual(events.map(\.event.kind), [.textCancel])
                XCTAssertEqual(input.text, "discard this draft")
                XCTAssertFalse(input.editing)
                let cancel = try XCTUnwrap(events.first)
                events.removeAll()
                widget.invoke(cancel.action, event: cancel.event)
                XCTAssertTrue(renderPublished(widget))
                let restored = try XCTUnwrap(widget.surface.textInputs.values.first {
                    widget.text.string($0.capture.content.help) == help
                })
                XCTAssertFalse(restored === input)
                XCTAssertNotEqual(restored.handle, input.handle)
                XCTAssertNil(input.view.superview)
                XCTAssertEqual(restored.text, saved)
                XCTAssertFalse(widget.surface.hasFocusedTextInput)
                XCTAssertEqual(globalNumber("lastOperation", widget), 0)
                XCTAssertTrue(events.isEmpty)
            }
        }
    }

    func testRootStringAndRootComponentStringListsUsePublicWritesAndPreserveEmptyEntries() throws {
        for root in [false, true] {
            let widget = try fixture()
            widget.render(ShellBarData())
            if root {
                widget.invoke(try action("Appearance settings", in: widget))
                widget.render(ShellBarData())
                let label = try textInput("Edit Label", in: widget)
                var event = ShellEvent(kind: .textCommit)
                event.text = "Asia/Tokyo"
                widget.invoke(label.content.inputCommitAction, event: event)
                XCTAssertEqual(globalNumber("lastOperation", widget), 6)
                XCTAssertTrue(globalBool("lastStringMatches", widget))
                XCTAssertTrue(globalBool("lastRootKeyMatches", widget))
                widget.render(ShellBarData())
            }
            let title = root ? "Aliases" : "Tags"
            widget.invoke(try action("Edit \(title) values", in: widget))
            widget.render(ShellBarData())
            let first = try textInput("Edit \(title) 1", in: widget)
            XCTAssertEqual(widget.text.string(first.content.text), "")
            let second = try textInput("Edit \(title) 2", in: widget)
            XCTAssertEqual(widget.text.string(second.content.text), "line\nbreak")
            var event = ShellEvent(kind: .textCommit)
            event.text = "Asia/Tokyo"
            widget.invoke(second.content.inputCommitAction, event: event)
            XCTAssertEqual(globalNumber("lastOperation", widget), root ? 6 : 5)
            XCTAssertTrue(globalBool("lastArrayMatches", widget))
            XCTAssertEqual(globalNumber("lastCount", widget), 2)
        }
    }

    func testTextAdmissionSchemaAndPersistenceFailuresUseExistingNotice() throws {
        let rejected = try fixture(reject: true)
        rejected.render(ShellBarData())
        var commit = ShellEvent(kind: .textCommit)
        commit.text = "Asia/Tokyo"
        rejected.invoke(try textInput("Edit Zone", in: rejected).content.inputCommitAction, event: commit)
        rejected.render(ShellBarData())
        XCTAssertTrue(rejected.strings().contains("Configuration queue is full"))
        for (value, message) in [
            (String(repeating: "x", count: 65), "Invalid option value"),
            ("Asia/Tokyo", "Disk is full")
        ] {
            let widget = try fixture()
            widget.render(ShellBarData())
            commit.text = value
            widget.invoke(try textInput("Edit Zone", in: widget).content.inputCommitAction, event: commit)
            widget.render(ShellBarData())
            XCTAssertTrue(widget.strings().contains("Saving…"))
            var writer = ShellValueWriter()
            writer.map(0)
            var error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_trigger(widget.instance, $0.baseAddress, $0.count, 25_000_000, &error, error.count)
            }, OMNI_OK)
            widget.render(ShellBarData())
            XCTAssertTrue(widget.strings().contains(message))
            XCTAssertFalse(widget.strings().contains("Saving…"))
        }
    }

    func testSuccessfulTextWriteClearsThePendingNoticeOnlyAfterCompletion() throws {
        let widget = try fixture(succeed: true)
        widget.render(ShellBarData())
        var commit = ShellEvent(kind: .textCommit)
        commit.text = "Asia/Tokyo"
        widget.invoke(try textInput("Edit Zone", in: widget).content.inputCommitAction, event: commit)
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Saving…"))
        var writer = ShellValueWriter()
        writer.map(0)
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_trigger(widget.instance, $0.baseAddress, $0.count, 25_000_000, &error, error.count)
        }, OMNI_OK)
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains("Saving…"))
        XCTAssertFalse(widget.strings().contains("Disk is full"))
    }

    func testStringListsRemainPagedAndBoundedAtTheSchemaMaximum() throws {
        let widget = try fixture(listCount: 256)
        widget.render(ShellBarData())
        widget.invoke(try action("Edit Tags values", in: widget))
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("1 / 22"))
        XCTAssertEqual(widget.tree().filter { $0.kind == .input }.count, 13)
        XCTAssertLessThan(widget.tree().count, 1024)
        let add = try XCTUnwrap(widget.tree().first { widget.text.string($0.content.help) == "Add Tags value" })
        XCTAssertEqual(add.content.action, 0)
        XCTAssertFalse(widget.tree().contains { widget.text.string($0.content.help) == "Edit Tags 13" })
    }

    private func textInput(_ help: String, in widget: ShellRenderedWidget) throws -> TreeNode {
        let input = try XCTUnwrap(
            widget.tree().first { $0.kind == .input && widget.text.string($0.content.help) == help },
            help
        )
        XCTAssertNotEqual(input.content.inputCommitAction, 0)
        XCTAssertNotEqual(input.content.inputCancelAction, 0)
        XCTAssertEqual(input.content.action, 0)
        return input
    }

    private func renderPublished(_ widget: ShellRenderedWidget) -> Bool {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 512)
        let status = omni_instance_render(widget.instance, OMNI_VIEW_BAR, 8_000_000, &stats, &error, error.count)
        XCTAssertEqual(
            status,
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        guard status == OMNI_OK, stats.changed != 0 else { return false }
        let output = widget.output()
        widget.text.ingest(wire: output)
        widget.surface.sequence += 1
        XCTAssertTrue(widget.surface.apply(output, text: widget.text))
        ShellLayerScene.engineQueue.sync {}
        return true
    }

    private func fixture(
        schema: Bool = true,
        reject: Bool = false,
        catalogCount: Int = 1,
        listCount: Int = 2,
        succeed: Bool = false
    ) throws -> ShellRenderedWidget {
        let folder = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake/lib/lake")
        let settings = try String(contentsOf: folder.appendingPathComponent("settings.luau"), encoding: .utf8)
        let modules = try ["motion", "preferences"].map { name in
            ShellWidgetSource.Module(
                path: "lib/lake/\(name).luau",
                source: try String(contentsOf: folder.appendingPathComponent("\(name).luau"), encoding: .utf8)
            )
        }
        let source = """
        local dependencies = { ["./motion"] = require("../lib/lake/motion"), ["./preferences"] = require("../lib/lake/preferences") }
        local current
        local pending
        local pendingError = "Disk is full"
        local realUI = ui
        local mockUI = {}
        for name, constructor in { box = realUI.box, row = realUI.row, column = realUI.column,
            stack = realUI.stack, text = realUI.text, symbol = realUI.symbol, input = realUI.input } do
            mockUI[name] = function(props)
                for _, key in { "onClick", "onKey", "onGesture", "onOutsidePress", "onCommit", "onCancel" } do
                    local handler = props[key]
                    if type(handler) == "function" then props[key] = function(_, event) handler(current, event) end end
                end
                return constructor(props)
            end
        end
        lastOperation = 0
        lastNumber = 0
        lastValueMatches = false
        lastIDMatches = false
        lastStringMatches = false
        lastArrayMatches = false
        lastRootKeyMatches = false
        lastCount = 0
        lastColorMatches = false
        lastTargetMatches = false
        didCloseSettings = false
        local function emit(operation, id, key, value, callback)
            lastOperation = operation
            lastColorMatches = key == "backgroundColor" and value == "#11223344"
            lastTargetMatches = key == "clickTarget" and value == "component:two"
            lastStringMatches = value == "Asia/Tokyo"
            lastArrayMatches = type(value) == "table" and value[1] == "" and value[2] == "Asia/Tokyo"
            lastRootKeyMatches = operation == 6 and (key == "label" or key == "aliases")
            lastCount = if type(value) == "table" then #value else 0
            pendingError = if type(value) == "string" and #value > 64 then "Invalid option value" else "Disk is full"
            lastNumber = if type(value) == "number" then value else 0
            lastIDMatches = id == "one" or (operation == 1 and id == "clock")
            lastValueMatches = value == true or value == "analog" or (type(value) == "table" and value[1] == "one:main")
            if \(reject ? "true" : "false") then return nil, "Configuration queue is full" end
            pending = callback
            return { cancel = function() end }
        end
        local mock = { components = {
            add = function(widget, options, cb) return emit(1, widget, nil, options, cb) end,
            remove = function(id, cb) return emit(2, id, nil, nil, cb) end,
            move = function(id, index, cb) return emit(3, id, nil, index, cb) end,
            enable = function(id, value, cb) return emit(4, id, nil, value, cb) end,
            set = function(id, key, value, cb) return emit(5, id, key, value, cb) end,
        }, config = { set = function(key, value, cb) return emit(6, nil, key, value, cb) end } }
        local function loadSettings()
            local ui = mockUI
            local omniwm = mock
            local require = function(name) return dependencies[name] end
            \(settings)
        end
        local settings = loadSettings()
        local tags = { "", "line\\nbreak" }
        for index = 3, \(listCount) do tags[index] = "Value " .. index end
        local options = {
            seconds = { type = "boolean", title = "Seconds", default = false },
            size = { type = "number", title = "Size", default = 12, min = 8, max = 20, step = 2 },
            face = { type = "choice", title = "Face", default = "digital", choices = { "digital", "analog" } },
            zone = { type = "string", title = "Zone", default = "UTC", maxLength = 64 },
            tags = { type = "strings", title = "Tags", default = tags, maxLength = 64 },
        }
        local data = { components = {
            { id = "one", widget = "clock", title = "Clock", enabled = true, options = { seconds = false, size = 12, face = "digital", zone = "UTC" } },
            { id = "two", widget = "clock", title = "Second clock", enabled = true, options = {} },
        }, catalog = { { widget = "clock", title = "Clock", icon = "clock", views = { "compact" }, options = options } },
            settings = { width = 520, radius = 28, hoverPreview = true, springBounce = 0.18 },
            settingsSchema = if \(schema ? "true" : "false") then {
                width = { type = "number", title = "Expanded width", default = 520, min = 380, max = 640, step = 20 },
                backgroundColor = { type = "string", title = "Solid background color", default = "#000000", maxLength = 9 },
                clickTarget = { type = "string", title = "Click target", default = "toggle", maxLength = 128 },
                hoverPreview = { type = "boolean", title = "Hover preview", default = true },
                springBounce = { type = "number", title = "Expansion bounce", default = 0.18, min = 0, max = 0.60, step = 0.02 },
                label = { type = "string", title = "Label", default = "Island", maxLength = 64 },
                aliases = { type = "strings", title = "Aliases", default = tags, maxLength = 64 },
            } else nil }
        for index = 2, \(catalogCount) do
            data.catalog[index] = { widget = "component-" .. index, title = "Component " .. index,
                icon = "square.grid.2x2", views = { "compact" }, options = {} }
        end
        function render(ctx)
            current = { state = ctx.state, data = data }
            return settings.render(current, { size = { w = 760, h = 360 }, notch = { h = 32 } }, function(root)
                root.state.settingsOpen = false
                didCloseSettings = true
            end)
        end
        function trigger()
            if pending then local cb = pending; pending = nil; cb({ ok = \(succeed ? "true" : "false"), error = pendingError }) end
        end
        """
        return try ShellRenderedWidget(
            name: "settings",
            source: source,
            modules: modules,
            chunk: "@widgets/settings-test/init.luau"
        )
    }

    private func action(_ help: String, in widget: ShellRenderedWidget) throws -> UInt32 {
        let node = try XCTUnwrap(widget.tree().first { widget.text.string($0.content.help) == help }, help)
        XCTAssertNotEqual(node.content.action, 0, help)
        return node.content.action
    }

    private func globalNumber(_ name: String, _ widget: ShellRenderedWidget) -> Double {
        var value = 0.0
        XCTAssertEqual(omni_vm_global_number(widget.vm, name, &value), OMNI_OK)
        return value
    }

    private func globalBool(_ name: String, _ widget: ShellRenderedWidget) -> Bool {
        var value = false
        XCTAssertEqual(omni_vm_global_boolean(widget.vm, name, &value), OMNI_OK)
        return value
    }
}
