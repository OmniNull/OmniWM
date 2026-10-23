// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellHTTPUtilityCaptureTests: XCTestCase {
    private final class ProtocolStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "capture.example"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((url.path.hasPrefix("/invalid/") ? "{" : "{}").utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testCountsTransfersAndActualJSONAttemptsSeparatelyFromAdmission() async throws {
        let owner = ShellServiceOwner(generation: 42, owner: 1, epoch: 1)
        let ledger = ShellServiceLedger(generation: 42)
        let service = ShellHTTPService(ledger: ledger, captureID: 7, protocolClasses: [ProtocolStub.self])
        defer { ledger.close() }
        await service.captureBegin(7)
        for (index, kind) in ["valid", "invalid", "denied"].enumerated() {
            let completion = expectation(description: kind)
            ledger.attachWake { completion.fulfill() }
            XCTAssertTrue(service.start(
                .init(owner: owner, request: UInt64(index + 1)),
                request: ShellHTTPRequest(url: "https://capture.example/\(kind)/\(UUID().uuidString)", response: .json),
                policy: .hosts(kind == "denied" ? [] : ["capture.example"])
            ))
            await fulfillment(of: [completion], timeout: 5)
            XCTAssertEqual(ledger.takeBatch().count, 1)
            XCTAssertFalse(ledger.finishBatch())
        }
        let wrong = await service.captureEnd(8)
        XCTAssertNil(wrong)
        let ended = await service.captureEnd(7)
        let capture = try XCTUnwrap(ended)
        XCTAssertEqual(capture.reservedBegin, 0)
        XCTAssertEqual(capture.reservedPeak, 1)
        XCTAssertEqual(capture.reservedEnd, 0)
        XCTAssertEqual(capture.tasksBegin, 0)
        XCTAssertEqual(capture.tasksPeak, 1)
        XCTAssertEqual(capture.tasksEnd, 0)
        XCTAssertEqual(capture.taskStarts, 2)
        XCTAssertEqual(capture.jsonAttempts, 2)
        XCTAssertEqual(capture.jsonSuccesses, 1)
        let duplicate = await service.captureEnd(7)
        XCTAssertNil(duplicate)
        await service.captureBegin(8)
        let empty = await service.captureEnd(8)
        XCTAssertEqual(empty?.jsonAttempts, 0)
    }
}
