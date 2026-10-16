// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMScriptHost

@MainActor
final class ShellHiddenBarMenu {
    let popout: ShellPopout

    private weak var parent: ShellPopout?
    private let onSelect: (String) -> Void
    private let onFailure: () -> Void
    private let available: CGSize
    private var page: HiddenBarMenuPage
    private var text = ShellTextStore()
    private var epoch: Int?
    private var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
    private var worker: Task<Void, Never>?
    private var package: ShellWidgetPackage?
    var tracePackage: ShellWidgetPackage? {
        package
    }

    private var keyMonitor: Any?
    private var closed = false

    init(
        page: HiddenBarMenuPage,
        anchor: ShellAnchor,
        parent: ShellPopout,
        resources: ShellResources,
        resourceStore: ShellResourceStore? = nil,
        source: ShellWidgetSource,
        directories: [URL],
        onSelect: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.page = page
        self.parent = parent
        self.onSelect = onSelect
        self.onFailure = onFailure
        let anchor = ShellAnchor(frame: anchor.frame, level: anchor.level)
        let visible = parent.screen.visibleFrame
        let below = PopupAttachment(sourceFrame: anchor.frame, edge: .below).availableSize(in: visible)
        let above = PopupAttachment(sourceFrame: anchor.frame, edge: .above).availableSize(in: visible)
        available = CGSize(width: below.width, height: max(below.height, above.height))
        popout = ShellPopout(
            widget: "hidden-bar-menu",
            key: parent.key,
            anchor: anchor,
            screen: parent.screen,
            resources: resources,
            directories: directories,
            tracksDismissal: false,
            fitsAroundAnchor: true,
            onDismiss: {}
        )
        popout.surface.focusAxis = .vertical
        popout.surface.onAction = { [weak self] click in
            guard let self, !closed else { return }
            perform(click)
        }
        let outbox = ShellWidgetOutbox { [weak self] batch in
            self?.receive(batch)
        }
        let package = ShellWidgetPackage(
            name: popout.widget,
            generation: 0,
            outbox: outbox,
            resourceStore: resourceStore,
            retireResourceImages: { [images = resources.resourceImages] owner in await images?.retire(owner) }
        )
        self.package = package
        let mailbox = startWorker(package, source: source)
        update(page: page)
        mailbox.yield(.bars([parent.key: ShellBarData()]))
        mailbox.yield(.popout(parent.key, true))
        parent.setCompanion(popout)
        installKeyboardForwarding()
    }

    private func startWorker(
        _ package: ShellWidgetPackage, source: ShellWidgetSource
    ) -> AsyncStream<ShellWidgetMessage>.Continuation {
        let retiring = Array(ShellWidgetHost.retiringTasks.values)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        package.capture.attach(mailbox)
        ShellWidgetHost.joinTraceCapture(package)
        package.services.attachWake { mailbox.yield(.services) }
        package.resourceInbox.attachWake { mailbox.yield(.resources) }
        self.mailbox = mailbox
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            for task in retiring { await task.value }
            guard !Task.isCancelled else { await package.close()
                return
            }
            if await package.load(source) != nil {
                await self?.fail()
            } else {
                for await message in messages {
                    guard !Task.isCancelled else { break }
                    await package.receive(message)
                }
            }
            await package.close()
        }
        return mailbox
    }

    isolated deinit {
        close()
    }

    func update(page: HiddenBarMenuPage) {
        guard !closed else { return }
        self.page = page
        var data = ShellWidgetData()
        data.hiddenBar.menu = page
        data.hiddenBar.maxWidth = Double(available.width)
        data.hiddenBar.maxHeight = Double(available.height)
        mailbox?.yield(.update(data))
    }

    func close() {
        guard !closed else { return }
        closed = true
        ShellWidgetHost.retireTraceCapture(package)
        mailbox?.finish()
        mailbox = nil
        worker?.cancel()
        worker = nil
        ShellWidgetHost.close(package)
        package = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        parent?.setCompanion(nil)
        popout.surface.onAction = nil
        popout.close(animated: false)
    }

    private func perform(_ click: ShellClick) {
        guard click.action & OMNI_ACTION_HANDLER != 0 else {
            select(text.string(click.action))
            return
        }
        var event = click.event
        let id = ShellInvocation.next()
        event.invocationID = id
        event.sourceID = popout.surface.sourceID
        if let token = event.trackingToken { popout.surface.bindGestureInvocation(trackToken: token, invocationID: id) }
        var enqueued = false
        defer { if !enqueued { popout.surface.acknowledgeGesture(through: id) } }
        guard let package, let mailbox else { return }
        let sequence = click.sequence ?? popout.surface.sequence
        if event.isGesture {
            let gesture = ShellGestureBox.Gesture(
                bar: popout.key,
                view: .popout,
                action: click.action,
                sequence: sequence,
                event: event
            )
            if let pending = package.gestures.post(gesture) {
                if case .enqueued = mailbox.yield(.gesture(pending)) { enqueued = true }
            } else { enqueued = true }
        } else {
            package.gestures.seal()
            if case .enqueued = mailbox.yield(.invoke(
                popout.key,
                .popout,
                action: click.action,
                sequence: sequence,
                event: event
            )) {
                enqueued = true
            }
        }
    }

    private func receive(_ batch: [String: ShellWidgetDelivery]) {
        guard !closed, let delivery = batch[popout.widget] else { return }
        guard delivery.failure == nil else {
            fail()
            return
        }
        let key = ShellTreeKey(bar: popout.key, view: .popout)
        let acknowledgement = delivery.acknowledgements[key]?.invocationID ?? 0
        guard !delivery.trees.isEmpty else {
            popout.surface.acknowledgeGesture(through: acknowledgement)
            return
        }
        if epoch != delivery.epoch {
            epoch = delivery.epoch
            text = ShellTextStore()
            popout.surface.reset(text: text)
        }
        text.ingest(delivery.strings, count: delivery.stringCount)
        if let tree = delivery.trees[key] {
            popout.surface.sequence = tree.sequence
            if !popout.apply(tree.nodes, text: text, gestureAcknowledgement: acknowledgement) { fail() }
        } else {
            popout.surface.acknowledgeGesture(through: acknowledgement)
        }
    }

    private func select(_ command: String) {
        let prefix = "hidden-bar-menu "
        guard command.hasPrefix(prefix) else { return }
        let id = String(command.dropFirst(prefix.count))
        guard id == page.backID || page.rows.contains(where: { $0.id == id && $0.enabled && !$0.separator }) else {
            return
        }
        onSelect(id)
    }

    private func installKeyboardForwarding() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let parent, !closed, popout.panel.isVisible, parent.panel.isKeyWindow,
                  !parent.surface.hasFocusedTextInput, !popout.surface.hasFocusedTextInput,
                  popout.surface.handleKey(event.keyCode, shift: event.modifierFlags.contains(.shift))
            else { return event }
            return nil
        }
    }

    private func fail() {
        guard !closed else { return }
        close()
        onFailure()
    }
}
