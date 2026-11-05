// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Dispatch
@testable import OmniWM
import XCTest

final class AXCallbackGenerationRegistryTests: XCTestCase {
    func testNewGenerationAcceptsReplacementObserver() {
        let registry = AXCallbackGenerationRegistry()
        let retiredGeneration = registry.currentGeneration
        var callbackCount = 0
        registerObserver(1, in: registry, serviceGeneration: retiredGeneration)
        XCTAssertTrue(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)

        let currentGeneration = registry.advance()
        XCTAssertFalse(registry.isCurrent(retiredGeneration))
        XCTAssertTrue(registry.isCurrent(currentGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertNil(registry.reserveCallbackGeneration(serviceGeneration: retiredGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)

        registerObserver(2, in: registry, serviceGeneration: currentGeneration)
        XCTAssertTrue(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 2)
    }

    func testUnregisterRejectsObserverWithoutAdvancingGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: generation)

        registry.unregister(observerKey: 1)

        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
        XCTAssertTrue(registry.isCurrent(generation))
    }

    func testAdvanceCompletesAfterAdmittedCallbackReleaseAndInvalidatesObserver() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: generation)

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let advanceFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            registry.performIfCurrent(observerKey: 1) {
                callbackEntered.signal()
                releaseCallback.wait()
            }
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(registry.isLocked)

        DispatchQueue.global().async {
            registry.advance()
            advanceFinished.signal()
        }

        releaseCallback.signal()

        XCTAssertEqual(advanceFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
    }

    func testContextIncarnationsReceiveDistinctCallbackGenerationsWithinOneServiceGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let first = registerObserver(1, in: registry, serviceGeneration: serviceGeneration)
        registry.unregister(observerKey: 1)
        let second = registerObserver(2, in: registry, serviceGeneration: serviceGeneration)

        XCTAssertGreaterThan(second, first)
        XCTAssertNil(registry.generation(observerKey: 1))
        XCTAssertEqual(registry.generation(observerKey: 2), second)
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
        XCTAssertTrue(registry.performIfCurrent(observerKey: 2) {})
    }

    func testRetiredElementOverflowFailsClosedUntilObserverIsRecreated() {
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let observerKey: UInt = 3
        let windowId = 740_001
        let pid: pid_t = 740_000

        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let liveElement = AXUIElementCreateApplication(pid)
            let subscriptions = ThreadGuardedValue([
                windowId: AppAXWindowSubscription(
                    windowId: windowId,
                    element: liveElement,
                    notifications: .lifecycle
                )
            ])
            defer {
                registry.unregister(observerKey: observerKey)
                subscriptions.destroy()
            }
            _ = registerObserver(
                observerKey,
                in: registry,
                serviceGeneration: serviceGeneration,
                windowSubscriptions: subscriptions
            )

            for offset in 0 ... AXCallbackGenerationRegistry.retiredWindowElementLimit {
                registry.retireWindowElement(
                    observerKey: observerKey,
                    element: AXUIElementCreateApplication(pid_t(741_000 + offset))
                )
            }
            XCTAssertFalse(
                registry.performIfCurrentWindowNotification(
                    observerKey: observerKey,
                    windowId: windowId,
                    element: liveElement,
                    notification: .destroyed
                ) {}
            )

            registry.unregister(observerKey: observerKey)
            _ = registerObserver(
                observerKey,
                in: registry,
                serviceGeneration: serviceGeneration,
                windowSubscriptions: subscriptions
            )
            XCTAssertTrue(
                registry.performIfCurrentWindowNotification(
                    observerKey: observerKey,
                    windowId: windowId,
                    element: liveElement,
                    notification: .destroyed
                ) {}
            )
        }
    }

    @discardableResult
    private func registerObserver(
        _ observerKey: UInt,
        in registry: AXCallbackGenerationRegistry,
        serviceGeneration: UInt64,
        windowSubscriptions: ThreadGuardedValue<[Int: AppAXWindowSubscription]>? = nil
    ) -> UInt64 {
        guard let callbackGeneration = registry.reserveCallbackGeneration(
            serviceGeneration: serviceGeneration
        ) else {
            XCTFail("Expected callback generation")
            return 0
        }
        XCTAssertTrue(
            registry.register(
                observerKey: observerKey,
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration,
                windowSubscriptions: windowSubscriptions
            )
        )
        return callbackGeneration
    }
}
