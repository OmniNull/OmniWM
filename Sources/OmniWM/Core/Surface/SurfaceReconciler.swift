// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class SurfaceReconciler {
    typealias TabRailApply = @MainActor (WMController, [TabRailInfo], Bool) -> Void
    typealias NativeFullscreenPlaceholderApply = @MainActor (
        WMController,
        [NativeFullscreenPlaceholderUpdate],
        Bool
    ) -> Void

    enum ReconcileScope: Equatable {
        case borderOnly
        case fullScene
    }

    private weak var controller: WMController?
    private(set) var reconcileScheduled = false
    private(set) var forceOrderingOnNextReconcile = false
    private(set) var pendingReconcileScope: ReconcileScope?
    private let borderApplier: BorderSurfaceApplier
    private let parkingEdgeMaskManager = ParkingEdgeMaskManager()
    private let applyTabRails: TabRailApply
    private let applyNativeFullscreenPlaceholders: NativeFullscreenPlaceholderApply
    let nativeFullscreenState = NativeFullscreenSurfaceState()
    private(set) var appliedScene = DesiredSurfaceScene.empty

    func nativeFullscreenDiagnosticsSnapshot() -> FullscreenSurfaceDiagnosticsSnapshot {
        nativeFullscreenState.diagnostics(applied: appliedScene.placeholders, controller: controller)
    }

    init(
        controller: WMController,
        borderApplier: BorderSurfaceApplier = BorderSurfaceApplier(),
        applyTabRails: @escaping TabRailApply = { controller, infos, forceOrdering in
            controller.tabRailManager.updateRails(
                infos, forceOrdering: forceOrdering, style: controller.tabRailStyle
            )
        },
        applyNativeFullscreenPlaceholders: @escaping NativeFullscreenPlaceholderApply = {
            controller,
            placeholders,
            forceOrdering in
            controller.nativeFullscreenPlaceholderManager.apply(
                placeholders,
                forceOrdering: forceOrdering
            )
        }
    ) {
        self.controller = controller
        self.borderApplier = borderApplier
        self.applyTabRails = applyTabRails
        self.applyNativeFullscreenPlaceholders = applyNativeFullscreenPlaceholders
        borderApplier.onWindowLevelResolved = { [weak self] in
            self?.noteBorderChanged()
        }
        borderApplier.onDisplayScaleInvalidated = { [weak self] in
            self?.noteBorderChanged()
        }
        borderApplier.onCornerSampleResolved = { [weak self] in
            self?.noteBorderChanged()
        }
    }

    func noteWorldChanged() {
        scheduleReconcile(.fullScene)
    }

    func noteBorderChanged() {
        scheduleReconcile(.borderOnly)
    }

    private func scheduleReconcile(_ scope: ReconcileScope) {
        switch (pendingReconcileScope, scope) {
        case (.fullScene, _),
             (_, .fullScene):
            pendingReconcileScope = .fullScene
        case (.borderOnly, .borderOnly),
             (nil, .borderOnly):
            pendingReconcileScope = .borderOnly
        }
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.flushScheduledReconcile()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    func noteRestackOccurred() {
        forceOrderingOnNextReconcile = true
        noteBorderChanged()
    }

    func reconcileNow() {
        let scope = pendingReconcileScope ?? .fullScene
        let forceOrdering = forceOrderingOnNextReconcile
        reconcileScheduled = false
        forceOrderingOnNextReconcile = false
        pendingReconcileScope = nil
        switch scope {
        case .borderOnly:
            runBorderReconcile(forceOrdering: forceOrdering)
        case .fullScene:
            runFullReconcile(forceOrdering: forceOrdering)
        }
    }

    func reconcileAnimationTick() {
        guard let controller, controller.settings.borders.enabled else { return }
        let world = WorldView(controller: controller)
        let desiredBorder = world.hasStartedServices
            ? SurfaceDerivation.deriveAnimationBorder(world: world, previous: appliedScene.border)
            : nil
        let outcome = borderApplier.apply(
            desiredBorder,
            forceOrdering: false,
            refreshCornerRadii: false
        )
        appliedScene.border = outcome.didApply ? desiredBorder : nil
        if outcome.needsWindowLevelRetry {
            noteBorderChanged()
        }
    }

    func applyAcceptedNativeFullscreenSlots(
        _ slots: [WindowToken: NativeFullscreenSlotProjection],
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        displayContext: NativeFullscreenDisplayContext
    ) {
        guard let controller else { return }
        let update = NativeFullscreenSurfaceProjectionUpdate(
            slots: slots,
            workspaceId: workspaceId,
            displayId: displayId,
            displayContext: displayContext
        )
        guard nativeFullscreenState.accept(update, controller: controller) else { return }

        var needsManagerApply = false
        for index in appliedScene.placeholders.indices {
            let previous = appliedScene.placeholders[index]
            guard previous.workspaceId == workspaceId,
                  let descriptor = nativeFullscreenState.descriptor(for: previous.originalToken)
            else { continue }

            let resolution = nativeFullscreenState.resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
            let next = resolution.update
            guard next != previous else { continue }

            appliedScene.placeholders[index] = next
            NativeFullscreenSurfaceTrace.traceSurfaceAppliedIfSignificant(
                next,
                previous: previous,
                reason: resolution.reason
            )
            if previous.originalToken == next.originalToken,
               previous.currentToken == next.currentToken,
               previous.workspaceId == next.workspaceId,
               previous.selected == next.selected,
               previous.visible == next.visible
            {
                controller.nativeFullscreenPlaceholderManager.moveForAnimation(next)
            } else {
                needsManagerApply = true
            }
        }

        if needsManagerApply {
            controller.nativeFullscreenPlaceholderManager.apply(appliedScene.placeholders)
        }
    }

    func applyAcceptedTabRailGeometry(
        _ commands: [TabRailGeometryCommand],
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) {
        guard !commands.isEmpty,
              let controller,
              controller.hasStartedServices,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              monitor.displayId == displayId,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            return
        }
        controller.tabRailManager.applyAnimationGeometry(commands, in: workspaceId)
    }

    func handleVerifiedFrameApplySuccess(_ result: AXFrameApplyResult) {
        guard let controller else { return }
        let token = WindowToken(pid: result.pid, windowId: result.windowId)
        guard controller.workspaceManager.borderFocusToken == token else { return }
        noteBorderChanged()
    }

    func cleanup() {
        reconcileScheduled = false
        forceOrderingOnNextReconcile = false
        pendingReconcileScope = nil
        borderApplier.cleanup()
        parkingEdgeMaskManager.removeAll()
        nativeFullscreenState.cleanup()
        appliedScene = .empty
    }

    func cleanupBorder() {
        borderApplier.cleanup()
        appliedScene.border = nil
    }

    private func flushScheduledReconcile() {
        guard reconcileScheduled else { return }
        reconcileNow()
    }

    private func runFullReconcile(forceOrdering: Bool) {
        BorderOpMetricsRecorder.shared.noteFullScenePass()
        guard let controller else { return }
        let world = WorldView(controller: controller)
        nativeFullscreenState.prepareForReconcile(
            servicesStarted: world.hasStartedServices,
            workspaceManager: controller.workspaceManager
        )
        var desired = SurfaceDerivation.derive(world: world)
        nativeFullscreenState.replaceDescriptors(desired.placeholders)
        desired.placeholders = desired.placeholders.map { descriptor in
            let previous = appliedScene.placeholders.first {
                $0.originalToken == descriptor.originalToken
            }
            let resolution = nativeFullscreenState.resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
            let resolved = resolution.update
            if resolved != previous {
                NativeFullscreenSurfaceTrace.traceSurfaceAppliedIfSignificant(
                    resolved,
                    previous: previous,
                    reason: resolution.reason
                )
            }
            return resolved
        }
        let outcome = applyFull(
            desired,
            on: controller,
            forceOrdering: forceOrdering,
            refreshCornerRadii: shouldRefreshCornerRadii(for: desired.border, controller: controller)
        )
        if outcome.needsWindowLevelRetry {
            noteBorderChanged()
        }
    }

    private func runBorderReconcile(forceOrdering: Bool) {
        BorderOpMetricsRecorder.shared.noteBorderOnlyPass()
        guard let controller else { return }
        let world = WorldView(controller: controller)
        let desiredBorder = world.hasStartedServices
            ? SurfaceDerivation.deriveBorder(world: world)
            : nil
        let outcome = borderApplier.apply(
            desiredBorder,
            forceOrdering: forceOrdering,
            refreshCornerRadii: shouldRefreshCornerRadii(for: desiredBorder, controller: controller)
        )
        if forceOrdering {
            applyTabRails(controller, appliedScene.tabRails, true)
            applyNativeFullscreenPlaceholders(controller, appliedScene.placeholders, true)
        }
        appliedScene.border = outcome.didApply ? desiredBorder : nil
        if outcome.needsWindowLevelRetry {
            noteBorderChanged()
        }
    }

    private func shouldRefreshCornerRadii(
        for border: DesiredBorderSurface?,
        controller: WMController
    ) -> Bool {
        guard let border,
              let entry = controller.workspaceManager.entry(for: border.token)
        else { return false }
        return !controller.workspaceManager.animationDriver.hasMotion(in: entry.workspaceId)
            && !controller.axManager.hasPendingFrameWrite(for: border.windowId)
    }

    private func applyFull(
        _ desired: DesiredSurfaceScene,
        on controller: WMController,
        forceOrdering: Bool,
        refreshCornerRadii: Bool
    ) -> BorderSurfaceApplyResult {
        controller.workspaceBarManager.apply(desired.bars)
        controller.publishWorkspaceDataChanges(from: appliedScene, to: desired)
        let borderOutcome = borderApplier.apply(
            desired.border,
            forceOrdering: forceOrdering,
            refreshCornerRadii: refreshCornerRadii
        )
        if desired.tabRails != appliedScene.tabRails || desired.tabRailStyle != appliedScene
            .tabRailStyle || forceOrdering
        {
            applyTabRails(controller, desired.tabRails, forceOrdering)
        }
        if desired.placeholders != appliedScene.placeholders || forceOrdering {
            applyNativeFullscreenPlaceholders(controller, desired.placeholders, forceOrdering)
        }
        parkingEdgeMaskManager.apply(desired.parkingEdgeMasks)
        appliedScene = desired
        if !borderOutcome.didApply {
            appliedScene.border = nil
        }
        return borderOutcome
    }
}
