// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellScriptHostTests {
    private func setSelectionData(
        _ script: Script,
        key: String,
        _ write: (inout ShellValueWriter) -> Void
    ) {
        var writer = ShellValueWriter()
        write(&writer)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(script.instance, key, $0.baseAddress, $0.count)
        }, OMNI_OK)
    }

    private func setSelectionMedia(_ script: Script, title: String, position: Double, artist: String = "same") {
        setSelectionData(script, key: "media") { writer in
            writer.map(3)
            writer.key("title")
            writer.string(title)
            writer.key("position")
            writer.number(position)
            writer.key("artist")
            writer.string(artist)
        }
    }

    func testSelectionsSkipSiblingChangesAndKeepTheRenderedBaseline() throws {
        let script = try Script("""
        local function title(ctx)
            return ctx.select("media", "title")
        end
        function render(ctx)
            return ui.text{ text = title(ctx) }
        end
        """)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, 0))
        setSelectionMedia(script, title: "same", position: 1)
        let first = script.render()
        XCTAssertEqual(first.status, OMNI_OK, script.message)
        XCTAssertEqual(first.stats.deps, ShellDataKey.media.bit)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.cpu.bit))
        for position in 2 ... 5 {
            setSelectionMedia(script, title: "same", position: Double(position))
            omni_vm_collect(script.vm)
            XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        }
        setSelectionMedia(script, title: "changed", position: 5)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
    }

    func testSelectionsFollowNilAndIntegerArrayPaths() throws {
        let script = try Script("""
        function render(ctx)
            return ui.text{ text = tostring(ctx.select("bluetooth", "devices", 1, "battery")) }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        setSelectionData(script, key: "bluetooth") { writer in
            writer.map(1)
            writer.key("devices")
            writer.array(0)
        }
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.bluetooth.bit))
        for battery in [50.0, 75.0] {
            setSelectionData(script, key: "bluetooth") { writer in
                writer.map(1)
                writer.key("devices")
                writer.array(1)
                writer.map(1)
                writer.key("battery")
                writer.number(battery)
            }
            XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.bluetooth.bit))
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        }
        setSelectionData(script, key: "bluetooth") { $0.null() }
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.bluetooth.bit))
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.bluetooth.bit))
    }

    func testSelectionBranchesRefreshEvenWhenThePublishedTreeIsUnchanged() throws {
        let script = try Script("""
        function render(ctx)
            local field = ctx.select("vars", "field") or "title"
            return ui.text{ text = ctx.select("media", field) }
        end
        """)
        setSelectionMedia(script, title: "same", position: 1)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        setSelectionData(script, key: "vars") { writer in
            writer.map(1)
            writer.key("field")
            writer.string("artist")
        }
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.vars.bit))
        let changedBranch = script.render()
        XCTAssertEqual(changedBranch.status, OMNI_OK, script.message)
        XCTAssertEqual(changedBranch.stats.changed, 0)
        setSelectionMedia(script, title: "ignored", position: 1)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        setSelectionMedia(script, title: "ignored", position: 1, artist: "changed")
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
    }

    func testBroadDataReadsOverrideSelectionsInEitherOrder() throws {
        for reads in [
            "local data = ctx.data.media; local title = ctx.select(\"media\", \"title\")",
            "local title = ctx.select(\"media\", \"title\"); local data = ctx.data.media"
        ] {
            let script = try Script("""
            function render(ctx)
                \(reads)
                return ui.text{ text = title }
            end
            """)
            setSelectionMedia(script, title: "same", position: 1)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            setSelectionMedia(script, title: "same", position: 2)
            XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        }
    }

    func testBarAndPopoutKeepIndependentSelections() throws {
        let script = try Script("""
        function render(ctx)
            return ui.text{ text = ctx.select("media", "title") }
        end
        function popout(ctx)
            return ui.text{ text = tostring(ctx.select("media", "position")) }
        end
        """)
        setSelectionMedia(script, title: "same", position: 1)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).status, OMNI_OK, script.message)
        setSelectionMedia(script, title: "same", position: 2)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_POPOUT, ShellDataKey.media.bit))
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).status, OMNI_OK, script.message)
        setSelectionMedia(script, title: "changed", position: 2)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_POPOUT, ShellDataKey.media.bit))
    }

    func testSelectedTablesKeepTheirIdentityIterationAndRetainedSnapshot() throws {
        let script = try Script("""
        function render(ctx)
            local media = ctx.select("media")
            local titles = ctx.select("media", "titles")
            assert(media.titles == titles)
            assert(table.isfrozen(media) and table.isfrozen(titles))
            assert(rawget(media, "titles") == titles)
            assert(#titles == 2 and table.clone(titles)[2] == "second")
            local total = 0
            for _, title in ipairs(titles) do total += #title end
            assert(total > 0)
            assert(next(media) == "titles")
            ctx.state.old = ctx.state.old or media
            return ui.text{ text = ctx.state.old.titles[1] .. ":" .. titles[1] }
        end
        """)
        for title in ["first", "changed"] {
            setSelectionData(script, key: "media") { writer in
                writer.map(1)
                writer.key("titles")
                writer.array(2)
                writer.string(title)
                writer.string("second")
            }
            XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        }
        let nodes = decode(script.output)
        XCTAssertEqual(strings(script.output).string(nodes[0].content.text), "first:changed")
    }

    func testSelectionFailuresDiscardAndStringResetRequireANewRender() throws {
        let script = try Script("""
        function render(ctx)
            local title = ctx.select("media", "title")
            if title == "fail" then error("broken") end
            return ui.text{ text = title }
        end
        """)
        setSelectionMedia(script, title: "same", position: 1)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        omni_instance_discard_output(script.instance, OMNI_VIEW_BAR)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, 0))
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        omni_vm_reset_strings(script.vm)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, 0))
        setSelectionMedia(script, title: "fail", position: 1)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, 0))
        setSelectionMedia(script, title: "recovered", position: 1)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertFalse(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
    }

    func testSelectionsValidatePathsAndBoundDependencyStorage() throws {
        let tooDeep = Array(repeating: "\"field\"", count: 17).joined(separator: ", ")
        for arguments in ["", "1", "\"unknown\"", "\"media\", true", "\"media\", 1.5", "\"media\", \(tooDeep)"] {
            let script = try Script("""
            function render(ctx)
                local value = ctx.select(\(arguments))
                return ui.box{}
            end
            """)
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
            XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, 0))
        }
        let script = try Script("""
        function render(ctx)
            for index = 1, 300 do
                local value = ctx.select("media", "missing" .. index)
            end
            return ui.box{}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.media.bit))
    }

    func testTimeReadsStillInvalidateAlongsideSelections() throws {
        let script = try Script("""
        function render(ctx)
            local time = os.time()
            return ui.text{ text = ctx.select("media", "title") }
        end
        """)
        setSelectionMedia(script, title: "same", position: 1)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertTrue(omni_instance_needs_render(script.instance, OMNI_VIEW_BAR, ShellDataKey.seconds.bit))
    }

    func testSelectedReadersCannotReadAnotherInstancesData() throws {
        let script = try Script("""
        local selected
        function render(ctx)
            if selected then
                return ui.text{ text = selected("media", "title") }
            end
            selected = ctx.select
            return ui.box{}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let other = try XCTUnwrap(omni_instance_create(script.vm))
        defer { omni_instance_destroy(other) }
        var stats = omni_render_stats()
        XCTAssertEqual(
            omni_instance_render(other, OMNI_VIEW_BAR, 8_000_000, &stats, &script.error, script.error.count),
            OMNI_ERR_RUNTIME
        )
        XCTAssertTrue(script.message.contains("own instance"))
        XCTAssertTrue(omni_instance_needs_render(other, OMNI_VIEW_BAR, 0))
    }
}
