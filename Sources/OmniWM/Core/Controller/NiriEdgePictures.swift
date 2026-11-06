// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

struct NiriEdgePictureGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let otherDisplayFrames: [CGRect]

    init?(frame: CGRect, displayFrame: CGRect, otherDisplayFrames: [CGRect] = []) {
        let visible = frame.intersection(displayFrame)
        guard frame.size.hasFinitePositiveDimensions(), frame.origin.x.isFinite, frame.origin.y.isFinite,
              !visible.isNull, !visible.isEmpty else { return nil }
        self.frame = frame
        visibleFrame = visible
        self.otherDisplayFrames = otherDisplayFrames
    }

    static func overlapsDisplay(_ frame: CGRect, otherDisplayFrames: [CGRect]) -> Bool {
        let extent = frame.union(SurfacePanelGeometry.backingFrame(for: frame))
        return otherDisplayFrames.contains {
            let overlap = extent.intersection($0)
            return !overlap.isNull && !overlap.isEmpty
        }
    }

    var requiresDisplayClip: Bool {
        Self.overlapsDisplay(frame, otherDisplayFrames: otherDisplayFrames)
    }

    var panelFrame: CGRect {
        requiresDisplayClip ? visibleFrame : frame
    }

    var pictureFrame: CGRect {
        frame.offsetBy(dx: -visibleFrame.minX, dy: -visibleFrame.minY)
    }
}

struct NiriEdgePicturePresentation: Equatable {
    let frame: CGRect
    let displayFrame: CGRect
    let scale: CGFloat
    let windowId: UInt32
    var otherDisplayFrames: [CGRect] = []
    var isMoving = false
}

@MainActor
protocol NiriEdgePictureSurface: AnyObject {
    var windowId: UInt32? { get }
    var isVisibleForCapture: Bool { get }
    func setOrderingTarget(_ windowId: Int?)
    func update(
        geometry: NiriEdgePictureGeometry,
        content: NiriPictureContent,
        activate: @escaping @MainActor () -> Void
    )
    func setContent(_ content: NiriPictureContent)
    func observeVisibility(_ changed: (@MainActor () -> Void)?)
    func hide()
    func destroy()
}

extension NiriEdgePictureSurface {
    func setContent(_: NiriPictureContent) {}
    func observeVisibility(_: (@MainActor () -> Void)?) {}

    var windowId: UInt32? {
        nil
    }
}

@MainActor
final class NiriEdgePictures {
    typealias Capture = @MainActor (WindowToken, @escaping @MainActor (CGImage?) -> Void) -> Task<Void, Never>?

    @MainActor
    final class Picture {
        let workspaceId: WorkspaceDescriptor.ID
        let displayId: CGDirectDisplayID
        let displayFrame: CGRect
        let scale: CGFloat
        var geometry: NiriEdgePictureGeometry
        var content: NiriPictureContent?
        var stream: NiriPictureStreamSession?
        var surface: (any NiriEdgePictureSurface)?
        var revealFrame: CGRect?
        var isResting = false

        init(
            workspaceId: WorkspaceDescriptor.ID,
            monitor: LayoutMonitorSnapshot,
            geometry: NiriEdgePictureGeometry
        ) {
            self.workspaceId = workspaceId
            displayId = monitor.displayId
            displayFrame = monitor.frame
            scale = monitor.scale
            self.geometry = geometry
        }
    }

    let capture: Capture
    let prepareStream: NiriPictureStreamSession.Prepare?
    let isOverviewOpen: @MainActor () -> Bool
    let makeSurface: @MainActor () -> any NiriEdgePictureSurface
    private let activate: @MainActor (WindowToken, WorkspaceDescriptor.ID) -> Void
    let orderingWindowId: @MainActor () -> Int?
    let displayFrames: @MainActor () -> [CGRect]
    var spareSurfaces: [any NiriEdgePictureSurface] = []
    var pictures: [WindowToken: Picture] = [:]
    var capturedPictures: [WindowToken: NiriCapturedPicture] = [:]
    var warmStates: [WorkspaceDescriptor.ID: NiriPictureWarmState] = [:]
    var pendingCaptures: [WindowToken: NiriPendingPictureCapture] = [:]
    var readyTokens: Set<WindowToken> = []
    var isUnderMemoryPressure = false
    var removeCaptureObservers: (@MainActor () -> Void)?
    var onPresentationChanged: @MainActor () -> Void = {}
    let isCaptureEligible: @MainActor (WindowToken) -> Bool

