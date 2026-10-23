// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

enum ShellHTTPPolicy: Sendable {
    case hosts(Set<String>)

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func resolve(
        component: String?, instances: some Sequence<ShellComponentInstance>, descriptors: [ShellComponentDescriptor]
    ) -> ShellHTTPPolicy {
        guard let component, !component.isEmpty else { return .hosts([]) }
        guard let instance = instances.first(where: { $0.id == component && $0.enabled }),
              let descriptor = descriptors.first(where: { $0.widget == instance.widget })
        else { return .hosts([]) }
        return .hosts(Set((descriptor.capabilities.network + (instance.capabilities?.network ?? []))
                .map(canonicalHost)))
    }

    static func canonicalHost(_ host: String) -> String {
        var result = host.lowercased()
        while result.last == "." { result.removeLast() }
        return result
    }

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return false }
        let canonical = Self.canonicalHost(host)
        guard scheme == "https" || scheme == "http" && Self.loopbackHosts.contains(canonical) else { return false }
        switch self {
        case let .hosts(hosts): return hosts.contains(canonical)
        }
    }
}

struct ShellHTTPRequest: Sendable {
    enum Response: String, Sendable {
        case text, json, bytes
    }

    var url: String
    var method = "GET"
    var headers: [String: String] = [:]
    var body: [UInt8]?
    var bodyResource: ShellResourceID?
    var response = Response.text
    var maxBytes = 1 << 20
    var timeout = 30.0

    func request() throws -> URLRequest {
        guard bodyResource == nil else { throw ShellHTTPFailure("resource_not_prepared") }
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { throw ShellHTTPFailure("invalid_url") }
        guard (1 ... ShellHTTPService.byteLimit).contains(maxBytes),
              timeout.isFinite, timeout > 0, timeout <= ShellHTTPService.timeoutLimit,
              Self.isToken(method), method.utf8.count <= 32, headers.count <= 128
        else { throw ShellHTTPFailure("invalid_request") }
        guard (body?.count ?? 0) <= ShellHTTPService.byteLimit else { throw ShellHTTPFailure("body_too_large") }
        var headerBytes = 0
        for (key, value) in headers {
            headerBytes += key.utf8.count + value.utf8.count
            guard Self.isToken(key), headerBytes <= ShellHTTPService.headerLimit,
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 })
            else { throw ShellHTTPFailure("invalid_request") }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.httpBody = body.map { Data($0) }
        request.httpShouldHandleCookies = false
        return request
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }
}

struct ShellHTTPFailure: Error, Equatable, Sendable {
    let code: String

    init(_ code: String) {
        self.code = code
    }
}

final class ShellHTTPService: Sendable {
    static let flightLimit = 6
    static let byteLimit = 4 << 20
    static let headerLimit = 64 << 10
    static let timeoutLimit = 120.0

    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var reservedBegin = 0
        var reservedEnd = 0
        var reservedPeak = 0
        var tasksBegin = 0
        var tasksEnd = 0
        var tasksPeak = 0
        var taskStarts: UInt64 = 0
        var jsonAttempts: UInt64 = 0
        var jsonSuccesses: UInt64 = 0

