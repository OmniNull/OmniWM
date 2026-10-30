// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellManipulationState: Sendable {
    let source: ElementHandle
    let target: ElementHandle
    let parent: ElementHandle
    let token: UInt64
    let recipe: ShellManipulationRecipe
    let start: CGRect
    let origin: CGPoint
    var preview: CGRect
    var proposal: ShellManipulationProposal
    var holding = false
    var invocationID: UInt64?

    var transaction: String {
        "placement-\(token)"
    }
}

extension ShellWidgetSurface {
    func manipulationTarget(from source: ElementHandle, key: UInt64) -> ElementHandle? {
        var current = layout.core.parent(of: source)
        while layout.core.contains(current) {
            if layout.core.key(of: current) == key {
                let parent = layout.core.parent(of: current)
                guard layout.core.contains(parent), layout.core.layoutStyle(of: parent).axis == .overlay,
                      !layout.core.content(of: current).decorative,
                      layout.core.paint(of: current).rotate == 0 else { return nil }
                return current
            }
            current = layout.core.parent(of: current)
        }
        return nil
    }

    func manipulationOwner(of handle: ElementHandle) -> ElementHandle? {
        var current = handle
        while layout.core.contains(current) {
            if manipulationTargets[current] != nil { return current }
            current = layout.core.parent(of: current)
        }
        return nil
    }

    var presentation: SurfacePresentation? {
        revealPresentation(over: placementPresentation)
    }

    var placementPresentation: SurfacePresentation? {
        var targets: [ElementHandle: SurfacePresentation.Group] = [:]
        let now = follows.values.contains { $0.motion != nil } ? clock() : 0
        if let current = manipulation {
            targets[current.target] = followMotion(of: current.target).map {
                placement(of: current.target, at: $0.rect(at: now), scaled: true)
            } ?? placement(of: current.target, at: current.preview, scaled: current.recipe.mode == .scale)
        }
        for (target, record) in follows where targets[target] == nil {
            guard let motion = record.motion else { continue }
            targets[target] = placement(of: target, at: motion.rect(at: now), scaled: true)
        }
        if layout.core.contains(selectedManipulation), targets[selectedManipulation] == nil {
            targets[selectedManipulation] = placement(
                of: selectedManipulation,
                at: CGRect(layout.core.absoluteFrame(of: selectedManipulation)),
                scaled: false
            )
        }
        return targets.isEmpty ? nil : SurfacePresentation(targets: targets)
    }

    private func placement(of target: ElementHandle, at rect: CGRect, scaled: Bool) -> SurfacePresentation.Group? {
        guard layout.core.contains(target) else { return nil }
        let absolute = CGRect(layout.core.absoluteFrame(of: target))
        let local = layout.core.layoutFrame(of: target)
        return SurfacePresentation.Group(
            frame: Rect(
                x: local.x + Float(rect.minX - absolute.minX),
                y: local.y + Float(rect.minY - absolute.minY),
                width: Float(rect.width), height: Float(rect.height)
            ),
            scale: scaled ? Float(rect.width / absolute.width) : 1,
            visible: true
        )
    }

    func isManipulationClip(_ handle: ElementHandle) -> Bool {
        manipulation?.target == handle
    }

    func isWithin(_ handle: ElementHandle, _ ancestor: ElementHandle) -> Bool {
        guard layout.core.contains(ancestor) else { return false }
        var current = handle
        while layout.core.contains(current) {
            if current == ancestor { return true }
            current = layout.core.parent(of: current)
        }
        return false
    }

    func presentedFrame(of handle: ElementHandle) -> Rect {
        presentedFrame(of: handle, in: presentation)
    }

    func presentedFrame(of handle: ElementHandle, in presentation: SurfacePresentation?) -> Rect {
        var frame = layout.core.absoluteFrame(of: handle)
        guard let presentation else { return frame }
        var current = handle
        while layout.core.contains(current) {
            if let placement = presentation.placement(of: current) {
                let absolute = layout.core.absoluteFrame(of: current)
                let local = layout.core.layoutFrame(of: current)
                let x = absolute.x + placement.frame.x - local.x
                let y = absolute.y + placement.frame.y - local.y
                frame = current == handle
                    ? Rect(x: x, y: y, width: placement.frame.width, height: placement.frame.height)
                    : Rect(
                        x: x + (frame.x - absolute.x) * placement.scale,
                        y: y + (frame.y - absolute.y) * placement.scale,
                        width: frame.width * placement.scale,
                        height: frame.height * placement.scale
                    )
            }
            current = layout.core.parent(of: current)
        }
        return frame
    }

    func presentedScale(of handle: ElementHandle, in presentation: SurfacePresentation?) -> CGFloat {
        guard let presentation else { return 1 }
        var scale: Float = 1
        var current = handle
        while layout.core.contains(current) {
            scale *= presentation.placement(of: current)?.scale ?? 1
            current = layout.core.parent(of: current)
        }
        return CGFloat(scale)
    }

