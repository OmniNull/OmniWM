// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

@MainActor
final class ShellHTTPServiceTests: XCTestCase {
    private final class ProtocolStub: URLProtocol {
        struct Plan: Sendable {
            var status = 200
            var headers: [String: String] = [:]
            var chunks: [Data] = []
            var error: URLError.Code?
            var redirect: URL?
            var stall = false
            var started: @Sendable (URLRequest) -> Void = { _ in }
            var stopped: @Sendable () -> Void = {}
        }

        static let plans = Mutex<[String: Plan]>([:])
        private let activePlan = Mutex<Plan?>(nil)

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.hasSuffix(".example") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url, let plan = Self.plans.withLock({ $0[url.absoluteString] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            activePlan.withLock { $0 = plan }
            plan.started(request)
            if plan.stall { return }
            if let error = plan.error { client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: plan.status,
                httpVersion: "HTTP/1.1",
                headerFields: plan.headers
            )
            else { return }
            if let redirect = plan.redirect {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            let stopped = activePlan.withLock { $0?.stopped }
            stopped?()
        }
    }

    private indirect enum Value: Equatable {
        case null, bool(Bool), number(Double), string([UInt8]), array([Value]), map([String: Value])

        subscript(_ key: String) -> Value? {
            guard case let .map(values) = self else { return nil }
            return values[key]
        }

        static func text(_ text: String) -> Value {
            .string(Array(text.utf8))
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take<T>(_ type: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
        }

        mutating func string() -> [UInt8] {
            let count = Int(take(UInt32.self))
            defer { offset += count }
            return Array(bytes[offset ..< offset + count])
        }

        mutating func value() -> Value {
            switch omni_value_tag(rawValue: UInt32(take(UInt8.self))) {
            case OMNI_VALUE_NIL: return .null
            case OMNI_VALUE_FALSE: return .bool(false)
            case OMNI_VALUE_TRUE: return .bool(true)
            case OMNI_VALUE_NUMBER: return .number(take(Double.self))
            case OMNI_VALUE_STRING: return .string(string())
            case OMNI_VALUE_ARRAY:
                let count = Int(take(UInt32.self))
                return .array((0 ..< count).map { _ in value() })
            case OMNI_VALUE_MAP:
                let count = Int(take(UInt32.self))
                var values: [String: Value] = [:]
                for _ in 0 ..< count { let key = String(decoding: string(), as: UTF8.self)
                    values[key] = value()
                }
                return .map(values)
            default: XCTFail("unexpected value tag")
                return .null
            }
        }
    }

    private func id(_ request: UInt64 = 1, owner: UInt32 = 1) -> ShellServiceID {
        ShellServiceID(owner: ShellServiceOwner(generation: 42, owner: owner, epoch: 1), request: request)
    }

    private func url(host: String = "api.example") -> String {
        "https://\(host)/\(UUID().uuidString)"
    }

    private func run(
        _ plan: ProtocolStub.Plan, response: ShellHTTPRequest.Response = .text, maxBytes: Int = 1 << 20,
        timeout: Double = 30, policy: ShellHTTPPolicy = .hosts(["api.example"]),
        decodeJSON: @escaping @Sendable (Data) throws -> [UInt8] = ShellHTTPResponse.json
    ) async throws -> Value {
        let url = url()
        ProtocolStub.plans.withLock { $0[url] = plan }
        defer { _ = ProtocolStub.plans.withLock { $0.removeValue(forKey: url) } }
        let ledger = ShellServiceLedger(generation: 42)
        let service = ShellHTTPService(ledger: ledger, protocolClasses: [ProtocolStub.self], decodeJSON: decodeJSON)
        defer { ledger.close() }
        let completed = expectation(description: "HTTP completion")
        ledger.attachWake { completed.fulfill() }
        XCTAssertTrue(service.start(
            id(),
            request: ShellHTTPRequest(url: url, response: response, maxBytes: maxBytes, timeout: timeout),
            policy: policy
        ))
        await fulfillment(of: [completed], timeout: 5)
        let batch = ledger.takeBatch()
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(service.activeCount, 0)
        XCTAssertEqual(ledger.activeCount, 0)
        var reader = Reader(bytes: try XCTUnwrap(batch.first?.payload))
        let value = reader.value()
        XCTAssertEqual(reader.offset, reader.bytes.count)
        return value
    }

    func testTextStatusAndResponseHeaders() async throws {
        let result = try await run(.init(headers: ["X-Test": "present"], chunks: [Data("hello".utf8)]))
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["status"], .number(200))
        XCTAssertEqual(result["text"], .text("hello"))
        XCTAssertEqual(result["headers"]?["x-test"], .text("present"))
        let rejected = try await run(.init(status: 503, chunks: [Data("unavailable".utf8)]))
        XCTAssertEqual(rejected["ok"], .bool(false))
        XCTAssertEqual(rejected["status"], .number(503))
        XCTAssertEqual(rejected["error"], .text("http_status"))
        XCTAssertEqual(rejected["text"], .text("unavailable"))
    }

    func testJSONDecodesOffMainWithNullBooleanAndEmptyArray() async throws {
        let decodedOffMain = Mutex(false)
        let result = try await run(
            .init(chunks: [Data("{\"nil\":null,\"true\":true,\"number\":1,\"empty\":[],\"array\":[null,2]}".utf8)]),
            response: .json
        ) { data in
            decodedOffMain.withLock { $0 = !Thread.isMainThread }
            return try ShellHTTPResponse.json(data)
        }
        XCTAssertTrue(decodedOffMain.withLock { $0 })
        XCTAssertEqual(result["json"]?["nil"], .null)
        XCTAssertEqual(result["json"]?["true"], .bool(true))
        XCTAssertEqual(result["json"]?["number"], .number(1))
        XCTAssertEqual(result["json"]?["empty"], .array([]))
        XCTAssertEqual(result["json"]?["array"], .array([.null, .number(2)]))
    }

    func testInvalidJSONOmitsReplacementValueAndBinaryDataIsExact() async throws {
        let result = try await run(.init(chunks: [Data("{broken".utf8)]), response: .json)
        XCTAssertEqual(result["error"], .text("invalid_json"))
        XCTAssertNil(result["json"])
        let bytes: [UInt8] = [0, 255, 128, 13, 10]
        let binary = try await run(.init(chunks: [Data(bytes)]), response: .bytes)
        XCTAssertEqual(binary["bytes"], .string(bytes))
        let text = try await run(.init(chunks: [Data(bytes)]))
        XCTAssertEqual(text["error"], .text("invalid_utf8"))
    }

    func testStreamingAndDeclaredLengthLimitsRejectExplicitly() async throws {
        let streamed = try await run(
            .init(chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 6)]),
            maxBytes: 10
        )
        XCTAssertEqual(streamed["error"], .text("response_too_large"))
        XCTAssertNil(streamed["text"])
        let declared = try await run(.init(headers: ["Content-Length": "100"], chunks: []), maxBytes: 10)
        XCTAssertEqual(declared["error"], .text("response_too_large"))
    }

