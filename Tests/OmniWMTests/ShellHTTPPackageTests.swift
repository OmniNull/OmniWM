// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

private extension ShellWidgetPackage {
    func installHTTPStub(
        _ type: AnyClass,
        decodeJSON: @escaping @Sendable (Data) throws -> [UInt8] = ShellHTTPResponse.json
    ) {
        http = ShellHTTPService(ledger: services, protocolClasses: [type], decodeJSON: decodeJSON)
    }

    func awaitHTTPQueue() async {
        await http?.captureBegin(0)
    }

    var reservedServices: UInt32 {
        script.map { omni_vm_service_stats($0.vm).reserved } ?? 0
    }

    func deliverServices(revokingAfterFirst revoke: @escaping @Sendable () -> Void) async {
        guard let script else { return }
        queue.async(execute: revoke)
        await deliverServices(in: script)
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

    func queueHTTPBody(_ id: ShellServiceID, url: String, policy: ShellHTTPPolicy) {
        let operation = ShellResourceOperation()
        services.register(id, cancel: { operation.cancel() })
        resourceWork.append(.httpBody(
            id,
            ShellHTTPRequest(url: url, bodyResource: ShellResourceID()),
            policy,
            operation
        ))
    }

    var queuedResourceWork: Int {
        resourceWork.count
    }
}

@MainActor
final class ShellHTTPPackageTests: XCTestCase {
    private final class ProtocolStub: URLProtocol {
        struct Plan: Sendable {
            var stall = false
            var body = "ok"
            var redirect: URL?
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
            let status = plan.redirect == nil ? 200 : 302
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            if let redirect = plan.redirect {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(plan.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            active.withLock { $0?.stopped }?()
        }
    }

    @MainActor
    private final class Sink {
        var commands: [String] = []
        var approvals: [ShellNetworkApproval] = []
        var onCommand: ((ShellWidgetScriptRequest) -> Void)?
        var onWidth: ((Float) -> Void)?
        var action: UInt32 = 0
        var sequence = 0

