// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

private extension ShellWidgetPackage {
    func installHTTPStub(_ type: AnyClass) {
        http = ShellHTTPService(ledger: services, protocolClasses: [type])
    }

    func invalidateHTTPConfiguration(_ source: ShellWidgetSource) -> ShellScriptFailure? {
        guard let script else { return ShellScriptFailure(kind: .internalError, message: "Missing script") }
        var broken = source
        broken.components += source.components
        return configureComponents(broken, in: script.vm)
    }

    func httpState() -> (created: Bool, active: Int, authorized: Bool) {
        (http != nil, http?.activeCount ?? 0, componentConfigurationValid)
    }
}

@MainActor
final class ShellHTTPPackageTests: XCTestCase {
    private final class ProtocolStub: URLProtocol {
        struct Plan: Sendable {
            var stall = false
            var started: @Sendable () -> Void = {}
            var stopped: @Sendable () -> Void = {}
        }

        static let plans = Mutex<[String: Plan]>([:])
        private let active = Mutex<Plan?>(nil)

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?
                .hasSuffix(".example") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url, let plan = Self.plans.withLock({ $0[url.absoluteString] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            active.withLock { $0 = plan }
            plan.started()
            if plan.stall { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            active.withLock { $0?.stopped }?()
        }
    }

    @MainActor
    private final class Sink {
        var commands: [String] = []
        var onCommand: ((ShellWidgetScriptRequest) -> Void)?
        var onWidth: ((Float) -> Void)?
        var action: UInt32 = 0
        var sequence = 0

        func consume(_ batch: [String: ShellWidgetDelivery]) {
            guard let delivery = batch["test"] else { return }
            XCTAssertNil(delivery.failure)
            for command in delivery.requests { commands.append(command.text)
                onCommand?(command)
            }
            for tree in delivery.trees.values {
                let nodes = tree.nodes.withUnsafeBytes { buffer in
                    let header = buffer.loadUnaligned(as: omni_wire_header.self)
                    return (0 ..< Int(header.node_count)).map {
                        buffer.loadUnaligned(
                            fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                                .stride,
                            as: omni_wire_node.self
                        )
                    }
                }
                if let clickable = nodes.first(where: { $0.action != 0 }) { action = clickable.action
                    sequence = tree.sequence
                }
                onWidth?(nodes.map(\.width).max() ?? 0)
            }
        }
    }

    private let bar = ShellBarKey(monitor: .init(displayId: 98102))

    private func componentSource(
        _ script: String,
        hosts: [String] = [],
        userHosts: [String] = [],
        root: String = "",
        rootHosts: [String] = []
    ) -> ShellWidgetSource {
        var instance = ShellComponentInstance(id: "child", widget: "child")
        if !userHosts.isEmpty { instance.capabilities = ShellComponentCapabilities(network: userHosts) }
        let descriptor = ShellComponentDescriptor(
            widget: "child",
            title: "Child",
            icon: "",
            views: ["compact"],
            uses: [],
            options: [:],
            capabilities: ShellComponentCapabilities(network: hosts),
            providerCommand: nil,
            folder: URL(fileURLWithPath: "/tmp/omnishell-http-test-child")
        )
        return ShellWidgetSource(
            chunk: "@look/widgets/test/init.luau",
            main: """
            \(root)
            function render(ctx)
                local row = {}
                for _, item in ctx.data.components or {} do
                    if item.enabled then row[#row+1] = ui.component{id=item.id,view='compact'} end
                end
                return ui.row(row)
            end
            """,
            modules: [.init(path: "look/widgets/child/component.luau", source: script)],
            moduleLimit: 512,
            components: [instance],
            componentDescriptors: [descriptor],
            network: rootHosts
        )
    }

    func testNewComponentInitUsesAcceptedManifestAndUserHostsBeforeRequestDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = UUID().uuidString.lowercased() + ".example"
        let manifestURL = "https://manifest." + suffix + "/init"
        let userURL = "https://user." + suffix + "/init"
        ProtocolStub.plans.withLock { plans in plans[manifestURL] = .init()
            plans[userURL] = .init()
        }
        defer { ProtocolStub.plans.withLock { $0[manifestURL] = nil
            $0[userURL] = nil
        } }
        let sink = Sink()
        let commands = expectation(description: "both component init HTTP callbacks run under their owner")
        commands.expectedFulfillmentCount = 2
        sink.onCommand = { command in
            XCTAssertEqual(command.text, "switch-workspace 2")
            XCTAssertNotEqual(command.owner?.owner, 0)
            XCTAssertNil(command.bar)
            commands.fulfill()
        }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory)
        )
        var source = componentSource("""
        return { init=function()
            for _, url in {'\(manifestURL)','\(userURL)'} do
                assert(omniwm.http({url=url},function(result)
                    assert(result.ok and result.text=='ok')
                    omniwm.run('switch-workspace 2')
                end))
            end
        end, views={compact=function() return ui.box{w=10,h=10} end} }
        """, hosts: ["manifest." + suffix], userHosts: ["user." + suffix])
        let component = source.components
        source.components = []
        let failure = await package.load(source)
        XCTAssertNil(failure)
        let before = await package.httpState()
        XCTAssertFalse(before.created)
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        source.components = component
        await package.receive(.components(source))
        await fulfillment(of: [commands], timeout: 10)
        let accepted = await package.configuredComponents["child"]
        XCTAssertEqual(accepted?.capabilities?.network, ["user." + suffix])
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
        let closed = await package.httpState()
        XCTAssertFalse(closed.created)
    }

    func testRootHTTPReachesOnlyDeclaredHostsWhileUndeclaredComponentHostIsDenied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/root"
        let undeclared = "https://undeclared." + host + "/root"
        let starts = Mutex(0)
        ProtocolStub.plans.withLock { $0[url] = .init(started: { starts.withLock { $0 += 1 } }) }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let sink = Sink()
        let callbacks = expectation(description: "root response, root denial and component denial delivered")
        callbacks.expectedFulfillmentCount = 3
        sink.onCommand = { command in
            XCTAssertEqual(command.owner?.owner == 0, command.text != "switch-workspace 3", command.text)
            callbacks.fulfill()
        }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory)
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let source = componentSource("""
        return { init=function()
            assert(omniwm.http({url='\(url)'},function(result)
                assert(not result.ok and result.error=='network_denied')
                omniwm.run('switch-workspace 3')
            end))
        end, views={compact=function() return ui.box{} end} }
        """, root: """
        for _, case in {{'\(url)', true, 2}, {'\(undeclared)', false, 4}} do
            assert(omniwm.http({url=case[1]},function(result)
                assert(result.ok == case[2] and (case[2] or result.error=='network_denied'))
                omniwm.run('switch-workspace ' .. case[3])
            end))
        end
        """, rootHosts: [host.uppercased() + "."])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [callbacks], timeout: 10)
        XCTAssertEqual(Set(sink.commands), ["switch-workspace 2", "switch-workspace 3", "switch-workspace 4"])
        XCTAssertEqual(starts.withLock { $0 }, 1)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
    }

    func testFailedConfigurationDeniesLaterOwnerHTTPUntilRecoveryAndRemovalCancelsTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/stall"
        let started = expectation(description: "recovered owner starts its authorized transfer")
        let stopped = expectation(description: "component removal cancels the native transfer")
        ProtocolStub.plans.withLock { $0[url] = .init(
            stall: true,
            started: { started.fulfill() },
            stopped: { stopped.fulfill() }
        ) }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let sink = Sink()
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory)
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        var source = componentSource("""
        return { views={compact=function(ctx)
            return ui.box{w=ctx.instance.state.denied and 40 or 10,h=10,onClick=function(c)
                assert(omniwm.http({url='\(url)'},function(result)
                    assert(not result.ok and result.error=='configuration_failed')
                    c.instance.state.denied=true
                end))
            end}
        end} }
        """, hosts: [host])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        let visible = expectation(description: "initial owner action rendered")
        sink.onWidth = { width in if width == 10 { sink.onWidth = nil
            visible.fulfill()
        } }
        await package.receive(.bars([bar: ShellBarData()]))
        await fulfillment(of: [visible], timeout: 10)
        let invalid = await package.invalidateHTTPConfiguration(source)
        XCTAssertNotNil(invalid)
        let retained = await package.configuredComponents["child"]
        XCTAssertEqual(retained?.widget, "child")
        let denied = expectation(description: "existing component action denied after configuration failure")
        sink.onWidth = { width in if width == 40 { sink.onWidth = nil
            denied.fulfill()
        } }
        await package.receive(.invoke(bar, .bar, action: sink.action, sequence: sink.sequence, event: ShellEvent()))
        await fulfillment(of: [denied], timeout: 10)
        let invalidState = await package.httpState()
        XCTAssertFalse(invalidState.authorized)
        XCTAssertEqual(invalidState.active, 0)
        await package.receive(.components(source))
        let recovered = await package.httpState()
        XCTAssertTrue(recovered.authorized)
        await package.receive(.invoke(bar, .bar, action: sink.action, sequence: sink.sequence, event: ShellEvent()))
        await fulfillment(of: [started], timeout: 10)
        source.components = []
        await package.receive(.components(source))
        await fulfillment(of: [stopped], timeout: 10)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.receive(.services)
        let removed = await package.httpState()
        XCTAssertEqual(removed.active, 0)
        await package.close()
    }
}
