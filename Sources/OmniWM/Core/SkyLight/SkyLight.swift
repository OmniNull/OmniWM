// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Synchronization

@MainActor
final class SkyLight {
    static let shared = SkyLight()

    let connections: SkyLightConnectionFunctions
    let queries: SkyLightQueryFunctions
    let transactions: SkyLightTransactionFunctions
    let notifications: SkyLightNotificationFunctions
    let surfaces: SkyLightSurfaceFunctions
    let spaces: SkyLightSpaceFunctions

    typealias ConnectionNotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Void

    typealias NotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        Int32
    ) -> Void

    private var deferredWindowInfoConnection: WindowInfoConnection?

    private let capabilitySymbols: [String]
    let screencaptureSelectionExclusionKey = "IgnoreForScreencaptureWindowSelection" as CFString

    private init() {
        var resolver = SkyLightSymbolResolver()
        connections = SkyLightConnectionFunctions(resolver: &resolver)
        queries = SkyLightQueryFunctions(resolver: &resolver)
        transactions = SkyLightTransactionFunctions(resolver: &resolver)
        notifications = SkyLightNotificationFunctions(resolver: &resolver)
        surfaces = SkyLightSurfaceFunctions(resolver: &resolver)
        spaces = SkyLightSpaceFunctions(resolver: &resolver)
        capabilitySymbols = resolver.capabilitySymbols
    }

    func getMainConnectionID() -> Int32 {
        connections.mainConnectionID()
    }

    func capabilityReport() -> [String] {
        capabilitySymbols
    }

    func commit(_ transaction: CFTypeRef) {
        MainThreadAXSpanTrace.measure(.windowServerCommit) {
            transactions.transactionCommit(transaction, 0)
        }
    }

    func windowInfoConnection() -> WindowInfoConnection? {
        if deferredWindowInfoConnection == nil {
            guard let newConnection = connections.newConnection,
                  let releaseConnection = connections.releaseConnection else { return nil }
            deferredWindowInfoConnection = WindowInfoConnection(
                mainConnectionId: getMainConnectionID(),
                create: {
                    var cid: Int32 = 0
                    let error = newConnection(0, &cid)
                    return (error, cid)
                },
                release: { _ = releaseConnection($0) }
            )
        }
        return deferredWindowInfoConnection
    }

    func stopWindowInfoQueries() {
        deferredWindowInfoConnection = nil
    }

    final class WindowInfoConnection: Sendable {
        private let mainConnectionId: Int32
        private let create: @Sendable () -> (CGError, Int32)
        private let release: @Sendable (Int32) -> Void
        private let connectionId = Mutex<Int32?>(nil)

        nonisolated init(
            mainConnectionId: Int32,
            create: @escaping @Sendable () -> (CGError, Int32),
            release: @escaping @Sendable (Int32) -> Void
        ) {
            self.mainConnectionId = mainConnectionId
            self.create = create
            self.release = release
        }

        deinit {
            guard let cid = connectionId.withLock({ $0 }) else { return }
            let release = release
            windowInfoQueue.async {
                release(cid)
            }
        }

        nonisolated func perform<Result: Sendable>(
            _ read: @escaping @Sendable (Int32) -> Result?
        ) async throws -> Result? {
            try await SkyLight.performWindowInfoQuery { [self] in
                connectionId.withLock { cid in
                    if cid == nil {
                        let (error, created) = create()
                        guard error == .success, created != 0, created != mainConnectionId else { return nil }
                        cid = created
                    }
                    guard let cid else { return nil }
                    return read(cid)
                }
            }
        }
    }

    private nonisolated static let windowInfoQueue = DispatchQueue(
        label: "OmniWM-WindowServerMetadata", qos: .userInteractive
    )

    nonisolated static func performWindowInfoQuery<Result: Sendable>(
        _ read: @escaping @Sendable () -> Result?
    ) async throws -> Result? {
        try Task.checkCancellation()
        let job = RunLoopJob()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                windowInfoQueue.async {
                    let result = job.isCancelled ? nil : autoreleasepool(invoking: read)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private var scopedTransaction: CFTypeRef?

    func withTransactionScope(_ body: () -> Void) {
        guard scopedTransaction == nil,
              let transaction = transactions.transactionCreate(getMainConnectionID())?.takeRetainedValue()
        else {
            body()
            return
        }
        scopedTransaction = transaction
        body()
        scopedTransaction = nil
        commit(transaction)
    }

    func withTransaction(_ ops: (CFTypeRef) -> Void) {
        if let transaction = scopedTransaction {
            ops(transaction)
            return
        }
        guard let transaction = transactions.transactionCreate(getMainConnectionID())?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return
        }
        ops(transaction)
        commit(transaction)
    }

    enum TransactionSubmissionResult: Equatable, Sendable {
        case submitted
        case deferred
        case unavailable
    }

    @discardableResult
    func batchMoveWindows(
        _ positions: [(windowId: UInt32, origin: CGPoint)]
    ) -> TransactionSubmissionResult {
        guard !positions.isEmpty else { return .submitted }
        if let transaction = scopedTransaction {
            for position in positions {
                transactions.transactionMoveWindowWithGroup(
                    transaction,
                    position.windowId,
                    position.origin
                )
            }
            return .deferred
        }
        guard let transaction = transactions.transactionCreate(getMainConnectionID())?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return .unavailable
        }
        for position in positions {
            transactions.transactionMoveWindowWithGroup(
                transaction,
                position.windowId,
                position.origin
            )
        }
        commit(transaction)
        return .submitted
    }
}