        func consume(_ batch: [String: ShellWidgetDelivery]) {
            guard let delivery = batch["test"] else { return }
            XCTAssertNil(delivery.failure)
            approvals += delivery.networkApprovals
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

    private static let renderComponents = """
    function render(ctx)
        local row = {}
        for _, item in ctx.data.components or {} do
            if item.enabled then row[#row+1] = ui.component{id=item.id,view='compact'} end
        end
        return ui.row(row)
    end
    """

    private let bar = ShellBarKey(monitor: .init(displayId: 98102))
    private let rootPrincipal = ShellWidgetPrincipal(role: .root, name: "test", source: "/tmp/omnishell-http-test-root")
    private let childPrincipal = ShellWidgetPrincipal(
        role: .component, name: "child", folder: URL(fileURLWithPath: "/tmp/omnishell-http-test-child")
    )

    private func componentSource(
        _ script: String,
        hosts: [String] = [],
        userHosts: [String] = [],
        root: String = "",
        rootHosts: [String] = [],
        purpose: String? = nil
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
            capabilities: ShellComponentCapabilities(network: hosts, purpose: purpose),
            providerCommand: nil,
            folder: URL(fileURLWithPath: "/tmp/omnishell-http-test-child")
        )
        return ShellWidgetSource(
            chunk: "@look/widgets/test/init.luau",
            main: root + "\n" + Self.renderComponents,
            modules: [.init(path: "look/widgets/child/component.luau", source: script)],
            moduleLimit: 512,
            components: [instance],
            componentDescriptors: [descriptor],
            network: rootHosts,
            principal: rootPrincipal
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
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions(
                allowing: ["manifest." + suffix, "user." + suffix],
                for: childPrincipal
            )
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
        await fulfillment(of: [commands], timeout: failureBound)
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
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions(allowing: [host], for: rootPrincipal)
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
        await fulfillment(of: [callbacks], timeout: failureBound)
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
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions(allowing: [host], for: childPrincipal)
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
        await fulfillment(of: [visible], timeout: failureBound)
        let invalid = await package.invalidateHTTPConfiguration(source)
        XCTAssertNotNil(invalid)
        let retained = await package.configuredComponents["child"]
        XCTAssertEqual(retained?.widget, "child")
        let denied = expectation(description: "existing component action denied after configuration failure")
        sink.onWidth = { width in if width == 40 { sink.onWidth = nil
            denied.fulfill()
        } }
        await package.receive(.invoke(bar, .bar, action: sink.action, sequence: sink.sequence, event: ShellEvent()))
        await fulfillment(of: [denied], timeout: failureBound)
        let invalidState = await package.httpState()
        XCTAssertFalse(invalidState.authorized)
        XCTAssertEqual(invalidState.active, 0)
        await package.receive(.components(source))
        let recovered = await package.httpState()
        XCTAssertTrue(recovered.authorized)
        await package.receive(.invoke(bar, .bar, action: sink.action, sequence: sink.sequence, event: ShellEvent()))
        await fulfillment(of: [started], timeout: failureBound)
        source.components = []
        await package.receive(.components(source))
        await fulfillment(of: [stopped], timeout: failureBound)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.receive(.services)
        let removed = await package.httpState()
        XCTAssertEqual(removed.active, 0)
        await package.close()
    }

    func testNotApprovedRequestsFailAtOnceReleaseReservationsAndPostOneApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = UUID().uuidString.lowercased() + ".example"
        let allowedURL = "https://allowed." + suffix + "/data"
        let pendingURL = "https://pending." + suffix + "/data"
        let pendingStarts = Mutex(0)
        ProtocolStub.plans.withLock { plans in plans[allowedURL] = .init()
            plans[pendingURL] = .init(started: { pendingStarts.withLock { $0 += 1 } })
        }
        defer { ProtocolStub.plans.withLock { $0[allowedURL] = nil
            $0[pendingURL] = nil
        } }
        let sink = Sink()
        let commands = expectation(description: "every refusal and the approved response reached Luau")
        commands.expectedFulfillmentCount = 2
        sink.onCommand = { _ in commands.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions(allowing: ["allowed." + suffix], for: childPrincipal)
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let failure = await package.load(componentSource("""
        return { init=function()
            local refusals = 0
            local function request()
                assert(omniwm.http({url='\(pendingURL)'},function(result)
                    assert(not result.ok and result.error=='network_not_approved')
                    refusals += 1
                    if refusals < 8 then request() else omniwm.run('switch-workspace 5') end
                end))
            end
            request()
            assert(omniwm.http({url='\(allowedURL)'},function(result)
                assert(result.ok and result.text=='ok')
                omniwm.run('switch-workspace 6')
            end))
        end, views={compact=function() return ui.box{w=10,h=10} end} }
        """, hosts: ["allowed." + suffix, "pending." + suffix], userHosts: ["extra." + suffix], purpose: "Build status"))
        XCTAssertNil(failure)
        await fulfillment(of: [commands], timeout: failureBound)
        XCTAssertEqual(Set(sink.commands), ["switch-workspace 5", "switch-workspace 6"])
        XCTAssertEqual(pendingStarts.withLock { $0 }, 0)
        XCTAssertEqual(sink.approvals, [ShellNetworkApproval(
            key: .init(principal: childPrincipal, hosts: ["pending." + suffix, "extra." + suffix]),
            purpose: "Build status"
        )])
        XCTAssertEqual(package.services.activeCount, 0)
        let state = await package.httpState()
        XCTAssertEqual(state.active, 0)
        await package.close()
    }

    func testRevocationFinishesInFlightTransferWithoutLateSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/stall"
        let started = expectation(description: "approved transfer started")
        let stopped = expectation(description: "revocation stops the native transfer")
        ProtocolStub.plans.withLock { $0[url] = .init(
            stall: true,
            started: { started.fulfill() },
            stopped: { stopped.fulfill() }
        ) }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let sink = Sink()
        let revoked = expectation(description: "revoked request reports the denial")
        sink.onCommand = { command in
            XCTAssertEqual(command.text, "switch-workspace 7")
            revoked.fulfill()
        }
        let permissions = ShellNetworkPermissions(allowing: [host], for: rootPrincipal)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: permissions
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let failure = await package.load(componentSource(
            "return { views={compact=function() return ui.box{} end} }",
            root: """
            assert(omniwm.http({url='\(url)'},function(result)
                assert(not result.ok and result.error=='network_denied' and result.text==nil)
                omniwm.run('switch-workspace 7')
            end))
            """,
            rootHosts: [host]
        ))
        XCTAssertNil(failure)
        await fulfillment(of: [started], timeout: failureBound)
        var denied = ShellPermissionDecisions()
        denied.setNetwork(.denied, hosts: [host], for: rootPrincipal)
        XCTAssertTrue(permissions.update(decisions: denied))
        await package.receive(.permissions)
        await fulfillment(of: [stopped, revoked], timeout: failureBound)
        XCTAssertEqual(sink.commands, ["switch-workspace 7"])
        XCTAssertEqual(package.services.activeCount, 0)
        let state = await package.httpState()
        XCTAssertEqual(state.active, 0)
        await package.close()
    }

