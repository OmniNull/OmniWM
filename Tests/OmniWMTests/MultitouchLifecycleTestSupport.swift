// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreHID
import Foundation
import IOKit
@testable import OmniWM
import XCTest

@MainActor
final class ManualMultitouchSleeper {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var requestedDurations: [Duration] = []
    private var nextId: UInt64 = 0
    private var waiters: [Waiter] = []
    private var requestWaiters: [(count: Int, expectation: XCTestExpectation)] = []
    private var wakeWaiters: [UInt64: XCTestExpectation] = [:]

    private enum WaitFailure: Error {
        case missingRequest(expected: Int, actual: Int)
        case noPendingSleep
        case wakeDidNotComplete(UInt64)
    }

    var pendingCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        nextId &+= 1
        let id = nextId
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                resumeRequestWaiters()
            }
            wakeWaiters.removeValue(forKey: id)?.fulfill()
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func waitForRequests(_ count: Int) async throws {
        guard requestedDurations.count < count else { return }
        let requested = XCTestExpectation(description: "Multitouch sleep request \(count)")
        requestWaiters.append((count, requested))
        defer { requestWaiters.removeAll { $0.expectation === requested } }
        guard await XCTWaiter.fulfillment(of: [requested], timeout: failureBound) == .completed,
              requestedDurations.count >= count
        else {
            throw WaitFailure.missingRequest(expected: count, actual: requestedDurations.count)
        }
    }

    func waitForScheduledSleep(of source: MultitouchGestureSource) async throws {
        guard waiters.isEmpty, source.diagnosticsSnapshot().nextRetryDelay != nil else { return }
        try await waitForRequests(requestedDurations.count + 1)
    }

    func resumeNext() async throws {
        guard !waiters.isEmpty else { throw WaitFailure.noPendingSleep }
        try await wake(waiters.removeFirst())
    }

    func resumeAll() async {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            do {
                try await wake(waiter)
            } catch {
                XCTFail("Multitouch sleep cleanup did not complete: \(error)")
            }
        }
    }

    private func wake(_ waiter: Waiter) async throws {
        let woke = XCTestExpectation(description: "Multitouch sleep \(waiter.id) returned")
        wakeWaiters[waiter.id] = woke
        defer { wakeWaiters.removeValue(forKey: waiter.id) }
        waiter.continuation.resume()
        guard await XCTWaiter.fulfillment(of: [woke], timeout: failureBound) == .completed else {
            throw WaitFailure.wakeDidNotComplete(waiter.id)
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { $0.count <= requestedDurations.count }
        requestWaiters.removeAll { $0.count <= requestedDurations.count }
        for (_, expected) in ready {
            expected.fulfill()
        }
    }

    private func cancel(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

@MainActor
final class FakeTopologyMonitor {
    let sleeper = ManualMultitouchSleeper()
    var signalsByStream: [[MultitouchGestureSource.TopologySignal]] = []
    private(set) var streamCount = 0

    func operations() -> MultitouchGestureSource.TopologyMonitoringOperations {
        MultitouchGestureSource.TopologyMonitoringOperations(
            notifications: {
                self.streamCount += 1
                let signals = self.signalsByStream.isEmpty ? [] : self.signalsByStream.removeFirst()
                return MultitouchGestureSource.TopologyMonitoringOperations.Notifications { continuation in
                    for signal in signals {
                        continuation.yield(signal)
                    }
                    continuation.finish()
                }
            },
            sleep: { try await self.sleeper.sleep(for: $0) }
        )
    }
}

@MainActor
final class FakeMultitouchBackend {
    enum Call: Equatable {
        case enumerate
        case register(UInt64)
        case start(UInt64)
        case running(UInt64)
        case stop(UInt64)
        case unregister(UInt64)
    }

    var enumerations: [MultitouchBinding.Enumeration] = []
    var registerResults: [UInt64: [Bool]] = [:]
    var startResults: [UInt64: [Int32]] = [:]
    var runningResults: [UInt64: [Bool]] = [:]
    var stopResults: [UInt64: [Int32]] = [:]
    var unregisterResults: [UInt64: [Bool]] = [:]
    private(set) var calls: [Call] = []
    private(set) var registeredGenerations: [UInt] = []
    private(set) var registeredSlots: [Int] = []

    private var enumerationIndex = 0
    private var registryIdByPointer: [UInt: UInt64] = [:]
    private var callbackByRegistryId: [
        UInt64: (
            device: MultitouchBinding.DeviceRef,
            callback: MultitouchBinding.ContactCallback,
            refcon: UnsafeMutableRawPointer
        )
    ] = [:]

    static func device(pointer: UInt, registryId: UInt64, senderId: UInt64? = nil) -> MultitouchBinding.Device {
        MultitouchBinding.Device(ref: OpaquePointer(bitPattern: pointer)!, registryId: registryId, senderId: senderId)
    }

    static func enumeration(_ devices: [MultitouchBinding.Device]) -> MultitouchBinding.Enumeration {
        MultitouchBinding.Enumeration(
            list: nil,
            devices: devices,
            outcome: devices.isEmpty ? .empty : .success(devices.count)
        )
    }

    static func failedEnumeration(
        _ outcome: MultitouchBinding.EnumerationOutcome
    ) -> MultitouchBinding.Enumeration {
        MultitouchBinding.Enumeration(list: nil, devices: [], outcome: outcome)
    }

    func operations(sleeper: ManualMultitouchSleeper) -> MultitouchGestureSource.LifecycleOperations {
        MultitouchGestureSource.LifecycleOperations(
            enumerate: { self.enumerate() },
            register: { self.register($0, callback: $1, refcon: $2) },
            start: { self.start($0) },
            isRunning: { self.isRunning($0) },
            stop: { self.stop($0) },
            unregister: { ref, _ in self.unregister(ref) },
            sleep: { try await sleeper.sleep(for: $0) }
        )
    }

    func callCount(_ expected: Call) -> Int {
        calls.count(where: { $0 == expected })
    }

    func emitFrame(
        registryId: UInt64,
        touches: [(x: Float, y: Float)],
        timestamp: Double,
        refcon: UnsafeMutableRawPointer? = nil
    ) {
        guard let registration = callbackByRegistryId[registryId] else { return }
        let stride = 96
        let fingers = UnsafeMutableRawPointer.allocate(byteCount: max(touches.count, 1) * stride, alignment: 8)
        defer { fingers.deallocate() }
        for (index, touch) in touches.enumerated() {
            let base = index * stride
            fingers.storeBytes(of: Int32(4), toByteOffset: base + 20, as: Int32.self)
            fingers.storeBytes(of: touch.x, toByteOffset: base + 32, as: Float.self)
            fingers.storeBytes(of: touch.y, toByteOffset: base + 36, as: Float.self)
        }
        _ = registration.callback(
            registration.device,
            touches.isEmpty ? nil : fingers,
            Int32(touches.count),
            timestamp,
            0,
            refcon ?? registration.refcon
        )
    }

    private func enumerate() -> MultitouchBinding.Enumeration {
        calls.append(.enumerate)
        guard !enumerations.isEmpty else {
            return Self.failedEnumeration(.unavailable)
        }
        let index = min(enumerationIndex, enumerations.count - 1)
        enumerationIndex += 1
        let enumeration = enumerations[index]
        for device in enumeration.devices {
            registryIdByPointer[UInt(bitPattern: device.ref)] = device.registryId
        }
        return enumeration
    }

    private func register(
        _ ref: MultitouchBinding.DeviceRef,
        callback: MultitouchBinding.ContactCallback,
        refcon: UnsafeMutableRawPointer
    ) -> Bool {
        let registryId = registryId(for: ref)
        calls.append(.register(registryId))
        let token = MultitouchGestureSource.RegistrationToken(bitPattern: UInt(bitPattern: refcon))
        registeredGenerations.append(token.generation)
        registeredSlots.append(token.slot)
        let registered = nextResult(from: &registerResults, for: registryId) ?? true
        if registered {
            callbackByRegistryId[registryId] = (ref, callback, refcon)
        }
        return registered
    }

    private func start(_ ref: MultitouchBinding.DeviceRef) -> Int32 {
        let registryId = registryId(for: ref)
        calls.append(.start(registryId))
        return nextResult(from: &startResults, for: registryId) ?? KERN_SUCCESS
    }

    private func isRunning(_ ref: MultitouchBinding.DeviceRef) -> Bool {
        let registryId = registryId(for: ref)
        calls.append(.running(registryId))
        return nextResult(from: &runningResults, for: registryId) ?? true
    }

    private func stop(_ ref: MultitouchBinding.DeviceRef) -> Int32 {
        let registryId = registryId(for: ref)
        calls.append(.stop(registryId))
        return nextResult(from: &stopResults, for: registryId) ?? KERN_SUCCESS
    }

    private func unregister(_ ref: MultitouchBinding.DeviceRef) -> Bool {
        let registryId = registryId(for: ref)
        calls.append(.unregister(registryId))
        callbackByRegistryId.removeValue(forKey: registryId)
        return nextResult(from: &unregisterResults, for: registryId) ?? true
    }

    private func registryId(for ref: MultitouchBinding.DeviceRef) -> UInt64 {
        registryIdByPointer[UInt(bitPattern: ref)] ?? 0
    }

    private func nextResult<T>(from results: inout [UInt64: [T]], for registryId: UInt64) -> T? {
        guard var values = results[registryId], !values.isEmpty else { return nil }
        let value = values.removeFirst()
        results[registryId] = values
        return value
    }
}

@MainActor
func drainMultitouchTasks() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
