// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

private final class ConnectionReleaseObserver: Sendable {
    private let released: XCTestExpectation

    init(released: XCTestExpectation) {
        self.released = released
    }

    deinit {
        released.fulfill()
    }
}

@MainActor
final class IPCConnectionRegistryTests: XCTestCase {
    func testLateConnectionIsRejectedAfterShutdown() async throws {
        let registry = IPCConnectionRegistry()
        await registry.stopAll()
        weak var rejectedConnection: IPCConnection?

        do {
            let (connection, peerHandle) = try makeConnection()
            rejectedConnection = connection

            let accepted = await registry.insert(connection)
            XCTAssertFalse(accepted)
            await connection.stop()
            await connection.start()

            await assertClosed(connection, peerHandle: peerHandle)
        }

        XCTAssertNil(rejectedConnection)
    }

    func testShutdownBeforeStartKeepsAcceptedConnectionClosed() async throws {
        let registry = IPCConnectionRegistry()
        let (connection, peerHandle) = try makeConnection()
        let accepted = await registry.insert(connection)
        XCTAssertTrue(accepted)

        await registry.stopAll()
        await connection.start()

        await assertClosed(connection, peerHandle: peerHandle)
    }

    func testShutdownClosesAndReleasesActiveConnection() async throws {
        let registry = IPCConnectionRegistry()
        weak var stoppedConnection: IPCConnection?
        let released = XCTestExpectation(description: "Connection released after shutdown")

        do {
            let observer = ConnectionReleaseObserver(released: released)
            let (connection, peerHandle) = try makeConnection(onClose: { _ in withExtendedLifetime(observer) {} })
            stoppedConnection = connection
            let accepted = await registry.insert(connection)
            XCTAssertTrue(accepted)
            await connection.start()
            let hasReadSource = await connection.readSource != nil
            XCTAssertTrue(hasReadSource)

            await registry.stopAll()

            await assertClosed(connection, peerHandle: peerHandle)
        }

        await fulfillment(of: [released], timeout: failureBound)
        XCTAssertNil(stoppedConnection)
    }

    private func assertClosed(
        _ connection: IPCConnection,
        peerHandle: FileHandle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let isClosed = await connection.isClosed
        let hasReadSource = await connection.readSource != nil
        let hasWriteSource = await connection.writeSource != nil
        XCTAssertTrue(isClosed, file: file, line: line)
        XCTAssertFalse(hasReadSource, file: file, line: line)
        XCTAssertFalse(hasWriteSource, file: file, line: line)

        let readable = XCTestExpectation(description: "Peer socket readable after connection shutdown")
        readable.assertForOverFulfill = false
        let peerEvents = DispatchSource.makeReadSource(fileDescriptor: peerHandle.fileDescriptor, queue: .main)
        peerEvents.setEventHandler { readable.fulfill() }
        peerEvents.resume()
        await fulfillment(of: [readable], timeout: failureBound)
        peerEvents.cancel()
        var byte: UInt8 = 0
        let result = recv(peerHandle.fileDescriptor, &byte, 1, MSG_DONTWAIT)
        XCTAssertEqual(result, 0, "Expected peer EOF after connection shutdown", file: file, line: line)
    }

    private func makeConnection(
        onClose: @escaping @Sendable (UUID) -> Void = { _ in }
    ) throws -> (IPCConnection, FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        let serverHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peerHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMIPCRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: "0.0.0-test",
            sessionToken: "session",
            authorizationToken: "token"
        )
        addTeardownBlock { @MainActor in
            await bridge.shutdown()
            try? peerHandle.close()
            withExtendedLifetime(controller) {}
            try? FileManager.default.removeItem(at: root)
        }
        return (
            IPCConnection(handle: serverHandle, bridge: bridge, onClose: onClose),
            peerHandle
        )
    }
}
