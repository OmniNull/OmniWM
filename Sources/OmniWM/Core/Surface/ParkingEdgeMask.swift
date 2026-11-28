// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ParkingEdgeMaskManager {
    private var windowsByKey: [ParkingEdgeMaskKey: ParkingEdgeMaskWindow] = [:]
    private let pointerLocation: @MainActor () -> CGPoint
    private let sleep: @MainActor (Duration) async throws -> Void
    var canInteract: @MainActor (Bool) -> Bool = { _ in true }
    var animationsEnabled: @MainActor () -> Bool = { true }
    var navigationInterval: @MainActor () -> TimeInterval = { SettingsExport.Focus.defaults().edgeNavigationInterval }
    var onActivate: (@MainActor (ParkingEdgeMaskKey, ParkingEdgeNavigation) -> Bool)?

    init(
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pointerLocation = pointerLocation
        self.sleep = sleep
    }

    isolated deinit {
        for window in windowsByKey.values {
            window.destroy()
        }
    }

    func apply(_ masks: [DesiredParkingEdgeMask]) {
        var staleKeys = Set(windowsByKey.keys)

        for mask in masks {
            staleKeys.remove(mask.key)
            let window = windowsByKey[mask.key] ?? {
                let window = ParkingEdgeMaskWindow(
                    key: mask.key,
                    pointerLocation: pointerLocation,
                    sleep: sleep,
                    canInteract: { [weak self] in self?.canInteract($0) == true },
                    animationsEnabled: { [weak self] in self?.animationsEnabled() == true },
                    navigationInterval: { [weak self] in
                        self?.navigationInterval() ?? SettingsExport.Focus.defaults().edgeNavigationInterval
                    },
                    onActivate: { [weak self] in self?.onActivate?(mask.key, $0) == true }
                )
                windowsByKey[mask.key] = window
                return window
            }()
            window.apply(mask)
        }

        for key in staleKeys {
            windowsByKey.removeValue(forKey: key)?.destroy()
        }
    }

    func removeAll() {
        for window in windowsByKey.values {
            window.destroy()
        }
        windowsByKey.removeAll()
    }
}

@MainActor
final class ParkingEdgeMaskWindow: NSPanel {
    static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    private enum HoverPhase {
        case outside
        case entered
        case awaitingTarget
        case consumed
    }

    private let key: ParkingEdgeMaskKey
    private let surfaceId: String
    private let pointerLocation: @MainActor () -> CGPoint
    private let sleep: @MainActor (Duration) async throws -> Void
    private let canInteract: @MainActor (Bool) -> Bool
    private let animationsEnabled: @MainActor () -> Bool
    private let navigationInterval: @MainActor () -> TimeInterval
    private let onActivate: @MainActor (ParkingEdgeNavigation) -> Bool
    private var appliedMask: DesiredParkingEdgeMask?
    private var phase = HoverPhase.outside
    private(set) var dwellTask: Task<Void, Never>?
    private var fin: ParkingEdgeFinWindow?

