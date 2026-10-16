// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class ShellConfigurationOutboxTests: XCTestCase {
    func testCancelAndReadmitBeforeMainDeliveryRetainsOnlyOutstandingRequests() async throws {
        let delivered = expectation(description: "bounded delivery")
        let outbox = ShellWidgetOutbox { batch in
            XCTAssertEqual(batch["root"]?.configurationRequests.count, 32)
            XCTAssertEqual(batch["root"]?.configurationRequests.first?.id.request, 3201)
            delivered.fulfill()
        }
        for round in 0 ... 100 {
            let requests = try (1 ... 32).map { try request(UInt64(round * 32 + $0)) }
            outbox.configure(name: "root", generation: 1, requests: requests)
            if round < 100 {
                for request in requests { outbox.cancelConfiguration(name: "root", generation: 1, id: request.id) }
            }
        }
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testCancelledInvocationRequestsDoNotReappearWhenInvocationCommits() async throws {
        let delivered = expectation(description: "invocation delivery")
        let request = try request(1)
        let outbox = ShellWidgetOutbox { batch in
            XCTAssertEqual(batch["root"]?.configurationRequests.count, 0)
            XCTAssertEqual(batch["root"]?.acknowledgements.count, 1)
            delivered.fulfill()
        }
        outbox.beginInvoke(name: "root", generation: 1)
        outbox.configure(name: "root", generation: 1, requests: [request])
        outbox.cancelConfiguration(name: "root", generation: 1, id: request.id)
        outbox.finishInvoke(
            name: "root",
            generation: 1,
            key: ShellTreeKey(bar: ShellBarKey(monitor: Monitor.ID(displayId: 1)), view: .bar),
            invocationID: 1,
            failed: false
        )
        await fulfillment(of: [delivered], timeout: 2)
    }

    private func request(_ id: UInt64) throws -> ShellConfigurationRequest {
        var writer = ShellValueWriter()
        writer.map(2)
        writer.key("op")
        writer.string("remove")
        writer.key("id")
        writer.string("clock")
        return try ShellConfigurationRequest(
            id: ShellServiceID(
                owner: ShellServiceOwner(generation: 1, owner: 0, epoch: 1),
                request: id
            ),
            bytes: writer.bytes
        )
    }
}
