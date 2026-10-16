// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellCIComponentTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let seconds: Double
        let cancelled: Bool
        let bytes: [UInt8]
    }

    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        let display: OpaquePointer
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)
        var nodes: [omni_wire_node] = []

        init(
            rootRequests: Int = 0,
            ownerTimers: Int = 0,
            repo: String = "OmniNull/OmniWM",
            componentWidth: Int? = nil,
            seed: [UInt8]? = nil
        ) throws {
            let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            self.vm = vm
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            for path in ["lib/lake/view.luau", "lib/lake/motion.luau"] {
                let source = try String(contentsOf: profile.appendingPathComponent(path), encoding: .utf8)
                let virtual = "profile/" + path
                XCTAssertEqual(omni_vm_add_module(vm, virtual, virtual.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            let component = try String(
                contentsOf: profile.appendingPathComponent("widgets/ci-status/component.luau"),
                encoding: .utf8
            )
            let wrapper = """
            local component = (function()
            \(component)
            end)()
            local initialize = component.init
            component.init = function(instance)
                for _ = 1, \(ownerTimers) do assert(omniwm.after(3600, function() end)) end
                initialize(instance)
            end
            return component
            """
            let path = "profile/widgets/ci-status/component.luau"
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, wrapper, wrapper.utf8.count), OMNI_OK)
            let root = """
            for _ = 1, \(rootRequests) do
                assert(omniwm.http({url='https://example.test/busy'},function() end))
            end
            function render(ctx)
                local activity = omniwm.components.activity('ci')
                local alert = activity and activity.alert
                return ui.column{
                    ui.text{text=alert and 'alert:'..alert.id..':'..tostring(alert.seconds) or 'no-alert'},
                    ui.component{id='ci',view='expanded',w=\(componentWidth.map { String($0) } ?? "nil")}
                }
            end
            """
            var error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                root,
                root.utf8.count,
                200_000_000,
                &error,
                error.count
            ), OMNI_OK)
            display = try XCTUnwrap(omni_instance_create(vm))
            self.error = error
            if let seed {
                XCTAssertEqual(seed.withUnsafeBufferPointer {
                    omni_vm_seed_store(vm, "ci", 2, $0.baseAddress, $0.count, nil, 0, &self.error, self.error.count)
                }, OMNI_OK, message)
            }
            configure(repo: repo)
        }

        isolated deinit {
            omni_instance_destroy(display)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func configure(enabled: Bool = true, repo: String = "OmniNull/OmniWM", interval: Double = 60) {
            var writer = ShellValueWriter()
            writer.array(1)
            writer.map(4)
            writer.key("id")
            writer.string("ci")
            writer.key("widget")
            writer.string("ci-status")
            writer.key("enabled")
            writer.bool(enabled)
            writer.key("options")
            writer.map(2)
            writer.key("repo")
            writer.string(repo)
            writer.key("interval")
            writer.number(interval)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func drain() -> [Request] {
            var requests: [Request] = []
            var request = omni_service_request()
            while omni_vm_next_service(vm, &request) {
                requests.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    revision: request.revision,
                    seconds: request.seconds,
                    cancelled: request.cancelled,
                    bytes: request.value.map { Array(UnsafeBufferPointer(
                        start: $0,
                        count: request.value_length
                    )) } ?? []
                ))
            }
            return requests
        }

        @discardableResult
        func complete(_ request: Request, _ bytes: [UInt8]? = nil) -> Bool {
            var writer = ShellValueWriter()
            writer.map(1)
            writer.key("ok")
            writer.bool(true)
            var handled = false
            XCTAssertEqual((bytes ?? writer.bytes).withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm,
                    request.owner,
                    request.id,
                    request.revision,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &handled,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            return handled
        }

        func render() throws {
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
            var count = 0
            let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &count))
            let bytes = Array(UnsafeBufferPointer(start: output, count: count))
            text.ingest(wire: bytes)
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func retry() throws {
            try render()
            let buttons = nodes.filter { $0.action != 0 }
            XCTAssertEqual(buttons.count, 1)
            let action = try XCTUnwrap(buttons.first).action
            let bytes = ShellEvent().bytes
            XCTAssertEqual(bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    display,
                    OMNI_VIEW_BAR,
                    action,
                    0,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }
    }

    private func response(
        id: Double = 10,
        attempt: Double = 1,
        name: String = "Build",
        conclusion: String = "success",
        failure: String? = nil,
        malformed: Bool = false,
        object: Bool = false,
        empty: Bool = false
    ) -> [UInt8] {
        var writer = ShellValueWriter()
        if let failure {
            writer.map(3)
            writer.key("ok")
            writer.bool(false)
            writer.key("status")
            writer.number(0)
            writer.key("error")
            writer.string(failure)
        } else {
            writer.map(3)
            writer.key("ok")
            writer.bool(true)
            writer.key("status")
            writer.number(200)
            writer.key("json")
            writer.map(1)
            writer.key("workflow_runs")
            if malformed { writer.string("invalid") }
            else if object { writer.map(1)
                writer.key("unexpected")
                writer.bool(true)
            } else if empty { writer.array(0) }
            else {
                writer.array(1)
                writer.map(5)
                writer.key("id")
                writer.number(id)
                writer.key("run_attempt")
                writer.number(attempt)
                writer.key("name")
                writer.string(name)
                writer.key("status")
                writer.string("completed")
                writer.key("conclusion")
                writer.string(conclusion)
            }
        }
        return writer.bytes
    }

    func testPopulatedExpandedViewFitsTheMinimumProfileWidth() throws {
        let fixture = try Fixture(componentWidth: 380)
        let request = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_HTTP })
        XCTAssertTrue(fixture.complete(request, response(
            name: String(repeating: "Long workflow name ", count: 10),
            conclusion: String(repeating: "cancelled", count: 4)
        )))
        for failed in [false, true] {
            if failed {
                let timer = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_TIMER })
                XCTAssertTrue(fixture.complete(timer))
                let refresh = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_HTTP })
                XCTAssertTrue(fixture.complete(
                    refresh,
                    response(failure: String(repeating: "Network unavailable ", count: 30))
                ))
            }
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains { $0.hasPrefix("Long workflow name") })
            var length = 0
            let output = try XCTUnwrap(omni_instance_output(fixture.display, OMNI_VIEW_BAR, &length))
            let bytes = Array(UnsafeBufferPointer(start: output, count: length))
            let layout = ShellWidgetLayout()
            XCTAssertTrue(layout.apply(bytes, text: fixture.text))
            XCTAssertEqual(layout.size.width, 380)
            let elements = layout.core.elements { _ in true }
            XCTAssertFalse(elements.isEmpty)
            for handle in elements {
                let frame = layout.core.absoluteFrame(of: handle)
                XCTAssertGreaterThanOrEqual(frame.x, 0)
                XCTAssertLessThanOrEqual(frame.x + frame.width, 380)
            }
        }
    }

    func testHTTPOverloadSchedulesExactlyOneLaterPoll() throws {
        let fixture = try Fixture(rootRequests: 6)
        let initial = fixture.drain()
        XCTAssertEqual(initial.filter { $0.kind == OMNI_SERVICE_HTTP }.count, 6)
        let timer = try XCTUnwrap(initial.first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(timer.seconds, 60)
        XCTAssertNotEqual(timer.owner.owner, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.complete(try XCTUnwrap(initial.first { $0.kind == OMNI_SERVICE_HTTP }))
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.complete(timer)
        let request = try XCTUnwrap(fixture.drain().ciOnly)
        XCTAssertEqual(request.kind, OMNI_SERVICE_HTTP)
        XCTAssertEqual(request.owner.owner, timer.owner.owner)
        let fields = try XCTUnwrap(ShellServiceValue.decode(request.bytes).fields)
        XCTAssertEqual(fields["url"]?.string, "https://api.github.com/repos/OmniNull/OmniWM/actions/runs?per_page=5")
        XCTAssertEqual(fields["response"]?.string, "json")
        XCTAssertEqual(fields["maxBytes"]?.number, 262_144)
    }

    func testTimerOverloadPausesUntilUserRetryAfterCapacityReturns() throws {
        let fixture = try Fixture(rootRequests: 6, ownerTimers: 32)
        let initial = fixture.drain()
        XCTAssertEqual(initial.filter { $0.kind == OMNI_SERVICE_TIMER }.count, 32)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Retry polling"))
        XCTAssertTrue(fixture.captions.contains("Polling paused: overloaded"))
        XCTAssertTrue(fixture.drain().isEmpty)
        let timer = try XCTUnwrap(initial.first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertTrue(omni_vm_cancel_service(fixture.vm, timer.owner, timer.id))
        fixture.complete(try XCTUnwrap(initial.first { $0.kind == OMNI_SERVICE_HTTP }))
        XCTAssertTrue(fixture.drain().allSatisfy(\.cancelled))
        try fixture.retry()
        let resumed = try XCTUnwrap(fixture.drain().ciOnly)
        XCTAssertEqual(resumed.kind, OMNI_SERVICE_HTTP)
        XCTAssertEqual(resumed.owner.owner, timer.owner.owner)
        try fixture.render()
        XCTAssertFalse(fixture.captions.contains("Retry polling"))
    }

    func testFailedAndMalformedResponsesRetainLastDataAndPollNormally() throws {
        let fixture = try Fixture()
        fixture.complete(try XCTUnwrap(fixture.drain().ciOnly), response(name: "Last valid run"))
        var pending = fixture.drain()
        let store = try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_STORE })
        fixture.complete(store)
        var timer = try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(timer.seconds, 60)
        for bytes in [
            response(failure: "invalid_json"),
            response(malformed: true),
            response(object: true),
            response(failure: "network")
        ] {
            fixture.complete(timer)
            let request = try XCTUnwrap(fixture.drain().ciOnly)
            fixture.complete(request, bytes)
            pending = fixture.drain()
            XCTAssertEqual(pending.count, 1)
            timer = try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_TIMER })
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains("Last valid run"))
            XCTAssertFalse(fixture.captions.contains("Retry polling"))
        }
        fixture.complete(timer)
        fixture.complete(try XCTUnwrap(fixture.drain().ciOnly), response(empty: true))
        try fixture.render()
        XCTAssertFalse(fixture.captions.contains("Last valid run"))
        XCTAssertTrue(fixture.captions.contains("No workflow runs"))
    }

    func testFailingRunOffersOneStableFourSecondAlertAndReattemptIsNew() throws {
        let fixture = try Fixture()
        var request = try XCTUnwrap(fixture.drain().ciOnly)
        for (attempt, expected) in [(1.0, "alert:10:1:4"), (1.0, "no-alert"), (2.0, "alert:10:2:4")] {
            fixture.complete(request, response(attempt: attempt, conclusion: "failure"))
            let pending = fixture.drain()
            for store in pending where store.kind == OMNI_SERVICE_STORE { fixture.complete(store) }
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains(expected), "\(fixture.captions)")
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains(expected))
            fixture.complete(try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_TIMER }))
            request = try XCTUnwrap(fixture.drain().ciOnly)
        }
    }

    func testOptionsChangeCancelsOldRequestAndTeardownCancelsTimerWithoutLateCallback() throws {
        let fixture = try Fixture()
        let old = try XCTUnwrap(fixture.drain().ciOnly)
        fixture.configure(repo: "Other/Project", interval: 15)
        let changed = fixture.drain()
        XCTAssertTrue(changed.contains { $0.cancelled && $0.id == old.id })
        let request = try XCTUnwrap(changed.first { !$0.cancelled })
        let fields = try XCTUnwrap(ShellServiceValue.decode(request.bytes).fields)
        XCTAssertEqual(fields["url"]?.string, "https://api.github.com/repos/Other/Project/actions/runs?per_page=5")
        XCTAssertFalse(fixture.complete(old, response(name: "Stale old repository")))
        fixture.complete(request, response(name: "Current repository"))
        let pending = fixture.drain()
        for store in pending where store.kind == OMNI_SERVICE_STORE { fixture.complete(store) }
        let timer = try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(timer.seconds, 15)
        fixture.configure(enabled: false, repo: "Other/Project", interval: 15)
        XCTAssertTrue(fixture.drain().contains { $0.cancelled && $0.id == timer.id })
        XCTAssertFalse(fixture.complete(timer))
        XCTAssertEqual(omni_vm_service_stats(fixture.vm).reserved, 0)
    }

    func testCachedRunsSurviveRestartWithoutRepeatingAlreadySeenFailureAlert() throws {
        let first = try Fixture()
        first.complete(try XCTUnwrap(first.drain().ciOnly), response(name: "Persisted failure", conclusion: "failure"))
        let store = try XCTUnwrap(first.drain().first { $0.kind == OMNI_SERVICE_STORE })
        let restored = try Fixture(seed: store.bytes)
        try restored.render()
        XCTAssertTrue(restored.captions.contains("Persisted failure"))
        XCTAssertTrue(restored.captions.contains("no-alert"))
        restored.complete(
            try XCTUnwrap(restored.drain().ciOnly),
            response(name: "Persisted failure", conclusion: "failure")
        )
        try restored.render()
        XCTAssertTrue(restored.captions.contains("no-alert"))
    }

    func testInstalledManifestBoundsAndNoDefaultNetworkActivation() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertTrue(ShellDefaults.sync(into: shell).isEmpty)
        XCTAssertTrue(try ShellProfiles.select("lake", in: shell))
        var problems: [String] = []
        let config = ShellConfig.resolve(shellDirectory: shell, problems: &problems)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertFalse(config.island?.components.contains { $0.widget == "ci-status" } == true)
        let descriptor = try ShellComponentCatalog.load("ci-status", directories: config.directories)
        XCTAssertEqual(descriptor.capabilities.network, ["api.github.com"])
        XCTAssertNil(descriptor.providerCommand)
        XCTAssertEqual(descriptor.views, ["compact", "expanded"])
        let option = try XCTUnwrap(descriptor.options["interval"])
        XCTAssertEqual(option.defaultValue, .number(60))
        XCTAssertTrue(option.accepts(.number(15)))
        XCTAssertTrue(option.accepts(.number(3600)))
        XCTAssertFalse(option.accepts(.number(14)))
        XCTAssertFalse(option.accepts(.number(3601)))
        XCTAssertFalse(option.accepts(.number(60.5)))
    }

    func testInvalidRepositoryDoesNotAdmitNetworkOrRetryTimer() throws {
        for repo in [
            "",
            "owner/name/extra",
            "owner/../bad",
            "-owner/name",
            "owner/name?query=x",
            "https://example.test"
        ] {
            let fixture = try Fixture(repo: repo)
            XCTAssertTrue(fixture.drain().isEmpty)
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains("Use a repository in owner/name format"))
            try fixture.retry()
            XCTAssertTrue(fixture.drain().isEmpty)
        }
    }
}

private extension Array {
    var ciOnly: Element? {
        count == 1 ? self[0] : nil
    }
}
