// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class EventInterpreter: EventIntakeSink {
    weak var controller: WMController?
    private let callbackGenerationProvider: @MainActor (pid_t) -> UInt64?

    init(
        controller: WMController,
        callbackGenerationProvider: @escaping @MainActor (pid_t) -> UInt64? = {
            AppAXContextRegistry.contexts[$0]?.callbackGeneration
        }
    ) {
        self.controller = controller
        self.callbackGenerationProvider = callbackGenerationProvider
    }

    func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
        guard let controller else { return }

        switch stamped.event {
        case let .activationFactsResolved(facts):
            controller.axEventHandler.handleActivationFactsResolved(facts)

        case let .focusedAdmissionRetryFactRequestSuperseded(execution):
            controller.axEventHandler.finishFocusedAdmissionRetryExecution(execution)

        case .activeSpaceChanged:
            controller.serviceLifecycleManager.handleActiveSpaceDidChange()

        case let .application(event):
            handleApplicationIntakeEvent(event, sequence: stamped.seq, controller: controller)

        case let .axWindow(event):
            handleAXWindowIntakeEvent(event, controller: controller)

        case let .cgs(event):
            controller.axEventHandler.handleCGSEvent(event)

        case let .display(event):
            controller.serviceLifecycleManager.monitorConfiguration.handle(event)

        case let .hotkeyInvocation(invocation):
            handleHotkeyInvocation(invocation, sequence: stamped.seq, controller: controller)

        case let .intentExpired(intentId, deadlineGeneration):
            controller.axEventHandler.handleIntentExpired(
                intentId,
                deadlineGeneration: deadlineGeneration
            )

        case let .ipcCommand(intake):
            intake.completion(intake.perform(controller))

        case let .mouseDragged(button, location):
            controller.mouseEventHandler.dispatchQueuedMouseDragged(at: location, button: button)

        case let .mouseMoved(location, modifiersRawValue, windowIdUnderPointer):
            controller.mouseEventHandler.dispatchMouseMoved(
                at: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )

        case let .mouseScroll(payload):
            controller.mouseEventHandler.dispatchScrollWheel(payload)

        case let .nativeFullscreenTransitionExpired(originalToken, generation):
            _ = controller.workspaceManager.expireNativeFullscreenTransition(
                originalToken: originalToken,
                generation: generation
            )

        case .systemSleep:
            _ = controller.workspaceManager.recordReconcileEvent(.systemSleep(source: .service))
            controller.mouseEventHandler.suspendMultitouchForSleep()

        case .systemWake:
            controller.serviceLifecycleManager.handleSystemWake()

        case let .windowConstraintsResolved(fact):
            controller.layoutRefreshController.applyResolvedConstraints(fact)
        }
    }

    private func handleHotkeyInvocation(_ invocation: HotkeyInvocation, sequence: UInt64, controller: WMController) {
        InputTrace.record(
            "hotkey.dispatch.begin seq=\(sequence)"
                + " source=\(TraceFormat.token(controller.workspaceManager.selectedManagedToken))"
                + " repeat=\(invocation.trigger?.isRepeat.description ?? "unknown")"
                + " cmd=\(invocation.command.displayName)"
        )
        let result = controller.commandHandler.handleHotkeyInvocation(invocation)
        InputTrace.record(
            "hotkey.dispatch.end seq=\(sequence)"
                + " selected=\(TraceFormat.token(controller.workspaceManager.selectedManagedToken))"
                + " pending=\(TraceFormat.token(controller.workspaceManager.pendingFocusedToken))"
                + " result=\(result)"
        )
    }

    private func acceptsCallbackGeneration(_ callbackGeneration: UInt64?, pid: pid_t) -> Bool {
        guard let callbackGeneration else { return true }
        return callbackGenerationProvider(pid) == callbackGeneration
    }

    private func handleAppVisibility(
        _ visibility: AppVisibilityTrace.Visibility,
        pid: pid_t,
        sequence: UInt64,
        controller: WMController
    ) {
        AppVisibilityTrace.record(
            .intake,
            pid: pid,
            visibility: visibility,
            outcome: .dispatched,
            intakeSequence: sequence,
            source: .service
        )
        switch visibility {
        case .hidden: controller.axEventHandler.handleAppHidden(pid: pid, source: .service)
        case .visible: controller.axEventHandler.handleNativeAppUnhide(pid: pid)
        }
    }

    private func handleApplicationIntakeEvent(
        _ event: ApplicationIntakeEvent,
        sequence: UInt64,
        controller: WMController
    ) {
        switch event {
        case let .activated(pid):
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .workspaceDidActivateApplication
            )

        case let .deactivated(pid):
            controller.axEventHandler.handleAppDeactivated(pid: pid)

        case let .hidden(pid):
            handleAppVisibility(.hidden, pid: pid, sequence: sequence, controller: controller)

        case let .launched(pid):
            controller.axEventHandler.handleAppLaunched(pid: pid)

        case let .terminated(pid, frontmostPID):
            controller.axEventHandler.handleAppTerminated(
                pid: pid,
                frontmostPID: frontmostPID
            )

        case let .unhidden(pid):
            handleAppVisibility(.visible, pid: pid, sequence: sequence, controller: controller)
        }
    }

    private func handleAXWindowIntakeEvent(_ event: AXWindowIntakeEvent, controller: WMController) {
        switch event {
        case let .focusedWindowChanged(pid, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleAppActivation(
                pid: pid,
                source: .focusedWindowChanged,
                callbackGeneration: callbackGeneration
            )

        case let .windowDestroyed(pid, axRef, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleRemoved(
                pid: pid,
                winId: axRef.windowId,
                axRef: axRef,
                callbackGeneration: callbackGeneration
            )

        case let .windowMiniaturized(pid, axRef, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleWindowMinimized(pid: pid, axRef: axRef, minimized: true)

        case let .windowDeminiaturized(pid, axRef, callbackGeneration):
            guard acceptsCallbackGeneration(callbackGeneration, pid: pid) else { return }
            controller.axEventHandler.handleWindowMinimized(pid: pid, axRef: axRef, minimized: false)
        }
    }
}