    func testExternalDeadlineAndURLSessionTimeoutHaveSameExplicitResult() async throws {
        let deadline = try await run(.init(stall: true), timeout: 0.02)
        XCTAssertEqual(deadline["error"], .text("timeout"))
        let session = try await run(.init(error: .timedOut))
        XCTAssertEqual(session["error"], .text("timeout"))
    }

    func testPolicyUsesExactHostsAndRejectsBeforeStarting() async throws {
        let started = Mutex(false)
        let result = try await run(
            .init(started: { _ in started.withLock { $0 = true } }),
            policy: .hosts(["other.example"])
        )
        XCTAssertEqual(result["error"], .text("network_denied"))
        XCTAssertFalse(started.withLock { $0 })
        let policy = ShellHTTPPolicy.hosts([ShellHTTPPolicy.canonicalHost("API.EXAMPLE.")])
        XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://api.example/path"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://sub.api.example/path"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "file://api.example/path"))))
    }

    func testPlainHTTPIsAllowedOnlyForDeclaredLoopbackHosts() throws {
        let policy = ShellHTTPPolicy.hosts(["api.example", "localhost", "127.0.0.1", "::1", "127.0.0.1.example"])
        let cases = [
            "https://api.example/path": true, "http://api.example/path": false,
            "http://localhost:8080/path": true, "http://LOCALHOST./path": true, "http://127.0.0.1/path": true,
            "http://[::1]:8080/path": true, "http://127.0.0.1.example/path": false, "https://localhost/path": true
        ]
        for (url, allowed) in cases {
            XCTAssertEqual(policy.allows(try XCTUnwrap(URL(string: url))), allowed, url)
        }
        XCTAssertFalse(ShellHTTPPolicy.hosts(["api.example"]).allows(try XCTUnwrap(URL(string: "http://localhost/"))))
    }