    init(
        key: ParkingEdgeMaskKey,
        pointerLocation: @escaping @MainActor () -> CGPoint,
        sleep: @escaping @MainActor (Duration) async throws -> Void,
        canInteract: @escaping @MainActor (Bool) -> Bool,
        animationsEnabled: @escaping @MainActor () -> Bool,
        navigationInterval: @escaping @MainActor () -> TimeInterval = {
            SettingsExport.Focus.defaults().edgeNavigationInterval
        },
        onActivate: @escaping @MainActor (ParkingEdgeNavigation) -> Bool
    ) {
        self.key = key
        self.pointerLocation = pointerLocation
        self.sleep = sleep
        self.canInteract = canInteract
        self.animationsEnabled = animationsEnabled
        self.navigationInterval = navigationInterval
        self.onActivate = onActivate
        surfaceId = "parking-edge-mask-\(key.monitorId.displayId)-\(key.side.rawValue)"

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        level = Self.windowLevel
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let maskView = ParkingEdgeMaskView(frame: .zero)
        maskView.onHoverChange = { [weak self] in self?.updateHover() }
        maskView.onActivate = { [weak self] in self?.activate(isHover: false) }
        maskView.wantsLayer = true
        maskView.layer?.backgroundColor = NSColor.black.cgColor
        contentView = maskView

        let maskWindowNumber = windowNumber
        if maskWindowNumber > 0 {
            SkyLight.shared.excludeFromScreencaptureWindowSelection(UInt32(maskWindowNumber))
        }

        SurfaceCoordinator.shared.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .parkingEdgeMask,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func apply(_ mask: DesiredParkingEdgeMask) {
        let previous = appliedMask
        appliedMask = mask
        if previous?.frame != mask.frame || frame != mask.frame {
            endHover()
            setFrame(mask.frame, display: true)
            contentView?.frame = CGRect(origin: .zero, size: mask.frame.size)
        } else if previous?.navigation != mask.navigation {
            let continuesNavigation = phase == .awaitingTarget
                && previous?.navigation?.workspaceId == mask.navigation?.workspaceId
                && previous?.navigation?.target != mask.navigation?.target
            cancelDwell()
            if continuesNavigation {
                phase = .entered
            } else if phase != .outside {
                phase = .consumed
            }
        }
        if mask.navigation == nil {
            cancelDwell()
            fin?.hide()
        } else {
            updateDwell()
        }

        if !isVisible {
            orderFrontRegardless()
        }
    }

    func updateHover() {
        let point = pointerLocation()
        guard NSMouseInRect(point, frame, false) || fin?.contains(point) == true else {
            endHover()
            return
        }
        guard phase == .outside else { return }
        phase = .entered
        guard appliedMask?.navigation != nil, canInteract(false) else { return }
        let fin = fin ?? {
            let window = ParkingEdgeFinWindow(
                key: key,
                onHoverChange: { [weak self] in self?.updateHover() },
                onActivate: { [weak self] in self?.activate(isHover: false) }
            )
            self.fin = window
            return window
        }()
        fin.show(at: point, maskFrame: frame, animated: animationsEnabled())
        updateDwell()
    }

    private func updateDwell() {
        guard phase == .entered else { return }
        guard appliedMask?.navigation?.hoverEnabled == true,
              fin?.isVisible == true,
              NSMouseInRect(pointerLocation(), frame, false) || fin?.contains(pointerLocation()) == true,
              canInteract(true)
        else {
            cancelDwell()
            return
        }
        guard dwellTask == nil else { return }
        let interval = navigationInterval()
        fin?.setProgress(duration: interval)
        let sleep = sleep
        dwellTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.activate(isHover: true)
        }
    }

    private func activate(isHover: Bool) {
        guard let navigation = appliedMask?.navigation,
              NSMouseInRect(pointerLocation(), frame, false) || fin?.contains(pointerLocation()) == true,
              canInteract(isHover),
              !isHover || phase == .entered && navigation.hoverEnabled
        else {
            endHover()
            return
        }
        phase = .awaitingTarget
        cancelDwell()
        fin?.setProgress(duration: 0)
        if !onActivate(navigation) {
            phase = .consumed
            cancelDwell()
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        fin?.setProgress(duration: nil)
    }

    private func endHover() {
        phase = .outside
        cancelDwell()
        fin?.hide()
    }

    func destroy() {
        appliedMask = nil
        endHover()
        fin?.destroy()
        fin = nil
        SurfaceCoordinator.shared.unregister(id: surfaceId)
        orderOut(nil)
        close()
    }
}

private final class ParkingEdgeMaskView: NSView {
    var onHoverChange: (@MainActor () -> Void)?
    var onActivate: (@MainActor () -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with _: NSEvent) {
        onHoverChange?()
    }

    override func mouseExited(with _: NSEvent) {
        onHoverChange?()
    }

    override func mouseMoved(with _: NSEvent) {
        onHoverChange?()
    }

    override func mouseDown(with _: NSEvent) {
        onActivate?()
    }
}