    init(
        capture: @escaping Capture = NiriEdgePictures.captureWindow,
        prepareStream: NiriPictureStreamSession.Prepare? = nil,
        makeSurface: @escaping @MainActor () -> any NiriEdgePictureSurface = { NiriEdgePictureWindow() },
        orderingWindowId: @escaping @MainActor () -> Int? = { nil },
        displayFrames: @escaping @MainActor () -> [CGRect] = { [] },
        isCaptureEligible: @escaping @MainActor (WindowToken) -> Bool = { _ in true },
        isOverviewOpen: @escaping @MainActor () -> Bool = { false },
        activate: @escaping @MainActor (WindowToken, WorkspaceDescriptor.ID) -> Void
    ) {
        self.orderingWindowId = orderingWindowId
        self.displayFrames = displayFrames
        self.isCaptureEligible = isCaptureEligible
        self.isOverviewOpen = isOverviewOpen
        self.capture = capture
        self.prepareStream = prepareStream
        self.makeSurface = makeSurface
        self.activate = activate
    }

    isolated deinit {
        for picture in pictures.values { picture.stream?.stop()
            picture.surface?.destroy()
        }
        removeCaptureObservers?()
        for captured in capturedPictures.values { captured.task?.cancel() }
        for surface in spareSurfaces { surface.destroy() }
    }

    func reconcile(_ plan: WorkspaceLayoutPlan) {
        defer { reconcileLiveStreams() }
        let resting = !plan.isInteractiveResize && plan.diff.picturePreparation?.isSettled == true
        let enabled = plan.isActiveWorkspace && plan.monitor.orientation == .vertical
        let desired = enabled ? plan.diff.edgeHiddenFrames : [:]
        preparePictures(plan, enabled: enabled)
        guard !desired.isEmpty || pictures.values.contains(where: { $0.workspaceId == plan.workspaceId })
        else { return }
        let otherDisplays = displayFrames().filter { $0 != plan.monitor.frame }
        for (token, picture) in pictures where picture.workspaceId == plan.workspaceId {
            guard enabled, picture.displayId == plan.monitor.displayId,
                  picture.displayFrame == plan.monitor.frame, picture.scale == plan.monitor.scale
            else { remove(token)
                continue
            }
            if desired[token] != nil { continue }
            guard let change = plan.diff.frameChanges.first(where: { $0.token == token }),
                  let geometry = NiriEdgePictureGeometry(
                      frame: change.frame, displayFrame: plan.monitor.frame, otherDisplayFrames: otherDisplays
                  )
            else { retirePicture(token)
                continue
            }
            picture.revealFrame = change.frame
            picture.isResting = false
            picture.geometry = geometry
            present(token, picture: picture)
        }
        for (token, frame) in desired {
            guard let geometry = NiriEdgePictureGeometry(
                frame: frame, displayFrame: plan.monitor.frame, otherDisplayFrames: otherDisplays
            )
            else { retirePicture(token)
                continue
            }
            if let picture = pictures[token] {
                if picture.workspaceId != plan.workspaceId {
                    remove(token)
                } else {
                    picture.revealFrame = nil
                    picture.isResting = resting
                    picture.geometry = geometry
                    present(token, picture: picture)
                    continue
                }
            }
            let picture = Picture(workspaceId: plan.workspaceId, monitor: plan.monitor, geometry: geometry)
            picture.isResting = resting
            pictures[token] = picture
            preparePicture(token, picture: picture, plan: plan)
        }
    }

    func frameApplicationEnded(token: WindowToken, targetFrame: CGRect, applied: Bool = true) {
        finishPendingCapture(token, targetFrame: targetFrame, applied: applied)
        guard let picture = pictures[token], picture.revealFrame == targetFrame else { return }
        retirePicture(token)
    }

    func retainCurrentContexts(
        _ isCurrent: (WindowToken, WorkspaceDescriptor.ID, CGDirectDisplayID, CGRect) -> Bool
    ) {
        for (token, pending) in pendingCaptures
            where !isCurrent(token, pending.key.workspaceId, pending.key.displayId, pending.key.displayFrame)
        { remove(token) }
        for (token, captured) in capturedPictures
            where !isCurrent(token, captured.key.workspaceId, captured.key.displayId, captured.key.displayFrame)
        { remove(token) }
        for (token, picture) in pictures
            where !isCurrent(token, picture.workspaceId, picture.displayId, picture.displayFrame)
        {
            remove(token)
        }
    }

    func retainWorkspaces(_ workspaceIds: Set<WorkspaceDescriptor.ID>) {
        for (token, pending) in pendingCaptures where !workspaceIds.contains(pending.key.workspaceId) { remove(token) }
        for (token, captured) in capturedPictures
            where !workspaceIds.contains(captured.key.workspaceId) { remove(token) }
        for workspaceId in warmStates.keys where !workspaceIds.contains(workspaceId) { warmStates[workspaceId] = nil }
        for (token, picture) in pictures where !workspaceIds.contains(picture.workspaceId) {
            remove(token)
        }
    }