        var detail: String {
            "utility=http reserved_begin=\(reservedBegin) reserved_end=\(reservedEnd) reserved_peak=\(reservedPeak)"
                + " task_begin=\(tasksBegin) task_end=\(tasksEnd) task_peak=\(tasksPeak) task_starts=\(taskStarts)"
                + " json_attempts=\(jsonAttempts) json_successes=\(jsonSuccesses) task_scope=owned_urlsession"
        }
    }

    private let driver: Driver
    private let session: URLSession
    private let ledger: ShellServiceLedger

    init(
        ledger: ShellServiceLedger,
        captureID: UInt64 = 0,
        protocolClasses: [AnyClass]? = nil,
        decodeJSON: @escaping @Sendable (Data) throws -> [UInt8] = ShellHTTPResponse.json
    ) {
        self.ledger = ledger
        let driver = Driver(ledger: ledger, decodeJSON: decodeJSON)
        driver.captureBegin(captureID)
        self.driver = driver
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = Self.flightLimit
        configuration.timeoutIntervalForRequest = Self.timeoutLimit
        configuration.timeoutIntervalForResource = Self.timeoutLimit
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.barut.OmniWM.shell.http.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = driver.queue
        session = URLSession(configuration: configuration, delegate: driver, delegateQueue: delegateQueue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    var activeCount: Int {
        driver.activeCount
    }

    func captureBegin(_ id: UInt64) async {
        let driver = driver
        await withCheckedContinuation { continuation in
            driver.queue.async {
                driver.captureBegin(id)
                continuation.resume()
            }
        }
    }

    func captureEnd(_ id: UInt64) async -> Capture? {
        let driver = driver
        return await withCheckedContinuation { continuation in
            driver.queue.async { continuation.resume(returning: driver.captureEnd(id)) }
        }
    }

    @discardableResult
    func start(
        _ id: ShellServiceID,
        request: ShellHTTPRequest,
        policy: ShellHTTPPolicy,
        registered: Bool = false
    ) -> Bool {
        let accepted = driver.reserve(id, request: request, policy: policy)
        let cancel: @Sendable () -> Void = { [driver] in driver.cancel(id) }
        guard registered ? ledger.adopt(id, cancel: cancel) : ledger.register(id, cancel: cancel) else {
            if accepted { driver.cancel(id) }
            return false
        }
        driver.queue.async { [driver, session, ledger] in
            if accepted {
                driver.start(id, session: session)
            } else {
                ledger.complete(ShellServiceCompletion(id: id, payload: ShellHTTPResponse.failure("overloaded")))
            }
        }
        return true
    }

    struct TransferState {
        var task: URLSessionDataTask?
        var deadline: (any DispatchSourceTimer)?
        var body = Data()
        var status = 0
        var headers: [String: String] = [:]
        var finished = false
    }

    private final class Transfer: Sendable {
        let id: ShellServiceID
        let request: ShellHTTPRequest
        let policy: ShellHTTPPolicy
        let state = Mutex(TransferState())

        init(id: ShellServiceID, request: ShellHTTPRequest, policy: ShellHTTPPolicy) {
            self.id = id
            self.request = request
            self.policy = policy
        }
    }

    private struct DriverState {
        var transfers: [ShellServiceID: Transfer] = [:]
        var tasks: [Int: ShellServiceID] = [:]
        var capture = Capture()
    }

    private final class Driver: NSObject, URLSessionDataDelegate, Sendable {
        let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.http", qos: .utility)
        private let state = Mutex(DriverState())
        private let ledger: ShellServiceLedger
        private let decodeJSON: @Sendable (Data) throws -> [UInt8]

        init(ledger: ShellServiceLedger, decodeJSON: @escaping @Sendable (Data) throws -> [UInt8]) {
            self.ledger = ledger
            self.decodeJSON = decodeJSON
        }

        var activeCount: Int {
            state.withLock { $0.transfers.count }
        }

        func captureBegin(_ id: UInt64) {
            state.withLock {
                guard id != 0, $0.capture.id != id else { return }
                $0.capture = Capture(
                    id: id, reservedBegin: $0.transfers.count, reservedPeak: $0.transfers.count,
                    tasksBegin: $0.tasks.count, tasksPeak: $0.tasks.count
                )
            }
        }

        func captureEnd(_ id: UInt64) -> Capture? {
            state.withLock {
                guard id != 0, $0.capture.id == id else { return nil }
                $0.capture.reservedEnd = $0.transfers.count
                $0.capture.tasksEnd = $0.tasks.count
                defer { $0.capture = Capture() }
                return $0.capture
            }
        }

        func reserve(_ id: ShellServiceID, request: ShellHTTPRequest, policy: ShellHTTPPolicy) -> Bool {
            state.withLock { state in
                guard state.transfers.count < ShellHTTPService.flightLimit,
                      state.transfers[id] == nil else { return false }
                state.transfers[id] = Transfer(id: id, request: request, policy: policy)
                if state.capture.id != 0 {
                    state.capture.reservedPeak = max(state.capture.reservedPeak, state.transfers.count)
                }
                return true
            }
        }

        func start(_ id: ShellServiceID, session: URLSession) {
            guard let transfer = state.withLock({ $0.transfers[id] }) else { return }
            do {
                let request = try transfer.request.request()
                guard let url = request.url,
                      transfer.policy.allows(url) else { throw ShellHTTPFailure("network_denied") }
                let task = session.dataTask(with: request)
                let deadline = DispatchSource.makeTimerSource(queue: queue)
                deadline.schedule(deadline: .now() + transfer.request.timeout)
                deadline.setEventHandler { [weak self] in self?.finish(id, error: "timeout") }
                let started = state.withLock { state in
                    guard state.transfers[id] === transfer else { return false }
                    state.tasks[task.taskIdentifier] = id
                    if state.capture.id != 0 {
                        state.capture.taskStarts &+= 1
                        state.capture.tasksPeak = max(state.capture.tasksPeak, state.tasks.count)
                    }
                    transfer.state.withLock { $0.task = task
                        $0.deadline = deadline
                    }
                    return true
                }
                deadline.resume()
                if started { task.resume() } else { deadline.cancel()
                    task.cancel()
                }
            } catch {
                finish(id, error: (error as? ShellHTTPFailure)?.code ?? "invalid_request")
            }
        }

        func cancel(_ id: ShellServiceID) {
            guard let removed = remove(id) else { return }
            let transfer = removed.transfer
            let task = transfer.state.withLock { state in
                state.finished = true
                state.deadline?.cancel()
                state.deadline = nil
                state.body = Data()
                defer { state.task = nil }
                return state.task
            }
            task?.cancel()
        }

        private func remove(_ id: ShellServiceID) -> (transfer: Transfer, captureID: UInt64)? {
            state.withLock { state in
                guard let transfer = state.transfers.removeValue(forKey: id) else { return nil }
                if let task = transfer.state
                    .withLock({ $0.task }) { state.tasks.removeValue(forKey: task.taskIdentifier) }
                return (transfer, state.capture.id)
            }
        }

        private func transfer(for task: URLSessionTask) -> Transfer? {
            state.withLock { state in state.tasks[task.taskIdentifier].flatMap { state.transfers[$0] } }
        }

        private func finish(_ id: ShellServiceID, error: String? = nil) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard let removed = remove(id) else { return }
            let transfer = removed.transfer
            let snapshot = transfer.state.withLock { state in
                state.finished = true
                state.deadline?.cancel()
                state.deadline = nil
                let result = (state.body, state.status, state.headers, state.task)
                state.body = Data()
                state.task = nil
                return result
            }
            if error != nil { snapshot.3?.cancel() }
            let decoder: @Sendable (Data) throws -> [UInt8]
            if removed.captureID == 0 { decoder = decodeJSON }
            else {
                decoder = { [self] data in
                    state.withLock {
                        if $0.capture.id == removed.captureID { $0.capture.jsonAttempts &+= 1 }
                    }
                    let decoded = try decodeJSON(data)
                    state.withLock {
                        if $0.capture.id == removed.captureID { $0.capture.jsonSuccesses &+= 1 }
                    }
                    return decoded
                }
            }
            let bytes = ShellHTTPResponse.encode(
                status: snapshot.1, headers: snapshot.2, body: snapshot.0,
                response: transfer.request.response, error: error, decodeJSON: decoder
            )
            ledger.complete(ShellServiceCompletion(id: id, payload: bytes))
        }

        func urlSession(
            _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let transfer = transfer(for: dataTask), let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                if let transfer = transfer(for: dataTask) { finish(transfer.id, error: "invalid_response") }
                return
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
                if let key = field.key as? String { result[key.lowercased()] = String(describing: field.value) }
            }
            let validHeaders = ShellHTTPResponse.headersFit(headers)
            transfer.state.withLock { state in state.status = response.statusCode
                state.headers = validHeaders ? headers : [:]
            }
            let error = !validHeaders ? "response_headers_too_large"
                : response.expectedContentLength > Int64(transfer.request.maxBytes) ? "response_too_large" : nil
            if let error { completionHandler(.cancel)
                finish(transfer.id, error: error)
            } else { completionHandler(.allow) }
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let transfer = transfer(for: dataTask) else { return }
            let overflow = transfer.state.withLock { state in
                guard !state.finished else { return false }
                guard data.count <= transfer.request.maxBytes - state.body.count else { return true }
                state.body.append(data)
                return false
            }
            if overflow { finish(transfer.id, error: "response_too_large") }
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let transfer = transfer(for: task) else { return }
            let code: String? = error.map {
                ($0 as? URLError)?.code == .timedOut ? "timeout" : "network"
            }
            finish(transfer.id, error: code)
        }

        func urlSession(
            _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let transfer = transfer(for: task), let url = request.url, transfer.policy.allows(url) else {
                completionHandler(nil)
                if let transfer = transfer(for: task) { finish(transfer.id, error: "network_denied") }
                return
            }
            completionHandler(request)
        }
    }
}