    func testRedirectToUndeclaredHostIsRejected() async throws {
        let target = try XCTUnwrap(URL(string: url(host: "unlisted.example")))
        let targetStarted = Mutex(false)
        ProtocolStub.plans
            .withLock { $0[target.absoluteString] = .init(started: { _ in targetStarted.withLock { $0 = true } }) }
        defer { _ = ProtocolStub.plans.withLock { $0.removeValue(forKey: target.absoluteString) } }
        let result = try await run(
            .init(status: 302, headers: ["Location": target.absoluteString], redirect: target),
            policy: .hosts(["api.example"])
        )
        XCTAssertEqual(result["error"], .text("network_denied"))
        XCTAssertFalse(targetStarted.withLock { $0 })
    }

    func testComponentPolicyCombinesManifestAndUserHostsAndDeniesRemovedOwners() throws {
        let descriptor = ShellComponentDescriptor(
            widget: "ci", title: "CI", icon: "", views: [], uses: [], options: [:],
            capabilities: .init(network: ["API.EXAMPLE."]), providerCommand: nil,
            folder: URL(fileURLWithPath: "/unused")
        )
        var instance = ShellComponentInstance(id: "jobs", widget: "ci", capabilities: .init(network: ["extra.example"]))
        let policy = ShellHTTPPolicy.resolve(component: "jobs", instances: [instance], descriptors: [descriptor])
        for host in ["api.example", "extra.example"] {
            XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: "https://\(host)/path"))))
        }
        instance.enabled = false
        XCTAssertFalse(ShellHTTPPolicy.resolve(component: "jobs", instances: [instance], descriptors: [descriptor])
            .allows(try XCTUnwrap(URL(string: "https://api.example/path"))))
        XCTAssertFalse(ShellHTTPPolicy.resolve(component: "missing", instances: [instance], descriptors: [descriptor])
            .allows(try XCTUnwrap(URL(string: "https://api.example/path"))))
        XCTAssertFalse(ShellHTTPPolicy.resolve(component: nil, instances: [], descriptors: [])
            .allows(try XCTUnwrap(URL(string: "https://other.example/path"))))
    }

    func testCancellationAndOwnerRemovalStopTasksWithoutCompletion() async throws {
        let ledger = ShellServiceLedger(generation: 42)
        let service = ShellHTTPService(ledger: ledger, protocolClasses: [ProtocolStub.self])
        let started = expectation(description: "two tasks started")
        started.expectedFulfillmentCount = 2
        let stopped = expectation(description: "two tasks stopped")
        stopped.expectedFulfillmentCount = 2
        let urls = [url(), url()]
        for url in urls { ProtocolStub.plans.withLock { $0[url] = .init(
            stall: true,
            started: { _ in started.fulfill() },
            stopped: { stopped.fulfill() }
        ) } }
        defer { ledger.close()
            ProtocolStub.plans.withLock { plans in for url in urls { plans.removeValue(forKey: url) } }
        }
        XCTAssertTrue(service.start(id(1, owner: 1), request: .init(url: urls[0]), policy: .hosts(["api.example"])))
        XCTAssertTrue(service.start(id(2, owner: 2), request: .init(url: urls[1]), policy: .hosts(["api.example"])))
        await fulfillment(of: [started], timeout: 5)
        ledger.cancel(id(1, owner: 1))
        XCTAssertEqual(ledger.activeCount, 1)
        ledger.cancel(owner: id(2, owner: 2).owner)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(service.activeCount, 0)
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertEqual(ledger.pendingCount, 0)
    }

    func testBurstNeverStartsMoreThanSixNativeRequests() async throws {
        let ledger = ShellServiceLedger(generation: 42)
        let service = ShellHTTPService(ledger: ledger, protocolClasses: [ProtocolStub.self])
        let started = expectation(description: "six admitted requests started")
        started.expectedFulfillmentCount = 6
        let overloaded = expectation(description: "remaining requests rejected explicitly")
        overloaded.expectedFulfillmentCount = 26
        let results = Mutex<[[UInt8]]>([])
        ledger.attachWake {
            for completion in ledger.takeBatch() { results.withLock { $0.append(completion.payload) }
                overloaded.fulfill()
            }
            _ = ledger.finishBatch()
        }
        let urls = (0 ..< 32).map { _ in url() }
        defer { ledger.close()
            ProtocolStub.plans.withLock { plans in for url in urls { plans.removeValue(forKey: url) } }
        }
        for (index, url) in urls.enumerated() {
            ProtocolStub.plans.withLock { $0[url] = .init(stall: true, started: { _ in started.fulfill() }) }
            XCTAssertTrue(service.start(
                id(UInt64(index + 1)),
                request: .init(url: url),
                policy: .hosts(["api.example"])
            ))
        }
        await fulfillment(of: [started, overloaded], timeout: 5)
        XCTAssertEqual(service.activeCount, 6)
        XCTAssertEqual(ledger.activeCount, 6)
        for bytes in results.withLock({ $0 }) { var reader = Reader(bytes: bytes)
            XCTAssertEqual(reader.value()["error"], .text("overloaded"))
        }
        ledger.cancel(owner: id().owner)
        XCTAssertEqual(service.activeCount, 0)
    }

    func testJSONDepthAndExpandedWireAreBounded() throws {
        XCTAssertThrowsError(try ShellHTTPResponse.json(Data((String(repeating: "[", count: 65) + "0" + String(
            repeating: "]",
            count: 65
        )).utf8))) {
            XCTAssertEqual($0 as? ShellHTTPFailure, .init("invalid_json"))
        }
        let count = ShellHTTPService.byteLimit / 9
        let large = "[" + String(repeating: "0,", count: count) + "0]"
        XCTAssertLessThan(large.utf8.count, ShellHTTPService.byteLimit)
        XCTAssertThrowsError(try ShellHTTPResponse.json(Data(large.utf8))) {
            XCTAssertEqual($0 as? ShellHTTPFailure, .init("decoded_response_too_large"))
        }
        let bracesInString = "{\"text\":\"" + String(repeating: "[", count: 80) + "\"}"
        XCTAssertNoThrow(try ShellHTTPResponse.json(Data(bracesInString.utf8)))
    }

    func testMaximumBodyAndEncodedHeadersFitServiceEnvelope() {
        let body = Data(repeating: 65, count: ShellHTTPService.byteLimit)
        let headers = ["x": String(repeating: "v", count: ShellHTTPService.headerLimit - 15)]
        XCTAssertTrue(ShellHTTPResponse.headersFit(headers))
        let encoded = ShellHTTPResponse.encode(status: 200, headers: headers, body: body, response: .bytes, error: nil)
        XCTAssertLessThanOrEqual(encoded.count, ShellHTTPResponse.envelopeLimit)
        var reader = Reader(bytes: encoded)
        let result = reader.value()
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["bytes"], .string(Array(body)))
        XCTAssertEqual(result["headers"]?["x"], .text(headers["x"]!))
        XCTAssertEqual(reader.offset, encoded.count)
    }

    func testEncodedHeaderOverheadIsBoundedAndErrorIsValidUTF8() {
        let headers = ["x": String(repeating: "v", count: ShellHTTPService.headerLimit - 14)]
        XCTAssertFalse(ShellHTTPResponse.headersFit(headers))
        var reader = Reader(bytes: ShellHTTPResponse.encode(
            status: 200,
            headers: headers,
            body: Data(),
            response: .text,
            error: nil
        ))
        let rejected = reader.value()
        XCTAssertEqual(rejected["error"], .text("response_headers_too_large"))
        XCTAssertEqual(rejected["headers"], .map([:]))
        XCTAssertNil(rejected["text"])
        let message = String(repeating: "a", count: 1022) + "🦊"
        reader = Reader(bytes: ShellHTTPResponse.failure(message))
        let failed = reader.value()
        XCTAssertEqual(failed["error"], .text(String(repeating: "a", count: 1022)))
    }

    func testDepth64JSONSurvivesResponseEnvelope() {
        let json = String(repeating: "[", count: 64) + "null" + String(repeating: "]", count: 64)
        let encoded = ShellHTTPResponse.encode(
            status: 200,
            headers: [:],
            body: Data(json.utf8),
            response: .json,
            error: nil
        )
        var reader = Reader(bytes: encoded)
        let result = reader.value()
        XCTAssertEqual(result["ok"], .bool(true))
        var value = result["json"]
        for _ in 0 ..< 64 {
            guard case let .array(children) = value, children.count == 1 else {
                XCTFail("missing nested JSON array")
                return
            }
            value = children[0]
        }
        XCTAssertEqual(value, .null)
        XCTAssertEqual(reader.offset, encoded.count)
    }
}