    func remove(_ token: WindowToken) {
        let picture = pictures.removeValue(forKey: token)
        picture?.stream?.stop()
        if let surface = picture?.surface {
            surface.observeVisibility(nil)
            surface.destroy()
            onPresentationChanged()
        }
        discardCapture(token)
        pendingCaptures[token] = nil
        reconcileLiveStreams()
    }

    func reset() {
        for token in pictures.keys { remove(token) }
        for token in capturedPictures.keys { discardCapture(token) }
        pendingCaptures.removeAll()
        warmStates.removeAll()
        for surface in spareSurfaces { surface.destroy() }
        spareSurfaces.removeAll()
    }

    func present(_ token: WindowToken, picture: Picture) {
        guard let content = picture.content else { return }
        let mounted = picture.surface == nil
        if mounted {
            picture.surface = spareSurfaces.popLast() ?? makeSurface()
            picture.surface?.setOrderingTarget(orderingWindowId())
            picture.surface?.observeVisibility { [weak self, weak picture] in
                guard let self, let picture, pictures[token] === picture else { return }
                reconcileLiveStreams()
            }
        }
        picture.surface?.update(geometry: picture.geometry, content: content) { [weak self, weak picture] in
            guard let self, let picture, pictures[token] === picture else { return }
            activate(token, picture.workspaceId)
        }
        if mounted {
            onPresentationChanged()
            reconcileLiveStreams()
        }
    }

    func presentation(for token: WindowToken) -> NiriEdgePicturePresentation? {
        guard let picture = pictures[token], let windowId = picture.surface?.windowId else { return nil }
        return NiriEdgePicturePresentation(
            frame: picture.geometry.frame, displayFrame: picture.displayFrame, scale: picture.scale, windowId: windowId,
            otherDisplayFrames: picture.geometry.otherDisplayFrames, isMoving: !picture.isResting
        )
    }

    static func captureWindow(
        _ token: WindowToken,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) -> Task<Void, Never>? {
        guard ScreenCapturePermissionMonitor.shared.isGranted else { completion(nil)
            return nil
        }
        return Task {
            let image = try? await SkyLight.shared.windowPictureDeferred(for: token)
            guard !Task.isCancelled else { return }
            completion(image)
        }
    }
}

extension WMController {
    func makeEdgePictures() -> NiriEdgePictures {
        let pictures = NiriEdgePictures(
            prepareStream: NiriPictureStreamSession.prepareNative,
            orderingWindowId: { [weak self] in self?.workspaceManager.nativeManagedFocusToken?.windowId },
            displayFrames: { [weak self] in self?.workspaceManager.monitors.map(\.frame) ?? [] },
            isCaptureEligible: { [weak self] token in
                self?.workspaceManager.entry(for: token)?.axRef != nil && ScreenCapturePermissionMonitor.shared
                    .isGranted
            },
            isOverviewOpen: { [weak self] in self?.windowActionHandler.overviewState.isOpen == true },
            activate: { [weak self] in self?.activateEdgePicture($0, in: $1) }
        )
        pictures.onPresentationChanged = { [weak self] in self?.surfaceReconciler.noteWorldChanged() }
        observePictureCaptureState(pictures)
        return pictures
    }

    func pruneEdgePictures() {
        niriEdgePictures.retainCurrentContexts { token, workspaceId, displayId, displayFrame in
            guard let monitor = workspaceManager.monitor(for: workspaceId),
                  monitor.displayId == displayId, monitor.frame == displayFrame,
                  settings.monitors.effectiveOrientation(for: monitor) == .vertical,
                  workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId,
                  workspaceManager.entry(for: token)?.workspaceId == workspaceId,
                  workspaceManager.layoutReason(for: token) != .nativeFullscreen
            else { return false }
            return true
        }
    }

    func activateEdgePicture(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let node = niriEngine?.findNode(for: token, in: workspaceId),
              let monitor = workspaceManager.monitor(for: workspaceId),
              workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else { return }
        var state = workspaceManager.niriViewportState(for: workspaceId)
        niriLayoutHandler.activateNode(
            node, in: workspaceId, state: &state,
            options: NodeActivationOptions(focusOrigin: .pointerSelection)
        )
        workspaceManager.applySessionPatch(
            .init(workspaceId: workspaceId, viewportState: state, rememberedFocusToken: nil)
        )
    }
}
