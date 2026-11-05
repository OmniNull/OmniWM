// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class ActivationFactsForwardingSink: EventIntakeSink {
    private let interpreter: EventInterpreter
    private let delivered: XCTestExpectation

    init(interpreter: EventInterpreter, delivered: XCTestExpectation) {
        self.interpreter = interpreter
        self.delivered = delivered
    }

    func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
        interpreter.handleIntakeEvent(stamped)
        if case .activationFactsResolved = stamped.event {
            delivered.fulfill()
        }
    }
}

@MainActor
enum WindowAdmissionTestSupport {
    static func controller(
        prefix: String = "OmniWMWindowAdmissionTests",
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        ),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
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
            windowFocusOperations: windowFocusOperations,
            ownedWindowRegistry: ownedWindowRegistry
        )
        let handler = controller.axEventHandler
        handler.lifecycleQueries.query = { [weak handler] in handler?.windowInfoProvider($0) }
        handler.frameObservations.nativeDragQuery = { [weak handler] in handler?.windowInfoProvider($0) }
        return controller
    }

    static func workspace(
        named name: String,
        layoutType: LayoutType,
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        controller.settings.workspaces.configurations.append(
            WorkspaceConfiguration(name: name, layoutType: layoutType)
        )
        controller.workspaceManager.applySettings()
        return controller.workspaceManager.workspaceId(for: name, createIfMissing: true)
    }

    static func parkedTask() -> Task<Void, Never> {
        Task { @MainActor in
            let (parked, keepOpen) = AsyncStream.makeStream(of: Void.self)
            for await _ in parked {}
            keepOpen.finish()
        }
    }

    static func drainLayoutRefreshes(_ controller: WMController) async {
        let refresh = controller.layoutRefreshController
        while let task = refresh.layoutState.activeRefreshTask ?? refresh.layoutState.pendingDebounceTask {
            guard !Task.isCancelled else {
                XCTFail("layout refresh drain cancelled")
                return
            }
            await task.value
        }
        XCTAssertNil(refresh.layoutState.activeRefresh)
        XCTAssertNil(refresh.layoutState.pendingRefresh)
    }

    static func awaitActivationFactsDelivery(
        to controller: WMController,
        afterResolving resolve: () async -> Void
    ) async {
        let previousSeq = controller.eventIntake.lastSeq
        let delivered = XCTestExpectation(description: "Deferred activation facts reached the interpreter")
        delivered.assertForOverFulfill = false
        let sink = ActivationFactsForwardingSink(interpreter: controller.eventInterpreter, delivered: delivered)
        controller.eventIntake.open(sink: sink)
        await resolve()
        let delivery = await XCTWaiter.fulfillment(of: [delivered], timeout: failureBound)
        XCTAssertEqual(delivery, .completed)
        XCTAssertGreaterThan(controller.eventIntake.lastSeq, previousSeq)
        controller.eventIntake.open(sink: controller.eventInterpreter)
        withExtendedLifetime(sink) {}
        controller.eventIntake.drainNow()
    }

    static func axRef(for token: WindowToken) -> AXWindowRef {
        AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
    }

    static func track(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> AXWindowRef {
        let axRef = axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        return axRef
    }

    static func frameRequest(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        window: AXWindowRef,
        frame: CGRect,
        isRetry: Bool = false
    ) -> AXFrameApplicationRequest? {
        ledger.prepareFrameApplication(
            .init(pid: pid, window: window, frame: frame),
            isRetry: isRetry,
            terminalObserver: nil
        ).request
    }

    static func frameResult(
        request: AXFrameApplicationRequest,
        observed: CGRect,
        failure: AXFrameWriteFailureReason,
        sizeError: AXError = .attributeUnsupported,
        positionError: AXError = .success
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: sizeError,
                positionError: positionError,
                failureReason: failure
            ),
            traceRequestId: request.traceRequestId
        )
    }

    static func verificationMismatchFrameResult(
        request: AXFrameApplicationRequest,
        observed: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        )
    }

    static func successfulFrameResult(request: AXFrameApplicationRequest) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: request.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }
}
