// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

final class ShellScriptHostTests: XCTestCase {
    final class Script {
        let vm: OpaquePointer
        let instance: OpaquePointer
        var error = [CChar](repeating: 0, count: 512)

        init(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20), file: file, line: line)
            let status = omni_vm_load(vm, "=test", source, source.utf8.count, 100_000_000, &error, error.count)
            guard status == OMNI_OK else {
                _ = omni_vm_destroy(vm)
                throw LoadFailure(
                    status: status,
                    message: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                )
            }
            self.vm = vm
            instance = try XCTUnwrap(omni_instance_create(vm), file: file, line: line)
        }

        deinit {
            omni_instance_destroy(instance)
            _ = omni_vm_destroy(vm)
        }

        func render(
            _ view: omni_view = OMNI_VIEW_BAR,
            budget: UInt64 = 8_000_000
        ) -> (status: omni_status, stats: omni_render_stats) {
            var stats = omni_render_stats()
            let status = omni_instance_render(instance, view, budget, &stats, &error, error.count)
            return (status, stats)
        }

        func invoke(_ action: UInt32, in view: omni_view = OMNI_VIEW_BAR, event: [UInt8] = []) -> omni_status {
            event.withUnsafeBufferPointer { bytes in
                omni_instance_invoke(
                    instance,
                    view,
                    action,
                    0,
                    bytes.baseAddress,
                    bytes.count,
                    25_000_000,
                    &error,
                    error.count
                )
            }
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var output: [UInt8] {
            output(OMNI_VIEW_BAR)
        }

        func output(_ view: omni_view) -> [UInt8] {
            var size = 0
            guard let bytes = omni_instance_output(instance, view, &size) else { return [] }
            return Array(UnsafeBufferPointer(start: bytes, count: size))
        }
    }

    struct LoadFailure: Error {
        let status: omni_status
        let message: String
    }

    func decode(_ output: [UInt8], capacity: Int = 64) -> [TreeNode] {
        let nodes = UnsafeMutablePointer<TreeNode>.allocate(capacity: capacity)
        defer { nodes.deallocate() }
        nodes.initialize(repeating: TreeNode(kind: .group, subtreeEnd: 1), count: capacity)
        let count = output.withUnsafeBytes { ShellWireDecoder.decode(
            $0.baseAddress!,
            length: $0.count,
            into: nodes,
            capacity: capacity
        ) }
        return Array(UnsafeBufferPointer(start: nodes, count: count))
    }

    func strings(_ output: [UInt8]) -> ShellTextStore {
        let store = ShellTextStore()
        store.ingest(wire: output)
        return store
    }

    func testRenderEncodesTreeAndStrings() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{ gap = 4,
                ui.symbol{ name = "cpu" },
                ui.text{ text = string.format("%d%%", ctx.data.cpu), reserve = "100%", style = "mono" },
                ui.progress{ value = ctx.data.cpu / 100 },
            }
        end
        """)
        XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", 42), OMNI_OK)
        let result = script.render()
        XCTAssertEqual(result.status, OMNI_OK, script.message)
        XCTAssertEqual(result.stats.changed, 1)
        let nodes = decode(script.output)
        XCTAssertEqual(nodes.map(\.kind), [.group, .symbol, .label, .progress])
        XCTAssertEqual(nodes[0].subtreeEnd, 4)
        XCTAssertEqual(nodes[0].layout.gap, 4)
        XCTAssertEqual(nodes[1].layout.width, ShellWireDecoder.symbolSize)
        XCTAssertEqual(nodes[2].content.style, 2)
        XCTAssertEqual(nodes[3].content.value, 420)
        let store = strings(script.output)
        XCTAssertEqual(store.string(nodes[1].content.text), "cpu")
        XCTAssertEqual(store.string(nodes[2].content.text), "42%")
        XCTAssertEqual(store.string(nodes[2].content.reserve), "100%")
    }

    func testGeometryNumbersStayFiniteThroughLayout() throws {
        let measure: MeasureText = { _, _, _, _, _, width, height in
            width.pointee = 10
            height.pointee = 10
        }
        func frames(_ nodes: [TreeNode]) -> [Rect] {
            var core = SurfaceCore(capacity: 16)
            var patches = PatchBuffer(capacity: 64)
            nodes.withUnsafeBufferPointer { core.apply($0, measure: measure, context: nil, into: &patches) }
            return (0 ..< patches.count).compactMap { index in
                guard case let .setFrame(_, rect) = patches.op(at: index) else { return nil }
                return rect
            }
        }
        func bounded(_ rects: [Rect]) -> Bool {
            rects.allSatisfy { rect in
                [rect.x, rect.y, rect.width, rect.height].allSatisfy { $0.isFinite && abs($0) < 1e12 }
            }
        }

        let huge = try Script("""
        function render(ctx)
            return ui.row{ gap = 1e300, pad = -math.huge,
                ui.column{ ui.box{ w = 1e300, h = 3e38 }, ui.box{ w = 10, h = 3e38 } },
                ui.shader{ source = "x", w = 1e19, values = { 1e300, -1e300, 0/0, 5 } } }
        end
        """)
        XCTAssertEqual(huge.render().status, OMNI_OK, huge.message)
        let nodes = decode(huge.output)
        XCTAssertEqual(nodes[0].layout.gap, 1e6)
        XCTAssertEqual(nodes[0].layout.padding, 0)
        XCTAssertEqual(nodes[2].layout.width, 1e6)
        XCTAssertEqual(nodes[2].layout.height, 1e6)
        XCTAssertEqual(nodes[4].layout.width, 1e6)
        XCTAssertEqual(nodes[4].content.params, SIMD4(1e6, -1e6, 0, 5))
        XCTAssertTrue(bounded(frames(nodes)))

        let grows = try Script("""
        function render(ctx)
            return ui.row{ w = 100,
                ui.box{ w = 10, grow = -1e6 }, ui.box{ w = 10, grow = 1e6 }, ui.box{ w = 10, grow = 1e-45 } }
        end
        """)
        XCTAssertEqual(grows.render().status, OMNI_OK, grows.message)
        let growNodes = decode(grows.output)
        XCTAssertEqual(growNodes[1].layout.grow, 0)
        XCTAssertTrue(bounded(frames(growNodes)))
    }

    func testAFailedRenderReportsTheDataItRead() throws {
        let script = try Script("function render(ctx) return ui.box{ w = ctx.data.network.down, h = 10 } end")
        let result = script.render()
        XCTAssertEqual(result.status, OMNI_ERR_RUNTIME)
        XCTAssertEqual(result.stats.deps, ShellDataKey.network.bit)
    }

    func testImagesTakePlayingAndSpeed() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.image{ image = "assets/cat.gif", playing = false, speed = 2 },
                ui.image{ image = "assets/cat.gif", align = "trailing" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        XCTAssertTrue(nodes[1].paint.loopPaused)
        XCTAssertEqual(nodes[1].paint.speed, 2)
        XCTAssertFalse(nodes[2].paint.loopPaused)
        XCTAssertEqual(nodes[2].paint.speed, 1)
        XCTAssertEqual(nodes[2].layout.align, 2)
    }

    func testAudioShadersKeepTheSpectrumRunningWithoutReadingIt() throws {
        let script = try Script("""
        function render(ctx)
            return ui.stack{ ui.shader{ source = "bars.metal", audio = true }, ui.shader{ source = "glow.metal" } }
        end
        """)
        let result = script.render()
        XCTAssertEqual(result.status, OMNI_OK, script.message)
        XCTAssertEqual(result.stats.deps, 0)
        XCTAssertEqual(ShellWidgetDelivery.Tree(nodes: script.output).demand, ShellDataKey.spectrum.bit)
        let nodes = decode(script.output)
        XCTAssertTrue(nodes[1].content.audio)
        XCTAssertFalse(nodes[2].content.audio)

        let plain = try Script("function render(ctx) return ui.shader{ source = \"glow.metal\", audio = false } end")
        let plainResult = plain.render()
        XCTAssertEqual(plainResult.status, OMNI_OK, plain.message)
        XCTAssertEqual(plainResult.stats.deps, 0)
        XCTAssertEqual(ShellWidgetDelivery.Tree(nodes: plain.output).demand, 0)

        let reader = try Script("function render(ctx) return ui.text{ text = tostring(ctx.data.spectrum) } end")
        XCTAssertEqual(reader.render().stats.deps, ShellDataKey.spectrum.bit)
        XCTAssertEqual(ShellWidgetDelivery.Tree(nodes: reader.output).demand, ShellDataKey.spectrum.bit)
    }

    func testIdenticalRerenderRunsItsNewestHandlers() throws {
        let script = try Script("""
        function render(ctx)
            local cpu = ctx.data.cpu
            return ui.box{ onClick = function(ctx) ctx.state.picked = cpu end,
                ui.text{ text = tostring(ctx.state.picked) } }
        end
        """)
        let setCPU = { (value: Double) in
            var writer = ShellValueWriter()
            writer.number(value)
            XCTAssertEqual(self.setValue(script, "cpu", writer.bytes), OMNI_OK)
        }
        setCPU(1)
        XCTAssertEqual(script.render().stats.changed, 1)
        let action = decode(script.output)[0].content.action
        setCPU(2)
        XCTAssertEqual(script.render().stats.changed, 0)
        XCTAssertEqual(script.invoke(action), OMNI_OK, script.message)
        XCTAssertEqual(script.render().stats.changed, 1)
        let nodes = decode(script.output)
        XCTAssertEqual(strings(script.output).string(nodes[1].content.text), "2")
    }

    func testFormatUsesTheHostFormatter() throws {
        let script = try Script("""
        function render(ctx)
            return ui.column{
                ui.text{ text = ctx.format.percent(0.426) },
                ui.text{ text = ctx.format.percent(0.426, 1) },
                ui.text{ text = ctx.format.bytes(17179869184) },
                ui.text{ text = ctx.format.bytes(994662584320, "file") },
                ui.text{ text = ctx.format.number(1234.5678, 2) },
                ui.text{ text = ctx.format.number(1.5, 0/0) },
            }
        end
        """)
        let result = script.render()
        XCTAssertEqual(result.status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        let store = strings(script.output)
        XCTAssertEqual(nodes.dropFirst().map { store.string($0.content.text) }, [
            ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, 0.426, digits: 0),
            ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, 0.426, digits: 1),
            ByteCountFormatter.string(fromByteCount: 17_179_869_184, countStyle: .memory),
            ByteCountFormatter.string(fromByteCount: 994_662_584_320, countStyle: .file),
            ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 1234.5678, digits: 2),
            ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 1.5, digits: 0)
        ])
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, 0.426, digits: 0, locale: english), "43%")
        XCTAssertEqual(ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, 0.426, digits: 1, locale: english), "42.6%")
        XCTAssertEqual(
            ShellFormatter.string(kind: OMNI_FORMAT_NUMBER, 1234.5678, digits: 2, locale: english),
            "1,234.57"
        )
        XCTAssertEqual(ShellFormatter.string(kind: OMNI_FORMAT_MEMORY, .infinity, digits: 0), "—")
    }

    func testDatesFormatInAnyZoneAndOffsetsFollowDaylightSaving() throws {
        let script = try Script("""
        function render(ctx)
            return ui.column{
                ui.text{ text = ctx.format.date(1783339200, "yyyyMMddHH", "Asia/Tokyo") },
                ui.text{ text = tostring(ctx.format.offset(1783339200, "Europe/London")) },
                ui.text{ text = tostring(ctx.format.offset(1767268800, "Europe/London")) },
                ui.text{ text = tostring(ctx.format.date(0, "jmm", "Mars/Olympus")) },
                ui.text{ text = tostring(ctx.format.offset(0, "Mars/Olympus")) },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let store = strings(script.output)
        XCTAssertEqual(decode(script.output).dropFirst().map { store.string($0.content.text) }, [
            ShellFormatter.date(1_783_339_200, template: "yyyyMMddHH", zone: "Asia/Tokyo"),
            "3600", "0", "nil", "nil"
        ])
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(
            ShellFormatter.date(1_783_339_200, template: "jmm", zone: "Asia/Tokyo", locale: english),
            "9:00\u{202F}PM"
        )
        XCTAssertEqual(ShellFormatter.date(1_783_339_200, template: "jmm", zone: "Asia/Tokyo", locale: german), "21:00")
        XCTAssertEqual(ShellFormatter.date(0, template: "yyyy", zone: "UTC", locale: english), "1970")
        XCTAssertEqual(
            ShellFormatter.offset(0, zone: nil),
            TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 0))
        )
        XCTAssertNil(ShellFormatter.date(0, template: "", zone: nil))
    }

    func testFormatRejectsUnknownByteStylesAndStaysReadOnly() throws {
        let bytes = try Script("function render(ctx) return ui.text{ text = ctx.format.bytes(1, \"disk\") } end")
        XCTAssertNotEqual(bytes.render().status, OMNI_OK)
        XCTAssertTrue(bytes.message.contains("expected \"memory\" or \"file\""), bytes.message)

        let assign = try Script("function render(ctx) ctx.format.percent = nil return ui.text{ text = \"x\" } end")
        XCTAssertNotEqual(assign.render().status, OMNI_OK)
    }

    func testBundledSystemStatsPopoutShowsTheNativeDashboard() throws {
        let url = try XCTUnwrap(ShellDefaults.bundledFile("widgets/system-stats/init.luau"))
        let script = try Script(String(contentsOf: url, encoding: .utf8))
        var interval = 0.0
        XCTAssertEqual(omni_vm_global_number(script.vm, "interval", &interval), OMNI_OK)
        XCTAssertEqual(interval, 1)
        let system = ShellSystemData(
            memoryUsed: 8 << 30,
            memoryTotal: 16 << 30,
            pressure: .warning,
            diskUsed: 400_000_000_000,
            diskTotal: 1_000_000_000_000,
            uptime: 93784,
            host: SystemStatsHostInfo(
                chip: "Apple M9",
                modelIdentifier: "Mac99,1",
                osVersion: "Version 27.2",
                hostname: "studio"
            ),
            displays: [ShellSystemDisplay(width: 5120, height: 2880, refresh: 120)]
        )
        var writer = ShellValueWriter()
        system.write(into: &writer)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(script.instance, "system", $0.baseAddress, $0.count)
        }, OMNI_OK)
        var null = ShellValueWriter()
        null.null()
        XCTAssertEqual(null.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(script.instance, "gpu", $0.baseAddress, $0.count)
        }, OMNI_OK)
        XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", 42), OMNI_OK)

        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).status, OMNI_OK, script.message)
        let output = script.output(OMNI_VIEW_POPOUT)
        let nodes = decode(output, capacity: 256)
        let store = strings(output)
        let root = try XCTUnwrap(nodes.first)
        XCTAssertEqual(root.layout.width, 340)
        XCTAssertEqual(root.layout.height, 300)
        XCTAssertEqual(root.paint.material, UInt8(OMNI_MATERIAL_GLASS))
        XCTAssertEqual(root.paint.cornerRadius, 14)
        let l10n = { (key: String, arguments: [ShellLocalizer.Argument]) in ShellLocalizer.string(key, arguments) }
        let percent = { ShellFormatter.string(kind: OMNI_FORMAT_PERCENT, $0, digits: 0) }
        let memory = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
        let file = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let labels = nodes.filter { $0.kind == .label }
        XCTAssertEqual(labels.map { store.string($0.content.text) }, [
            "studio",
            "Apple M9",
            l10n("%lldd %lldh %lldm", [.number(1), .number(2), .number(3)]),
            l10n("CPU", []), percent(0.42), l10n("Total processor", []),
            l10n("GPU", []), "—", l10n("Unavailable", []),
            l10n("Memory", []), percent(0.5), "\(memory(8 << 30)) / \(memory(16 << 30)) · \(l10n("Warning", []))",
            l10n("Disk", []), percent(0.4),
            l10n("%@ free", [.text(file(600_000_000_000))]),
            "Mac99,1",
            "Version 27.2  " + l10n("%@ @ %lld Hz", [.text("5120×2880"), .number(120)])
        ])
        XCTAssertEqual(labels.last?.content.lines, 2)
        let meters = nodes.filter { $0.kind == .shader }
        XCTAssertEqual(meters.map { $0.content.params.x }, [0, 1, 2, 3])
        for (meter, fraction) in zip(meters, [Float(0.42), 0, 0.5, 0.4]) {
            XCTAssertEqual(meter.layout.width, fraction * 129, accuracy: 0.01)
        }
        let titles = Set(["CPU", "GPU", "Memory", "Disk"].map { l10n($0, []) })
        let titleWidths = labels.filter { titles.contains(store.string($0.content.text)) }.map(\.content.maxWidth)
        XCTAssertEqual(titleWidths, [61, 61, 61, 61])
    }

    func testUnchangedRenderDoesNotPublish() throws {
        let script = try Script("function render(ctx) return ui.text{ text = ctx.data.clock } end")
        _ = omni_instance_set_string(script.instance, "clock", "12:00", 5)
        XCTAssertEqual(script.render().stats.changed, 1)
        XCTAssertEqual(script.render().stats.changed, 0)
        _ = omni_instance_set_string(script.instance, "clock", "12:01", 5)
        let changed = script.render().stats
        XCTAssertEqual(changed.changed, 1)
        XCTAssertEqual(changed.new_strings, 1)
    }

    func testCompileErrorIsReported() {
        XCTAssertThrowsError(try Script("function (")) { error in
            XCTAssertEqual((error as? LoadFailure)?.status, OMNI_ERR_COMPILE)
        }
    }

    func testRunawayRenderTimesOutAndPcallCannotSwallowIt() throws {
        let script = try Script("""
        function render(ctx)
            while true do
                pcall(function() while true do end end)
            end
        end
        """)
        let start = ContinuousClock.now
        let result = script.render(budget: 5_000_000)
        XCTAssertEqual(result.status, OMNI_ERR_TIMEOUT, script.message)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testMemoryCapIsEnforced() throws {
        let script = try Script("""
        function render(ctx)
            local parts = {}
            for i = 1, 1e8 do parts[i] = string.rep("x", 1024) .. i end
            return ui.text{ text = "never" }
        end
        """)
        let status = script.render(budget: 2_000_000_000).status
        XCTAssertEqual(status, OMNI_ERR_MEMORY, script.message)
    }

    func testSandboxRejectsWritesToSharedLibraries() throws {
        let script = try Script("function render(ctx) ui.text = nil return ui.row{} end")
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("readonly"), script.message)
    }

    func testContextDataIsReadOnly() throws {
        let script = try Script("function render(ctx) ctx.data.cpu = 1 return ui.row{} end")
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("read-only"), script.message)
    }

    func testEncodeWorkIsCapped() throws {
        let script = try Script("""
        function render(ctx)
            local leaf = table.create(65536, 0)
            local root = ui.row{}
            for i = 1, 1024 do root[i] = leaf end
            return root
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("encode exceeded"), script.message)
    }

    func testClickHandlerUpdatesStateAndCommandIsInterned() throws {
        let script = try Script("""
        function render(ctx)
            local count = ctx.state.count or 0
            return ui.row{
                ui.box{ hover = 0xFFFFFF22, onClick = function(ctx) ctx.state.count = count + 1 end,
                    ui.text{ text = tostring(count) } },
                ui.box{ onClick = "switch-workspace 2", ui.text{ text = "two" } },
                ui.box{ onClick = function() error("boom") end },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        let handler = nodes[1].content.action
        XCTAssertNotEqual(handler & OMNI_ACTION_HANDLER, 0)
        XCTAssertEqual(nodes[1].content.hover, Color(packed: 0xFFFF_FF22))
        XCTAssertEqual(strings(script.output).string(nodes[3].content.action), "switch-workspace 2")

        XCTAssertEqual(script.invoke(handler), OMNI_OK)
        XCTAssertEqual(script.render().stats.changed, 1)
        let rerendered = decode(script.output)
        XCTAssertEqual(strings(script.output).string(rerendered[2].content.text), "1")

        let failing = rerendered[5].content.action
        XCTAssertEqual(script.invoke(failing), OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("boom"), script.message)
        let stale = OMNI_ACTION_HANDLER | 99
        XCTAssertEqual(script.invoke(stale), OMNI_ERR_STALE_ACTION)
    }

    func testHandlersReceiveTheClickEvent() throws {
        let script = try Script("""
        function render(ctx)
            return ui.box{
                onClick = function(ctx, event)
                    ctx.state.seen = event.button .. tostring(event.shift) .. tostring(event.command)
                end,
                onRightClick = "switch-workspace 3",
                ui.text{ text = ctx.state.seen or "none" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        XCTAssertEqual(strings(script.output).string(nodes[0].content.secondaryAction), "switch-workspace 3")
        XCTAssertEqual(nodes[0].content.scrollAction, 0)

        let event = ShellEvent(button: .middle, shift: true, command: false)
        XCTAssertEqual(script.invoke(nodes[0].content.action, event: event.bytes), OMNI_OK, script.message)
        XCTAssertEqual(script.render().status, OMNI_OK)
        XCTAssertEqual(strings(script.output).string(decode(script.output)[1].content.text), "middletruefalse")
    }

    func testTextSizeWeightAndStyleCombineInAnyOrder() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.text{ text = "a", style = "mono", size = 15, weight = "semibold", maxWidth = 30 },
                ui.text{ maxWidth = 30, weight = "semibold", size = 15, style = "mono", text = "a" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        let expected = UInt32(2 | (6 << OMNI_STYLE_WEIGHT_SHIFT) | (1500 << OMNI_STYLE_SIZE_SHIFT))
        XCTAssertEqual(nodes[1].content.style, expected)
        XCTAssertEqual(nodes[2].content.style, expected)
        XCTAssertEqual(nodes[1].content.maxWidth, 30)

        let font = ShellTextStyle.font(for: expected)
        XCTAssertEqual(CTFontGetSize(font), 15)
        XCTAssertEqual(CTFontGetSize(ShellTextStyle.font(for: 0)), 12)
        XCTAssertEqual(CTFontGetSize(ShellTextStyle.font(for: 3)), 10)
        XCTAssertEqual(ShellTextStyle.symbolSize(for: 0), ShellWireDecoder.symbolSize)
        XCTAssertEqual(ShellTextStyle.symbolSize(for: expected), 15)
    }

    func testTextChoosesABundledFontAndIconsAreLigatures() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.text{ text = "home", font = "symbols", filled = true, size = 18 },
                ui.text{ text = "home", font = "symbols", size = 18 },
                ui.text{ text = "12", font = "rubik", weight = "semibold" },
                ui.text{ text = "Hi", font = "sans" },
                ui.text{ text = "Hi", font = "nowhere" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        let filled = nodes[1].content.style
        let outline = nodes[2].content.style
        XCTAssertEqual(
            filled,
            UInt32(3 << OMNI_STYLE_FONT_SHIFT) | OMNI_STYLE_FILLED | UInt32(1800 << OMNI_STYLE_SIZE_SHIFT)
        )
        XCTAssertEqual(outline, UInt32(3 << OMNI_STYLE_FONT_SHIFT) | UInt32(1800 << OMNI_STYLE_SIZE_SHIFT))
        XCTAssertEqual(nodes[5].content.style, 0)

        func glyphs(_ style: UInt32) -> [CGGlyph] {
            let font = ShellTextStyle.font(for: style)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "home",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            ))
            return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { run in
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                return glyphs
            }
        }
        XCTAssertEqual(glyphs(filled).count, 1)
        XCTAssertEqual(glyphs(0).count, 4)
        let paths = [filled, outline].map { style in
            CTFontCreatePathForGlyph(ShellTextStyle.font(for: style), glyphs(style)[0], nil)
        }
        XCTAssertNotNil(paths[0])
        XCTAssertNotEqual(paths[0], paths[1])
        XCTAssertEqual(CTFontCopyFamilyName(ShellTextStyle.font(for: nodes[3].content.style)) as String, "Rubik")
        XCTAssertEqual(
            CTFontCopyFamilyName(ShellTextStyle.font(for: nodes[4].content.style)) as String,
            "Google Sans Flex"
        )
    }

    func testAnimateAndEnterTakeNamedOrCustomCurves() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.box{ w = 1, h = 1, animate = "spatial" },
                ui.box{ w = 1, h = 1, animate = { duration = 0.3, curve = { 0.2, 0, 0, 1 } } },
                ui.box{ w = 1, h = 1, animate = "smooth", enter = { opacity = 0, curve = "emphasized", stretch = 0.1 } },
                ui.box{ w = 1, h = 1, animate = 0.25 },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        XCTAssertEqual(nodes[1].content.motion, 54)
        XCTAssertEqual(nodes[1].content.motionCurve, 13)
        XCTAssertEqual(nodes[2].content.motion, 34)
        XCTAssertEqual(nodes[2].content.motionCurve, UInt8(OMNI_CURVE_CUSTOM))
        XCTAssertEqual(strings(script.output).string(nodes[2].content.motionCurveRef), "0.2,0,0,1")
        XCTAssertEqual(nodes[3].content.motion, 3)
        XCTAssertEqual(nodes[3].content.motionCurve, 0)
        XCTAssertEqual(nodes[3].paint.enter.curve, 9)
        XCTAssertEqual(nodes[3].paint.enter.stretch, 0.1)
        XCTAssertEqual(nodes[1].paint.enter.stretch, 0)
        XCTAssertEqual(nodes[4].content.motion, 29)
        XCTAssertEqual(nodes[4].content.motionCurve, 0)

        let broken = try Script("""
        function render(ctx) return ui.box{ w = 1, h = 1, animate = { curve = { 1, 2, 3 } } } end
        """)
        XCTAssertNotEqual(broken.render().status, OMNI_OK)
        XCTAssertTrue(broken.message.contains("6 numbers per segment"), broken.message)
    }

    func testElementsRotateLoopAndTrail() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.text{ text = "Title", rotate = 90 },
                ui.text{ text = "Tilt", rotate = 45 },
                ui.box{ w = 1, h = 1, trail = true, loop = { rotate = { 0, 360, 23.5 }, dx = { -10, 10, 4 }, paused = true } },
                ui.box{ w = 1, h = 1, trail = true, align = "bottomTrailing", loop = { dx = { 0, 1, 1 }, paused = true } },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        XCTAssertEqual(nodes[1].paint.rotate, 90)
        XCTAssertNotEqual(nodes[1].content.style & OMNI_STYLE_QUARTER, 0)
        XCTAssertEqual(nodes[2].content.style & OMNI_STYLE_QUARTER, 0)
        XCTAssertTrue(nodes[3].content.trail)
        XCTAssertFalse(nodes[1].content.trail)
        XCTAssertTrue(nodes[3].paint.loopPaused)
        XCTAssertEqual(nodes[3].layout.align, 0)
        XCTAssertEqual(nodes[4].layout.align, 10)
        XCTAssertTrue(nodes[4].content.trail)
        XCTAssertTrue(nodes[4].paint.loopPaused)
        XCTAssertEqual(strings(script.output).string(nodes[3].paint.loop), "dx -10 10 4;rotate 0 360 23.5")

        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let upright = text.measureMiss(nodes[1].content.text, style: 0)
        let turned = text.measureMiss(nodes[1].content.text, style: nodes[1].content.style)
        XCTAssertEqual(turned.width, upright.height)
        XCTAssertEqual(turned.height, upright.width)

        let broken = try Script("""
        function render(ctx) return ui.box{ w = 1, h = 1, loop = { rotate = { 0, 360 } } } end
        """)
        XCTAssertNotEqual(broken.render().status, OMNI_OK)
        XCTAssertTrue(broken.message.contains("loop.rotate must be"), broken.message)

        let endless = try Script("""
        function render(ctx) return ui.box{ w = 1, h = 1, loop = { rotate = { 0, 1e20, 1 } } } end
        """)
        XCTAssertNotEqual(endless.render().status, OMNI_OK)
        XCTAssertTrue(endless.message.contains("at most 3600 degrees"), endless.message)
        let longest = try Script("""
        function render(ctx) return ui.box{ w = 1, h = 1, loop = { rotate = { 3600, 0, 10 } } } end
        """)
        XCTAssertEqual(longest.render().status, OMNI_OK, longest.message)
        let spec = strings(longest.output).string(decode(longest.output)[0].paint.loop)
        XCTAssertEqual(ShellLoop(spec)?.animations(size: CGSize(width: 10, height: 10)).first.flatMap {
            ($0.animation as? CAKeyframeAnimation)?.values?.count
        }, 721)
    }

    func testIconsCarryTheirSourceAndPlaceholder() throws {
        let script = try Script("""
        function render(ctx)
            return ui.row{
                ui.icon{ window = "ow_1", placeholder = "app.dashed" },
                ui.icon{ pid = 42 },
                ui.icon{ app = "com.apple.finder" },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        let text = strings(script.output)
        XCTAssertEqual(nodes[1].content.iconSource, .window)
        XCTAssertEqual(text.string(nodes[1].content.iconRef), "ow_1")
        XCTAssertEqual(text.string(nodes[1].content.placeholder), "app.dashed")
        XCTAssertEqual(nodes[2].content.iconSource, .pid)
        XCTAssertEqual(text.string(nodes[2].content.iconRef), "42")
        XCTAssertEqual(nodes[3].content.iconSource, .bundle)
    }

    func testPopoutRendersItsOwnTreeAndHandlers() throws {
        let script = try Script("""
        function render(ctx)
            return ui.box{ onClick = ui.popout, ui.text{ text = "bar" } }
        end
        function popout(ctx)
            return ui.column{
                ui.text{ text = ctx.state.picked or "none" },
                ui.box{ onClick = function(ctx) ctx.state.picked = "one" end },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(decode(script.output)[0].content.action, OMNI_ACTION_POPOUT)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).stats.changed, 1, script.message)
        let popout = decode(script.output(OMNI_VIEW_POPOUT))
        XCTAssertEqual(popout.map(\.kind), [.group, .label, .box])
        XCTAssertEqual(strings(script.output(OMNI_VIEW_POPOUT)).string(popout[1].content.text), "none")
        XCTAssertEqual(script.invoke(popout[2].content.action, in: OMNI_VIEW_BAR), OMNI_ERR_STALE_ACTION)
        XCTAssertEqual(script.invoke(popout[2].content.action, in: OMNI_VIEW_POPOUT), OMNI_OK, script.message)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).stats.changed, 1)
        let picked = decode(script.output(OMNI_VIEW_POPOUT))
        XCTAssertEqual(strings(script.output(OMNI_VIEW_POPOUT)).string(picked[1].content.text), "one")
        XCTAssertEqual(decode(script.output).map(\.kind), [.box, .label])

        omni_instance_discard_output(script.instance, OMNI_VIEW_POPOUT)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).stats.changed, 1)
    }

    func testStructuredDataReachesScriptsReadOnly() throws {
        let script = try Script("""
        function render(ctx)
            local spaces = ctx.data.workspaces
            if ctx.data.mutate then spaces[1].name = "x" end
            return ui.text{ text = spaces[2].name .. tostring(spaces[2].focused) .. spaces[2].windows
                .. tostring(ctx.data.charging) .. tostring(ctx.data.battery) }
        end
        """)
        var writer = ShellValueWriter()
        writer.array(2)
        for (name, focused) in [("one", false), ("two", true)] {
            writer.map(3)
            writer.key("name")
            writer.string(name)
            writer.key("focused")
            writer.bool(focused)
            writer.key("windows")
            writer.number(3)
        }
        XCTAssertEqual(setValue(script, "workspaces", writer.bytes), OMNI_OK)
        var flag = ShellValueWriter()
        flag.bool(true)
        XCTAssertEqual(setValue(script, "charging", flag.bytes), OMNI_OK)
        var missing = ShellValueWriter()
        missing.null()
        XCTAssertEqual(setValue(script, "battery", missing.bytes), OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let output = script.output
        XCTAssertEqual(strings(output).string(decode(output)[0].content.text), "twotrue3truenil")

        XCTAssertEqual(setValue(script, "mutate", flag.bytes), OMNI_OK)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("readonly"), script.message)
        XCTAssertEqual(setValue(script, "broken", Array(writer.bytes.dropLast())), OMNI_ERR_INTERNAL)
    }

    private func setValue(_ script: Script, _ key: String, _ bytes: [UInt8]) -> omni_status {
        bytes.withUnsafeBufferPointer { omni_instance_set_value(script.instance, key, $0.baseAddress, $0.count) }
    }

    func testEnvironmentHijackCannotStallEntryLookup() throws {
        let script = try Script("setmetatable(getfenv(), { __index = function() while true do end end })")
        let start = ContinuousClock.now
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("render function"), script.message)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }
}