    func testRevocationFailsQueuedHTTPBodyWorkAndKeepsApprovedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let permissions = ShellNetworkPermissions(allowing: ["revoked.example", "kept.example"], for: rootPrincipal)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: directory),
            permissions: permissions
        )
        let failure = await package.load(componentSource("return { views={compact=function() return ui.box{} end} }"))
        XCTAssertNil(failure)
        let policy = ShellHTTPPolicy.widget(
            rootPrincipal, hosts: ["revoked.example", "kept.example"], permissions: permissions
        )
        let owner = ShellServiceOwner(generation: package.services.generation, owner: 0, epoch: 1)
        let revokedID = ShellServiceID(owner: owner, request: 101)
        let keptID = ShellServiceID(owner: owner, request: 102)
        await package.queueHTTPBody(revokedID, url: "https://revoked.example/upload", policy: policy)
        await package.queueHTTPBody(keptID, url: "https://kept.example/upload", policy: policy)
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["kept.example"], for: rootPrincipal)
        decisions.setNetwork(.denied, hosts: ["revoked.example"], for: rootPrincipal)
        XCTAssertTrue(permissions.update(decisions: decisions))
        await package.receive(.permissions)
        let queued = await package.queuedResourceWork
        XCTAssertEqual(queued, 1)
        let batch = package.services.takeBatch()
        XCTAssertEqual(batch.map(\.id), [revokedID])
        XCTAssertEqual(
            try XCTUnwrap(ShellServiceValue.decode(try XCTUnwrap(batch.first?.payload)).fields)["error"]?.string,
            "network_denied"
        )
        XCTAssertTrue(package.services.contains(keptID))
        await package.close()
    }

