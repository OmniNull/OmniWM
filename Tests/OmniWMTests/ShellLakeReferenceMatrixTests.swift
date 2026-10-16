// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellLakeReferenceMatrixTests: XCTestCase {
    func testEveryAdvertisedViewRendersUnavailableDataWithAndWithoutANotch() throws {
        let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
        let widgets = try FileManager.default.contentsOfDirectory(
            at: profile.appendingPathComponent("widgets"), includingPropertiesForKeys: nil
        ).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("component.toml").path) }
            .map(\.lastPathComponent).sorted()
        let required: Set<String> = [
            "media",
            "calendar",
            "battery",
            "weather",
            "world-clock",
            "ci-status",
            "shelf",
            "converter",
            "devices",
            "privacy",
            "badges",
            "reminders",
            "timer",
            "quick-note"
        ]
        XCTAssertTrue(
            required.isSubset(of: Set(widgets)),
            "Missing reference components: \(required.subtracting(widgets).sorted())"
        )
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: profile, includingPropertiesForKeys: nil))
        var modules: [(path: String, source: String)] = []
        for case let file as URL in enumerator where file.pathExtension == "luau" {
            let relative = String(file.path.dropFirst(profile.path.count + 1))
            modules.append(("profile/" + relative, try String(contentsOf: file, encoding: .utf8)))
        }
        modules.sort { $0.path < $1.path }
        for widget in widgets {
            let descriptor = try ShellComponentCatalog.load(widget, directories: [profile])
            XCTAssertFalse(descriptor.views.isEmpty, widget)
            let configuration = try descriptor.validate(ShellComponentInstance(id: "subject", widget: widget))
            for notch in [false, true] {
                try renderMatrix(descriptor: descriptor, configuration: configuration, modules: modules, notch: notch)
            }
        }
    }

    private func renderMatrix(
        descriptor: ShellComponentDescriptor,
        configuration: ShellComponentInstance,
        modules: [(path: String, source: String)],
        notch: Bool
    ) throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
        defer { _ = omni_vm_destroy(vm) }
        XCTAssertEqual(omni_vm_set_module_limit(vm, 512), OMNI_OK)
        for module in modules {
            XCTAssertEqual(omni_vm_add_module(
                vm,
                module.path,
                module.path.utf8.count,
                module.source,
                module.source.utf8.count
            ), OMNI_OK, module.path)
        }
        let root = """
        local slots=require('../lib/lake/slots')
        function render(ctx)
            local entry=ctx.data.components[1]
            assert(entry.status=='ready',entry.error or entry.status)
            local island=ctx.data.island
            local mode=ctx.data.title
            local geometry=slots.geometry(island,mode,520)
            return ui.stack{w=island.size.w,h=island.size.h,align='top',
                ui.component{id='subject',view=mode,w=geometry.width,h=geometry.height,align='top',
                    props={notchGap=mode=='expanded' and 0 or geometry.gap,
                        top=mode=='expanded' and geometry.top+46 or mode=='peek' and geometry.compactHeight or 0}}}
        end
        """
        var error = [CChar](repeating: 0, count: 512)
        func message() -> String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        let loaded = omni_vm_load(
            vm,
            "@profile/widgets/matrix/init.luau",
            root,
            root.utf8.count,
            200_000_000,
            &error,
            error.count
        )
        XCTAssertEqual(loaded, OMNI_OK, message())
        guard loaded == OMNI_OK else { throw ShellResourceFailure(message()) }
        let config = ShellComponentCatalog.configurationBytes(instances: [configuration], descriptors: [descriptor])
        let configured = config.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
        }
        XCTAssertEqual(configured, OMNI_OK, message())
        guard configured == OMNI_OK else { throw ShellResourceFailure(message()) }
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        let text = ShellTextStore()
        let layout = ShellWidgetLayout()
        func set(_ key: String, _ value: ShellServiceValue) {
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }
        set("island", .object([
            "size": .object(["w": .number(760), "h": .number(360)]),
            "notch": notch ? .object(["w": .number(180), "h": .number(32)]) : .null,
            "visible": .bool(true),
            "drag": .object(["active": .bool(false), "types": .array([])])
        ]))
        set("seconds", .number(1000))
        for view in descriptor.views {
            let label = "\(descriptor.widget)/\(view), notch=\(notch), unavailable data"
            set("title", .text(view))
            XCTAssertEqual(omni_instance_begin_update(instance, OMNI_VIEW_BAR, .max, true), OMNI_OK, label)
            var done = false
            for _ in 0 ..< 32 {
                var step = omni_render_step_stats()
                let status = omni_instance_step_update(instance, OMNI_VIEW_BAR, 200_000_000, &step, &error, error.count)
                XCTAssertEqual(status, OMNI_OK, label + ": " + message())
                XCTAssertEqual(step.unit_status, OMNI_OK, label + ": " + message())
                guard status == OMNI_OK, step.unit_status == OMNI_OK else {
                    throw ShellResourceFailure(label + ": " + message())
                }
                if step.done { done = true
                    break
                }
            }
            XCTAssertTrue(done, label)
            guard done else { throw ShellResourceFailure(label) }
            var length = 0
            let output = try XCTUnwrap(omni_instance_output(instance, OMNI_VIEW_BAR, &length), label)
            let bytes = Array(UnsafeBufferPointer(start: output, count: length))
            let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).node_count }
            XCTAssertGreaterThan(count, 2, label)
            text.ingest(wire: bytes)
            XCTAssertTrue(layout.apply(bytes, text: text), label)
            XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite, label)
            XCTAssertEqual(layout.size.width, 760, label)
            XCTAssertEqual(layout.size.height, 360, label)
        }
    }
}
