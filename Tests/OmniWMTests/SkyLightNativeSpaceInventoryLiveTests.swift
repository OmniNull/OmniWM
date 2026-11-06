// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Darwin
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class SkyLightNativeSpaceInventoryLiveTests: XCTestCase {
        func testLiveBatchedBoundsMatchSingleReads() throws {
            let sky = SkyLight.shared
            let windows = (0 ..< 3).map { index in
                sky.createBorderWindow(frame: CGRect(x: -8960 + CGFloat(index) * 40, y: -9000, width: 10, height: 10))
            }
            defer { windows.forEach(sky.releaseBorderWindow) }
            XCTAssertFalse(windows.contains(0))

            let batch = sky.queryWindowBounds(windows)

            XCTAssertEqual(Set(batch.keys), Set(windows))
            for window in windows {
                XCTAssertEqual(batch[window], sky.queryWindowBounds(window))
            }
        }

        func testForeignMoveCannotPoisonBoundsUsedForVerification() async throws {
            if ProcessInfo.processInfo.environment[Self.foreignHelperEnvironmentKey] == "1" {
                try runForeignPanelHelper()
                return
            }
            let helper = Process()
            let output = Pipe()
            let input = Pipe()
            helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            helper.arguments = [
                "-XCTest",
                "OmniWMTests.SkyLightNativeSpaceInventoryLiveTests/testForeignMoveCannotPoisonBoundsUsedForVerification",
                Bundle(for: Self.self).bundlePath
            ]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.foreignHelperEnvironmentKey] = "1"
            helper.environment = environment
            helper.standardOutput = output
            helper.standardInput = input
            try helper.run()
            defer {
                try? input.fileHandleForWriting.close()
                helper.terminate()
                helper.waitUntilExit()
            }
            let wid = try foreignWindowId(from: output.fileHandleForReading)
            func independentlyObservedBounds() -> CGRect? {
                guard let list = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]],
                      let info = list
                          .first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid }),
                      let bounds = info[kCGWindowBounds as String] as? [String: Any]
                else { return nil }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            let before = try XCTUnwrap(independentlyObservedBounds(), "Foreign helper running: \(helper.isRunning)")
            let sky = SkyLight.shared
            XCTAssertEqual(sky.getWindowBounds(wid), before)
            XCTAssertEqual(sky.batchMoveWindows([
                (windowId: wid, origin: CGPoint(x: before.midX, y: before.midY))
            ]), .submitted)
            try synchronizeWindowServer()

            XCTAssertEqual(sky.getWindowBounds(wid), try XCTUnwrap(independentlyObservedBounds()))
        }

        func testLiveDeferredOrderingTracksOffscreenWithdrawalAndReopening() async throws {
            let sky = SkyLight.shared
            let wid = sky.createBorderWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            guard wid != 0 else {
                throw MissingTestPrerequisite("Unable to create an owned SkyLight test window")
            }
            defer {
                sky.releaseBorderWindow(wid)
                sky.stopWindowInfoQueries()
            }
            XCTAssertTrue(sky.moveWindow(wid, to: CGPoint(x: -9000, y: -9000)))

            for expected in [false, true, false, true] {
                sky.orderWindow(wid, relativeTo: 0, order: expected ? .above : .out)
                try synchronizeWindowServer()
                XCTAssertEqual(sky.isWindowOrderedIn(wid), expected)

                let result = try await sky.queryWindowInfoDeferred(
                    windowIds: [wid, UInt32.max],
                    includeOrderedIn: true
                )
                let info = try XCTUnwrap(result?[wid])
                XCTAssertEqual(info.isOrderedIn, expected)
                XCTAssertEqual(info.pid, getpid())
                XCTAssertEqual(info.frame.origin, CGPoint(x: -9000, y: -9000))
                XCTAssertNil(result?[UInt32.max])
            }

            let metadata = try await sky.queryWindowInfoDeferred(windowIds: [wid])
            XCTAssertNil(try XCTUnwrap(metadata?[wid]).isOrderedIn)
        }

        func testLiveAboveOrdersWindowBackIn() async throws {
            let sky = SkyLight.shared
            let wid = sky.createBorderWindow(frame: CGRect(x: -9000, y: -9000, width: 10, height: 10))
            guard wid != 0 else {
                throw MissingTestPrerequisite("Unable to create an owned SkyLight test window")
            }
            defer { sky.releaseBorderWindow(wid) }

            sky.transactionHide(wid)
            let orderedOut = try observedOrderedState(of: wid, matching: false)
            XCTAssertEqual(orderedOut, false)

            sky.orderWindow(wid, relativeTo: 0, order: .above)
            let orderedIn = try observedOrderedState(of: wid, matching: true)
            XCTAssertEqual(orderedIn, true)
        }

        func testLiveTransactionMoveIsObservedThroughWindowServerBounds() async throws {
            let sky = SkyLight.shared
            let wid = sky.createBorderWindow(frame: CGRect(x: -9000, y: -9000, width: 10, height: 10))
            guard wid != 0 else {
                throw MissingTestPrerequisite("Unable to create an owned SkyLight test window")
            }
            defer { sky.releaseBorderWindow(wid) }
            _ = sky.configureWindow(wid, resolution: 1, opaque: false)
            let initialBounds = try XCTUnwrap(sky.getWindowBounds(wid))
            defer { _ = sky.moveWindow(wid, to: initialBounds.origin) }
            let nestedTarget = CGPoint(x: initialBounds.origin.x + 4, y: initialBounds.origin.y + 4)
            let scopedTarget = CGPoint(x: initialBounds.origin.x + 8, y: initialBounds.origin.y + 8)
            var scopedSubmission: SkyLight.TransactionSubmissionResult?

            sky.withTransactionScope {
                sky.transactionMove(wid, origin: nestedTarget)
                scopedSubmission = sky.batchMoveWindows([(windowId: wid, origin: scopedTarget)])
            }

            XCTAssertEqual(scopedSubmission, .deferred)
            let scopedMovedBounds = try observedBounds(of: wid, matching: scopedTarget)
            XCTAssertEqual(scopedMovedBounds.size, initialBounds.size)
            XCTAssertTrue(sky.moveWindow(wid, to: initialBounds.origin))
            let scopedRestoredBounds = try observedBounds(of: wid, matching: initialBounds.origin)
            XCTAssertEqual(scopedRestoredBounds.size, initialBounds.size)

            let submittedTarget = CGPoint(x: initialBounds.origin.x + 12, y: initialBounds.origin.y + 12)
            let submitted = sky.batchMoveWindows([(windowId: wid, origin: submittedTarget)])
            XCTAssertEqual(submitted, .submitted)
            let submittedMovedBounds = try observedBounds(of: wid, matching: submittedTarget)
            XCTAssertEqual(submittedMovedBounds.size, initialBounds.size)
            XCTAssertTrue(sky.moveWindow(wid, to: initialBounds.origin))
            let submittedRestoredBounds = try observedBounds(of: wid, matching: initialBounds.origin)
            XCTAssertEqual(submittedRestoredBounds.size, initialBounds.size)

            let orderedWid = sky.createBorderWindow(frame: CGRect(x: -8960, y: -9000, width: 10, height: 10))
            guard orderedWid != 0 else {
                throw MissingTestPrerequisite("Unable to create a second owned SkyLight test window")
            }
            defer { sky.releaseBorderWindow(orderedWid) }
            _ = sky.configureWindow(orderedWid, resolution: 1, opaque: false)
            let orderedInitialInfo = try XCTUnwrap(sky.queryWindowInfo(orderedWid))
            let alternateLevel: Int32 = orderedInitialInfo.level == 3 ? 0 : 3
            let orderedTarget = CGPoint(
                x: orderedInitialInfo.frame.origin.x + 8,
                y: orderedInitialInfo.frame.origin.y + 8
            )

            sky.orderWindow(wid, relativeTo: 0)
            sky.withTransactionScope {
                sky.transactionMoveAndOrder(
                    orderedWid,
                    origin: orderedTarget,
                    level: alternateLevel,
                    relativeTo: wid,
                    order: .below
                )
            }

            let orderedMovedInfo = try observedWindowInfo(
                of: orderedWid,
                matching: orderedTarget,
                level: alternateLevel
            )
            XCTAssertEqual(orderedMovedInfo.frame.size, orderedInitialInfo.frame.size)
            XCTAssertEqual(sky.isWindowOrderedIn(orderedWid), true)

            sky.transactionMoveAndOrder(
                orderedWid,
                origin: orderedInitialInfo.frame.origin,
                level: orderedInitialInfo.level,
                relativeTo: 0,
                order: .above
            )
            let orderedRestoredInfo = try observedWindowInfo(
                of: orderedWid,
                matching: orderedInitialInfo.frame.origin,
                level: orderedInitialInfo.level
            )
            XCTAssertEqual(orderedRestoredInfo.frame.size, orderedInitialInfo.frame.size)
        }

        func testLiveNativeSpaceInventoryReturnsCompleteDeduplicatedDetails() throws {
            let spaceIds = try liveSpaceIds()
            let inventory = try authoritativeInventory(spaceIds: spaceIds)

            XCTAssertEqual(Set(inventory.keys), spaceIds)
            for windows in inventory.values {
                XCTAssertTrue(windows.allSatisfy { $0.id != 0 })
                XCTAssertEqual(Set(windows.map(\.id)).count, windows.count)
            }
        }

        func testRepeatedLiveNativeSpaceInventoryQueriesRemainUsable() throws {
            let spaceIds = try liveSpaceIds()
            var authoritativeQueryCount = 0

            for _ in 0 ..< 256 {
                switch SkyLight.shared.nativeSpaceWindowInventory(spaceIds: spaceIds) {
                case .authoritative:
                    authoritativeQueryCount += 1
                case .queryFailed:
                    continue
                case .unavailable:
                    throw MissingTestPrerequisite("SLSCopyWindowsWithOptionsAndTags is unavailable")
                }
            }

            XCTAssertGreaterThan(authoritativeQueryCount, 0)
        }

        private func liveSpaceIds() throws -> Set<UInt64> {
            let spaceIds = Set(SkyLight.shared.managedSpaces().map(\.currentSpaceId))
            guard !spaceIds.isEmpty, !spaceIds.contains(0) else {
                throw MissingTestPrerequisite("No usable native Space inventory is available")
            }
            return spaceIds
        }

        private func authoritativeInventory(
            spaceIds: Set<UInt64>
        ) throws -> [UInt64: [WindowServerInfo]] {
            switch SkyLight.shared.nativeSpaceWindowInventory(spaceIds: spaceIds) {
            case let .authoritative(inventory):
                inventory
            case .queryFailed:
                throw MissingTestPrerequisite("The live native Space inventory changed during the query")
            case .unavailable:
                throw MissingTestPrerequisite("SLSCopyWindowsWithOptionsAndTags is unavailable")
            }
        }

        private static let foreignHelperEnvironmentKey = "OMNIWM_SKYLIGHT_FOREIGN_PANEL_HELPER"
        private static let foreignWindowPrefix = "OMNIWM_FOREIGN_WINDOW="

        private func runForeignPanelHelper() throws {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let panel = NSPanel(
                contentRect: CGRect(x: 5, y: 5, width: 10, height: 10),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.level = .statusBar
            FileHandle.standardInput.readabilityHandler = { handle in
                if handle.availableData.isEmpty { exit(EXIT_SUCCESS) }
            }
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            CATransaction.flush()
            try synchronizeWindowServer()
            let wid = try XCTUnwrap(UInt32(exactly: panel.windowNumber))
            let info = try XCTUnwrap(SkyLight.shared.queryWindowInfo(wid))
            XCTAssertEqual(info.pid, getpid())
            XCTAssertEqual(SkyLight.shared.isWindowOrderedIn(wid), true)
            print(Self.foreignWindowPrefix + String(wid))
            fflush(stdout)
            app.run()
            withExtendedLifetime(panel) {}
        }

        private func foreignWindowId(from output: FileHandle) throws -> UInt32 {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            var line = Data()
            while true {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw ForeignPanelError.readinessDeadlineExceeded
                }
                let components = remaining.components
                let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, Int32(clamping: milliseconds)) > 0 else {
                    throw ForeignPanelError.readinessDeadlineExceeded
                }
                guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                    throw ForeignPanelError.exitedBeforeReady
                }
                if byte == Data("\n".utf8) {
                    let message = String(decoding: line, as: UTF8.self)
                    if message.hasPrefix(Self.foreignWindowPrefix),
                       let wid = UInt32(message.dropFirst(Self.foreignWindowPrefix.count))
                    {
                        return wid
                    }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }

        private enum ForeignPanelError: Error {
            case readinessDeadlineExceeded
            case exitedBeforeReady
        }

        private func synchronizeWindowServer() throws {
            let sky = SkyLight.shared
            let transaction = try XCTUnwrap(sky.transactions.transactionCreate(sky.getMainConnectionID())?
                .takeRetainedValue())
            let synchronous: Int32 = 1
            sky.transactions.transactionCommit(transaction, synchronous)
        }

        private func observedBounds(of wid: UInt32, matching origin: CGPoint) throws -> CGRect {
            try synchronizeWindowServer()
            let bounds = try XCTUnwrap(SkyLight.shared.getWindowBounds(wid))
            XCTAssertEqual(bounds.origin, origin)
            return bounds
        }

        private func observedOrderedState(of wid: UInt32, matching expected: Bool) throws -> Bool {
            try synchronizeWindowServer()
            let orderedIn = try XCTUnwrap(SkyLight.shared.isWindowOrderedIn(wid))
            XCTAssertEqual(orderedIn, expected)
            return orderedIn
        }

        private func observedWindowInfo(
            of wid: UInt32,
            matching origin: CGPoint,
            level: Int32
        ) throws -> WindowServerInfo {
            try synchronizeWindowServer()
            let info = try XCTUnwrap(SkyLight.shared.queryWindowInfo(wid))
            XCTAssertEqual(info.level, level)
            XCTAssertEqual(info.frame.origin, origin)
            return info
        }
    }
#endif