    func testGrantingAnotherHostDoesNotRerunFinishedRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = UUID().uuidString.lowercased() + ".example"
        let firstURL = "https://first." + suffix + "/once"
        let secondURL = "https://second." + suffix + "/once"
        let starts = Mutex<[String: Int]>([:])
        ProtocolStub.plans.withLock { plans in
            for url in [firstURL, secondURL] {
                plans[url] = .init(started: { starts.withLock { $0[url, default: 0] += 1 } })
            }
        }
        defer { ProtocolStub.plans.withLock { $0[firstURL] = nil
            $0[secondURL] = nil
        } }
        let sink = Sink()
        let callbacks = expectation(description: "approved and not-approved startup requests finished")
        callbacks.expectedFulfillmentCount = 2
        sink.onCommand = { _ in callbacks.fulfill() }
        let permissions = ShellNetworkPermissions(allowing: ["first." + suffix], for: rootPrincipal)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: permissions
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let failure = await package.load(componentSource(
            "return { views={compact=function() return ui.box{} end} }",
            root: """
            assert(omniwm.http({url='\(firstURL)'},function(result)
                assert(result.ok)
                omniwm.run('switch-workspace 2')
            end))
            assert(omniwm.http({url='\(secondURL)'},function(result)
                assert(result.error=='network_not_approved')
                omniwm.run('switch-workspace 3')
            end))
            """,
            rootHosts: ["first." + suffix, "second." + suffix]
        ))
        XCTAssertNil(failure)
        await fulfillment(of: [callbacks], timeout: failureBound)
        XCTAssertEqual(sink.approvals.map(\.key), [.init(principal: rootPrincipal, hosts: ["second." + suffix])])
        var granted = ShellPermissionDecisions()
        granted.setNetwork(.allowed, hosts: ["first." + suffix, "second." + suffix], for: rootPrincipal)
        XCTAssertTrue(permissions.update(decisions: granted))
        await package.receive(.permissions)
        await package.receive(.services)
        XCTAssertEqual(starts.withLock { $0 }, [firstURL: 1])
        XCTAssertEqual(Set(sink.commands), ["switch-workspace 2", "switch-workspace 3"])
        XCTAssertEqual(sink.commands.count, 2)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
    }

    func testQueuedSuccessRevokedBeforeDeliveryReportsTheDenialAndReleasesItsReservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/done"
        ProtocolStub.plans.withLock { $0[url] = .init() }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let sink = Sink()
        let delivered = expectation(description: "the revoked response reaches Luau once")
        sink.onCommand = { _ in delivered.fulfill() }
        let permissions = ShellNetworkPermissions(allowing: [host], for: rootPrincipal)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: permissions
        )
        await package.installHTTPStub(ProtocolStub.self)
        let queued = expectation(description: "the successful response waits for service delivery")
        queued.assertForOverFulfill = false
        package.services.attachWake { queued.fulfill() }
        let failure = await package.load(componentSource(
            "return { views={compact=function() return ui.box{} end} }",
            root: """
            assert(omniwm.http({url='\(url)'},function(result)
                omniwm.run('done ' .. tostring(result.error) .. ' ' .. tostring(result.text))
            end))
            """,
            rootHosts: [host]
        ))
        XCTAssertNil(failure)
        await fulfillment(of: [queued], timeout: failureBound)
        XCTAssertEqual(package.services.pendingCount, 1)
        let reserved = await package.reservedServices
        XCTAssertEqual(reserved, 1)
        var denied = ShellPermissionDecisions()
        denied.setNetwork(.denied, hosts: [host], for: rootPrincipal)
        XCTAssertTrue(permissions.update(decisions: denied))
        await package.receive(.permissions)
        await package.receive(.services)
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(sink.commands, ["done network_denied nil"])
        XCTAssertEqual(package.services.activeCount, 0)
        XCTAssertEqual(package.services.pendingCount, 0)
        let released = await package.reservedServices
        XCTAssertEqual(released, 0)
        await package.close()
    }

    func testRevocationBetweenTwoBatchedCompletionsDeniesOnlyTheLaterOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = UUID().uuidString.lowercased() + ".example"
        let hosts = ["first." + suffix, "second." + suffix]
        ProtocolStub.plans.withLock { plans in for host in hosts { plans["https://\(host)/json"] = .init(body: host) } }
        defer { ProtocolStub.plans.withLock { plans in for host in hosts { plans["https://\(host)/json"] = nil } } }
        let sink = Sink()
        let delivered = expectation(description: "both batched responses reach Luau")
        delivered.expectedFulfillmentCount = 2
        sink.onCommand = { _ in delivered.fulfill() }
        let permissions = ShellNetworkPermissions(allowing: Set(hosts), for: rootPrincipal)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: permissions
        )
        let order = Mutex<[String]>([])
        let decoded = expectation(description: "both responses were decoded into the ledger")
        decoded.expectedFulfillmentCount = 2
        await package.installHTTPStub(ProtocolStub.self) { data in
            let host = String(decoding: data, as: UTF8.self)
            order.withLock { $0.append(host) }
            decoded.fulfill()
            var writer = ShellValueWriter()
            writer.string(host)
            return writer.bytes
        }
        let failure = await package.load(componentSource(
            "return { views={compact=function() return ui.box{} end} }",
            root: """
            for _, host in {'\(hosts[0])', '\(hosts[1])'} do
                assert(omniwm.http({url='https://' .. host .. '/json', response='json'},function(result)
                    omniwm.run(host .. ' ' .. tostring(result.error) .. ' ' .. tostring(result.json))
                end))
            end
            """,
            rootHosts: hosts
        ))
        XCTAssertNil(failure)
        await fulfillment(of: [decoded], timeout: failureBound)
        await package.awaitHTTPQueue()
        XCTAssertEqual(package.services.pendingCount, 2)
        let batch = order.withLock { $0 }
        var revocation = ShellPermissionDecisions()
        revocation.setNetwork(.allowed, hosts: [batch[0]], for: rootPrincipal)
        revocation.setNetwork(.denied, hosts: [batch[1]], for: rootPrincipal)
        let decisions = revocation
        await package.deliverServices(revokingAfterFirst: { _ = permissions.update(decisions: decisions) })
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(sink.commands, ["\(batch[0]) nil \(batch[0])", "\(batch[1]) network_denied nil"])
        XCTAssertEqual(package.services.activeCount, 0)
        let released = await package.reservedServices
        XCTAssertEqual(released, 0)
        await package.close()
    }

    func testRemovingAComponentHostDeniesItsInFlightQueuedAndBodyWorkThroughComponentsUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        let suffix = UUID().uuidString.lowercased() + ".example"
        let keep = "keep." + suffix
        let gone = "gone." + suffix
        let holdStarted = expectation(description: "the removed host's transfer started")
        let holdStopped = expectation(description: "the components update stops the removed host's transfer")
        let stayStarted = expectation(description: "the kept host's transfer started")
        let urls = ["https://\(gone)/hold", "https://\(keep)/stay", "https://\(gone)/done"]
        ProtocolStub.plans.withLock { plans in
            plans[urls[0]] = .init(stall: true, started: { holdStarted.fulfill() }, stopped: { holdStopped.fulfill() })
            plans[urls[1]] = .init(stall: true, started: { stayStarted.fulfill() })
            plans[urls[2]] = .init()
        }
        defer { ProtocolStub.plans.withLock { plans in for url in urls { plans[url] = nil } } }
        let module = componentRequests(["hold": urls[0], "stay": urls[1], "done": urls[2]])
        try writeIsland(shell, child: module, hosts: [keep, gone], in: shell)
        let source = try islandSource(shell)
        let principal = try XCTUnwrap(source.componentDescriptors.first?.principal)
        let sink = Sink()
        let delivered = expectation(description: "the removed host's callbacks report the denial")
        delivered.expectedFulfillmentCount = 2
        sink.onCommand = { _ in delivered.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store")),
            permissions: ShellNetworkPermissions(allowing: [keep, gone], for: principal)
        )
        await package.installHTTPStub(ProtocolStub.self)
        let queued = expectation(description: "the successful response waits for service delivery")
        queued.assertForOverFulfill = false
        package.services.attachWake { queued.fulfill() }
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [holdStarted, stayStarted, queued], timeout: failureBound)
        let policy = ShellHTTPPolicy.declared(package.httpDeclarations, owner: "child")
        let owner = ShellServiceOwner(generation: package.services.generation, owner: 0, epoch: 1)
        let goneBody = ShellServiceID(owner: owner, request: 101)
        let keepBody = ShellServiceID(owner: owner, request: 102)
        await package.queueHTTPBody(goneBody, url: "https://\(gone)/upload", policy: policy)
        await package.queueHTTPBody(keepBody, url: "https://\(keep)/upload", policy: policy)

        try writeChild(module, hosts: [keep], in: shell)
        let updated = try islandSource(shell)
        XCTAssertEqual(updated.modules.map(\.source), source.modules.map(\.source))
        await package.receive(.components(updated))
        await package.awaitHTTPQueue()
        let state = await package.httpState()
        XCTAssertEqual(state.active, 1)
        let queuedWork = await package.queuedResourceWork
        XCTAssertEqual(queuedWork, 1)
        XCTAssertTrue(package.services.contains(keepBody))
        await fulfillment(of: [holdStopped], timeout: failureBound)
        await package.receive(.services)
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(Set(sink.commands), ["hold network_denied nil", "done network_denied nil"])
        XCTAssertFalse(package.services.contains(goneBody))
        await package.close()
    }

    func testRedirectAfterComponentsUpdateIsCheckedAgainstTheCurrentDeclaration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        let suffix = UUID().uuidString.lowercased() + ".example"
        let keep = "keep." + suffix
        let gone = "gone." + suffix
        let url = "https://\(keep)/redirect"
        let target = "https://\(gone)/next"
        let started = expectation(description: "the request reached the network before the update")
        let release = DispatchSemaphore(value: 0)
        let targetStarts = Mutex(0)
        ProtocolStub.plans.withLock { plans in
            plans[url] = .init(redirect: URL(string: target), started: {
                started.fulfill()
                _ = release.wait(timeout: .now() + 10)
            })
            plans[target] = .init(started: { targetStarts.withLock { $0 += 1 } })
        }
        defer { ProtocolStub.plans.withLock { $0[url] = nil
            $0[target] = nil
        } }
        let module = componentRequests(["redirect": url])
        try writeIsland(shell, child: module, hosts: [keep, gone], in: shell)
        let source = try islandSource(shell)
        let principal = try XCTUnwrap(source.componentDescriptors.first?.principal)
        let sink = Sink()
        let delivered = expectation(description: "the redirected request reports the denial")
        sink.onCommand = { _ in delivered.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store")),
            permissions: ShellNetworkPermissions(allowing: [keep, gone], for: principal)
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [started], timeout: failureBound)
        try writeChild(module, hosts: [keep], in: shell)
        await package.receive(.components(try islandSource(shell)))
        release.signal()
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(sink.commands, ["redirect network_denied nil"])
        XCTAssertEqual(targetStarts.withLock { $0 }, 0)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
    }

    func testRetargetedComponentSourceLosesTheOldPrincipalsGrantForInFlightAndQueuedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        let host = UUID().uuidString.lowercased() + ".example"
        let holdStarted = expectation(description: "the old principal's transfer started")
        let holdStopped = expectation(description: "the retarget stops the old principal's transfer")
        let urls = ["https://\(host)/hold", "https://\(host)/done"]
        ProtocolStub.plans.withLock { plans in
            plans[urls[0]] = .init(stall: true, started: { holdStarted.fulfill() }, stopped: { holdStopped.fulfill() })
            plans[urls[1]] = .init()
        }
        defer { ProtocolStub.plans.withLock { plans in for url in urls { plans[url] = nil } } }
        let module = componentRequests(["hold": urls[0], "done": urls[1]])
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try writeIsland(shell, child: module, hosts: [host], in: first)
        try writeChild(module, hosts: [host], in: second)
        let link = shell.appendingPathComponent("widgets/child")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: first.appendingPathComponent("widgets/child")
        )
        let source = try islandSource(shell)
        let principal = try XCTUnwrap(source.componentDescriptors.first?.principal)
        let sink = Sink()
        let delivered = expectation(description: "both callbacks report the new principal's missing approval")
        delivered.expectedFulfillmentCount = 2
        sink.onCommand = { _ in delivered.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store")),
            permissions: ShellNetworkPermissions(allowing: [host], for: principal)
        )
        await package.installHTTPStub(ProtocolStub.self)
        let queued = expectation(description: "the successful response waits for service delivery")
        queued.assertForOverFulfill = false
        package.services.attachWake { queued.fulfill() }
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [holdStarted, queued], timeout: failureBound)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: second.appendingPathComponent("widgets/child")
        )
        let retargeted = try islandSource(shell)
        XCTAssertNotEqual(retargeted.componentDescriptors.first?.principal, principal)
        XCTAssertEqual(retargeted.modules.map(\.path), source.modules.map(\.path))
        XCTAssertEqual(retargeted.modules.map(\.source), source.modules.map(\.source))
        await package.receive(.components(retargeted))
        await package.awaitHTTPQueue()
        await fulfillment(of: [holdStopped], timeout: failureBound)
        await package.receive(.services)
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(Set(sink.commands), ["hold network_not_approved nil", "done network_not_approved nil"])
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
    }

    func testRetiringAComponentKeepsTheRootsDeclaredTransferRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/root"
        let started = expectation(description: "the root transfer started")
        ProtocolStub.plans.withLock { $0[url] = .init(stall: true, started: { started.fulfill() }) }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions(allowing: [host], for: rootPrincipal)
        )
        await package.installHTTPStub(ProtocolStub.self)
        var source = componentSource(
            "return { views={compact=function() return ui.box{} end} }",
            root: "assert(omniwm.http({url='\(url)'},function() end))",
            rootHosts: [host]
        )
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [started], timeout: failureBound)
        source.components = []
        await package.receive(.components(source))
        await package.awaitHTTPQueue()
        let configured = await package.configuredComponents
        XCTAssertTrue(configured.isEmpty)
        let state = await package.httpState()
        XCTAssertEqual(state.active, 1)
        await package.close()
    }

    func testARemovedAndRestoredComponentReportsItsPendingHostAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "pending." + UUID().uuidString.lowercased() + ".example"
        let sink = Sink()
        let first = expectation(description: "the component's first request is refused")
        sink.onCommand = { _ in first.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions()
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let source = componentSource("""
        return { init=function()
            assert(omniwm.http({url='https://\(host)/data'},function(result) omniwm.run(result.error) end))
        end, views={compact=function() return ui.box{w=10,h=10} end} }
        """, hosts: [host])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [first], timeout: failureBound)
        let approval = ShellNetworkApproval(key: .init(principal: childPrincipal, hosts: [host]), purpose: nil)
        XCTAssertEqual(sink.approvals, [approval])

        let second = expectation(description: "the restored component's request is refused")
        sink.onCommand = { _ in second.fulfill() }
        await package.receive(.components(ShellWidgetSource(
            chunk: source.chunk, main: source.main, modules: [], moduleLimit: source.moduleLimit,
            network: source.network, principal: source.principal
        )))
        await package.receive(.components(source))
        await fulfillment(of: [second], timeout: failureBound)
        XCTAssertEqual(sink.approvals, [approval, approval])
        XCTAssertEqual(sink.commands, ["network_not_approved", "network_not_approved"])
        await package.close()
    }

    func testRemovingADeclaredHostForgetsTheComponentsReportedApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = UUID().uuidString.lowercased() + ".example"
        let hosts = ["pending." + suffix, "kept." + suffix]
        let sink = Sink()
        let refused = expectation(description: "the component's request is refused")
        sink.onCommand = { _ in refused.fulfill() }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory),
            permissions: ShellNetworkPermissions()
        )
        await package.installHTTPStub(ProtocolStub.self)
        package.services.attachWake { Task { await package.receive(.services) } }
        let script = """
        return { init=function()
            assert(omniwm.http({url='https://\(hosts[0])/data'},function(result) omniwm.run(result.error) end))
        end, views={compact=function() return ui.box{w=10,h=10} end} }
        """
        let source = componentSource(script, hosts: hosts)
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [refused], timeout: failureBound)
        let key = ShellNetworkApproval.Key(principal: childPrincipal, hosts: Set(hosts))
        XCTAssertEqual(sink.approvals.map(\.key), [key])
        var reported = await package.networkApprovals
        XCTAssertEqual(reported, [key])

        await package.receive(.components(source))
        reported = await package.networkApprovals
        XCTAssertEqual(reported, [key])
        await package.receive(.components(componentSource(script, hosts: [hosts[1]])))
        reported = await package.networkApprovals
        XCTAssertTrue(reported.isEmpty)
        await package.close()
    }

    func testRevocationReachesAPackageTheHostIsStillLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        let host = UUID().uuidString.lowercased() + ".example"
        let url = "https://" + host + "/startup"
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        ProtocolStub.plans.withLock { $0[url] = .init(
            stall: true,
            started: { started.signal() },
            stopped: { stopped.signal() }
        ) }
        defer { ProtocolStub.plans.withLock { $0[url] = nil } }
        let files = [
            "shell.toml": "profiles.default.trailing = [\"test\"]\n",
            "widgets/test/settings.toml": "[capabilities]\nnetwork = ['\(host)']\n",
            "widgets/test/init.luau": """
            assert(omniwm.http({url='\(url)'},function(result)
                omniwm.run(result.ok and 'switch-workspace 8'
                    or result.error == 'network_denied' and 'switch-workspace 7' or 'switch-workspace 9')
            end))
            function render(ctx) return ui.box{ w = 10, h = 10 } end
            """
        ]
        for (path, contents) in files {
            let file = shell.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("settings"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("settings"), deferSaves: false)
        )
        let motion = MotionPolicy(animationsEnabled: false)
        let manager = WorkspaceBarManager(configDirectory: root, motionPolicy: motion)
        settings.shellPermissions.onDecisionsChange = { [weak manager, weak settings] in
            guard let settings else { return }
            manager?.updateShellPermissions(settings)
        }
        let principal = ShellWidgetPrincipal(
            role: .bar,
            name: "test",
            folder: shell.appendingPathComponent("widgets/test")
        )
        settings.shellPermissions.setNetwork(.allowed, hosts: [host], for: principal)
        XCTAssertEqual(manager.shellPermissions.decide(host, for: principal), .allowed)
        var commands: [ShellRequest] = []
        let delivered = expectation(description: "the installed package reports the denial")
        let widgetHost = ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: motion),
            resourceStore: ShellResourceStore(directory: root.appendingPathComponent("resources")),
            permissions: manager.shellPermissions,
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { request, _ in
                commands.append(request)
                delivered.fulfill()
            },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
        manager.shellHost = widgetHost
        defer { manager.shellHost = nil
            widgetHost.stop()
        }
        await ShellWidgetHost.flushRetiredWork()
        widgetHost.start()
        let state = try XCTUnwrap(widgetHost.widgets["test"])
        let package = try XCTUnwrap(state.loadingPackage)
        await package.installHTTPStub(ProtocolStub.self)
        XCTAssertTrue(holdMainActor(until: started))
        XCTAssertNil(state.mailbox)
        XCTAssertTrue(state.loadingPackage === package)
        settings.shellPermissions.setNetwork(.denied, hosts: [host], for: principal)
        XCTAssertTrue(holdMainActor(until: stopped))
        XCTAssertNil(state.mailbox)
        XCTAssertTrue(state.loadingPackage === package)
        await fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(commands, [try XCTUnwrap(ShellRequest(words: ["switch-workspace", "7"]))])
        XCTAssertTrue(state.package === package)
    }

    private func holdMainActor(until event: DispatchSemaphore) -> Bool {
        event.wait(timeout: .now() + 10) == .success
    }

    private func componentRequests(_ requests: [String: String]) -> String {
        let cases = requests.sorted { $0.key < $1.key }.map { "{'\($0.key)','\($0.value)'}" }.joined(separator: ",")
        return """
        return { init=function()
            for _, case in {\(cases)} do
                assert(omniwm.http({url=case[2]},function(result)
                    omniwm.run(case[1] .. ' ' .. tostring(result.error) .. ' ' .. tostring(result.text))
                end))
            end
        end, views={compact=function() return ui.box{} end} }
        """
    }

    private func writeIsland(_ shell: URL, child module: String, hosts: [String], in layer: URL) throws {
        let root = shell.appendingPathComponent("widgets/island")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.renderComponents.utf8).write(to: root.appendingPathComponent("init.luau"))
        try writeChild(module, hosts: hosts, in: layer)
    }

    private func writeChild(_ module: String, hosts: [String], in layer: URL) throws {
        let folder = layer.appendingPathComponent("widgets/child")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let network = hosts.map { "'\($0)'" }.joined(separator: ", ")
        try Data("views = ['compact']\ncapabilities = { network = [\(network)] }\n".utf8)
            .write(to: folder.appendingPathComponent("component.toml"))
        try Data(module.utf8).write(to: folder.appendingPathComponent("component.luau"))
    }

    private func islandSource(_ shell: URL) throws -> ShellWidgetSource {
        try ShellWidgetSourceLoader.build(.init(
            name: "island",
            shellDirectory: shell,
            sourceURL: shell.appendingPathComponent("widgets/island/init.luau"),
            directories: [shell],
            profile: ShellDefaults.profile,
            components: [ShellComponentInstance(id: "child", widget: "child")]
        ))
    }
}