    func layoutPoint(_ point: CGPoint, in handle: ElementHandle, presentation: SurfacePresentation?) -> CGPoint {
        let frame = presentedFrame(of: handle, in: presentation)
        let scale = presentedScale(of: handle, in: presentation)
        guard scale > 0 else { return CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity) }
        return CGPoint(x: (point.x - CGFloat(frame.x)) / scale, y: (point.y - CGFloat(frame.y)) / scale)
    }

    func selectManipulation(at point: CGPoint) {
        let hit = element(at: point) { $0.acceptsPointer }
        guard let owner = manipulationOwner(of: hit) else { return }
        selectManipulation(owner: owner)
    }

    func selectManipulation(owner: ElementHandle) {
        guard let source = manipulationTargets[owner], selectedManipulation != owner else { return }
        if declaredFocus, let active = manipulationOwner(of: focused), active != owner { blurDeclaredFocus() }
        if layout.core.contains(selectedManipulation) {
            scene.submit([.raise(slot: selectedManipulation.slot, false)], animated: false)
        }
        selectedManipulation = owner
        let rect = CGRect(layout.core.absoluteFrame(of: owner))
        scene.submit([.raise(slot: owner.slot, true)], animated: false)
        emitManipulation(
            source: source,
            phase: .selected,
            transaction: nil,
            proposal: ShellManipulationProposal(rect: rect)
        )
        layoutTextInputs()
    }

    private func beginManipulation(_ sample: ShellPointerGesture.Sample) -> Bool {
        guard let capture = gestureCapture,
              let recipe = gestureTrackRecipes[capture.content.gestureTrack]?.manipulation else { return false }
        cancelManipulation(reason: "superseded")
        guard let target = manipulationTarget(from: sample.handle, key: recipe.target) else { return true }
        var start = CGRect(layout.core.absoluteFrame(of: target))
        if recipe.mode == .scale, let motion = followMotion(of: target) {
            start.origin = motion.rect(at: clock()).origin
        }
        guard let proposal = ShellManipulationGeometry.proposal(rect: start, recipe: recipe) else { return true }
        let current = ShellManipulationState(
            source: sample.handle, target: target, parent: layout.core.parent(of: target),
            token: ShellInvocation.next(), recipe: recipe, start: start,
            origin: CGPoint(x: gesturePointer.x - sample.translation.x, y: gesturePointer.y - sample.translation.y),
            preview: start, proposal: proposal
        )
        manipulation = current
        selectedManipulation = target
        setManipulationCursor(true, at: gesturePointer)
        emitManipulation(
            source: current.source,
            phase: .began,
            transaction: current.transaction,
            proposal: proposal
        )
        return true
    }

    @discardableResult
    func updateManipulation(_ sample: ShellPointerGesture.Sample) -> Bool {
        if sample.phase == .began {
            guard beginManipulation(sample) else { return false }
            if manipulation == nil { return true }
        }
        guard var current = manipulation, current.source == sample.handle, !current.holding else { return false }
        guard let rect = ShellManipulationGeometry.sample(
                  start: current.start,
                  translation: sample.translation,
                  recipe: current.recipe
              ),
              let proposal = ShellManipulationGeometry.proposal(rect: rect, recipe: current.recipe)
        else { cancelManipulation(reason: "geometry")
            return true
        }
        current.preview = rect
        current.proposal = proposal
        manipulation = current
        presentManipulation(current)
        return true
    }

    @discardableResult
    func finishManipulation(_ sample: ShellPointerGesture.Sample) -> Bool {
        guard var current = manipulation, current.source == sample.handle else { return false }
        let point = CGPoint(x: current.origin.x + sample.translation.x, y: current.origin.y + sample.translation.y)
        guard sample.phase != .cancelled,
              let rect = ShellManipulationGeometry.sample(
                  start: current.start,
                  translation: sample.translation,
                  recipe: current.recipe
              ),
              let proposal = ShellManipulationGeometry.proposal(rect: rect, recipe: current.recipe),
              layout.core.contains(current.source), layout.core.contains(current.target),
              layout.core.content(of: current.source).gestureAction != 0
        else { setManipulationCursor(false, at: point)
            cancelManipulation(reason: "cancelled")
            return true
        }
        current.preview = proposal.rect
        current.proposal = proposal
        current.holding = true
        manipulation = current
        presentManipulation(current)
        setManipulationCursor(false, at: point)
        emitManipulation(
            source: current.source,
            phase: .ended,
            transaction: current.transaction,
            proposal: proposal,
            trackingToken: current.token
        )
        return true
    }

    private func presentManipulation(_ current: ShellManipulationState) {
        let actual = CGRect(layout.core.absoluteFrame(of: current.target))
        scene.submit(manipulationCommands(
            current.target, token: current.token,
            presentation: followPresentation(current, layout: actual) ?? stillPresentation(current),
            active: true
        ), animated: false)
        layoutTextInputs()
        onMove?()
    }

    func stillPresentation(_ current: ShellManipulationState) -> ShellManipulationPresentation {
        let actual = CGRect(layout.core.absoluteFrame(of: current.target))
        return .still(
            translation: CGPoint(x: current.preview.minX - actual.minX, y: current.preview.minY - actual.minY),
            scale: current.recipe.mode == .scale ? current.preview.width / actual.width : 1,
            clip: current.recipe.mode == .resize
                ? ShellManipulationClip(size: current.preview.size, outline: outline(of: current.recipe)) : nil
        )
    }

    private func outline(of recipe: ShellManipulationRecipe) -> CGColor? {
        guard let outline = recipe.outline else { return ShellManipulationClip.standardOutline }
        return outline.enabled ? palette.color(outline.color) : nil
    }

    private func followPresentation(
        _ current: ShellManipulationState,
        layout actual: CGRect
    ) -> ShellManipulationPresentation? {
        guard var record = follows[current.target] else { return nil }
        let now = clock()
        guard current.recipe.mode != .resize,
              let motion = record.motion?.retargeted(at: now, to: current.preview)
              ?? ShellManipulationMotion(from: actual, to: current.preview, begin: now, spring: record.spring)
        else {
            follows[current.target]?.motion = nil
            return nil
        }
        record.motion = motion
        record.token = current.token
        record.frame = actual
        follows[current.target] = record
        return .motion(motion.wrapper(for: actual))
    }

    func reconcileManipulation() {
        if let current = manipulation {
            guard layout.core.contains(current.source), layout.core.contains(current.target),
                  layout.core.parent(of: current.target) == current.parent,
                  manipulationTarget(from: current.source, key: current.recipe.target) == current.target
            else { cancelManipulation(reason: "removed", immediate: true)
                return
            }
        }
        finishSettle { !layout.core.contains($0) }
    }

    func finishManipulationLayout(
        through acknowledgement: UInt64,
        commands: inout [ShellLayerCommand]
    ) -> ShellManipulationState? {
        guard var current = manipulation, current.holding, let invocation = current.invocationID,
              invocation <= acknowledgement, let text else { return nil }
        guard layout.core.contains(current.target),
              text.string(layout.core.content(of: current.target).manipulationCommit) == current.transaction
        else { cancelManipulation(reason: "layout-rejected")
            return nil
        }
        current.proposal = ShellManipulationProposal(rect: CGRect(layout.core.absoluteFrame(of: current.target)))
        if followMotion(of: current.target) == nil {
            commands += released(current.target, token: current.token)
            follows[current.target]?.commit = layout.core.content(of: current.target).manipulationCommit
        }
        manipulation = nil
        if selectedManipulation == current.target { selectedManipulation = .none }
        layoutTextInputs(into: &commands)
        return current
    }

    func manipulationApplied(_ current: ShellManipulationState) {
        guard layout.core.contains(current.source), layout.core.contains(current.target),
              text?.string(layout.core.content(of: current.target).manipulationCommit) == current.transaction
        else { return }
        emitManipulation(
            source: current.source,
            phase: .applied,
            transaction: current.transaction,
            proposal: current.proposal
        )
    }

    func cancelManipulation(reason: String, immediate: Bool = false) {
        guard let current = manipulation else { return }
        manipulation = nil
        if selectedManipulation == current.target { selectedManipulation = .none }
        if view.cursorState.manipulating { setManipulationCursor(false, at: gesturePointer) }
        var commands: [ShellLayerCommand] = []
        if immediate || followMotion(of: current.target) == nil || !layout.core.contains(current.target)
            || !settleFollow(current.target, to: CGRect(layout.core.absoluteFrame(of: current.target)), into: &commands)
        {
            follows[current.target]?.motion = nil
            commands = released(current.target, token: current.token)
        }
        scene.submit(commands, animated: false)
        emitManipulation(
            source: current.source,
            phase: .cancelled,
            transaction: current.transaction,
            proposal: current.proposal,
            reason: reason
        )
        layoutTextInputs()
        onMove?()
    }

    func released(_ target: ElementHandle, token: UInt64) -> [ShellLayerCommand] {
        manipulationCommands(target, token: token, presentation: .identity, active: false)
            + [.raise(slot: target.slot, false)]
    }

    func followMotion(of target: ElementHandle) -> ShellManipulationMotion? {
        follows[target]?.motion
    }

    private func emitManipulation(
        source: ElementHandle, phase: ShellEvent.Phase, transaction: String?,
        proposal: ShellManipulationProposal, trackingToken: UInt64? = nil, reason: String? = nil
    ) {
        guard layout.core.contains(source) else { return }
        var event = ShellEvent(button: .left)
        event.kind = .gesture
        event.phase = phase
        event.transaction = transaction
        event.placement = proposal
        event.trackingToken = trackingToken
        event.committed = phase == .ended || phase == .applied
        event.reason = reason
        let capture = capture(source)
        emit(capture.content.gestureAction, capture: capture, point: gesturePointer, event: event)
    }
}
