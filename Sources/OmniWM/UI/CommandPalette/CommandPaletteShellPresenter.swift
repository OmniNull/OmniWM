// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMScriptHost
import OmniWMShellCore

@MainActor
final class CommandPaletteShellPresenter {
    static let queryKey = "query"
    static let resultsKey = "results"
    static let commandPrefix = "palette "
    static let beforeKey = ShellWidgetLayout.elementKey("results-before")
    static let afterKey = ShellWidgetLayout.elementKey("results-after")
    static let resultsElement = ShellWidgetLayout.elementKey(resultsKey)

    let config: ShellConfig
    let fingerprint: [String: SettingsFileAccess.Fingerprint]
    let surface: ShellWidgetSurface
    let chrome: ShellChromeView
    private let fieldFrame: CGRect
    private(set) lazy var field = surface.pinTextInput(key: Self.queryKey, frame: fieldFrame) { [weak self] event in
        self?.receiveText(event)
    }

    var onQuery: (@MainActor (String) -> Void)?
    var onCommand: (@MainActor (String) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    var onTree: (@MainActor () -> Void)?
    var onWindowChange: (@MainActor () -> Void)?
    private(set) var rowWindow = CommandPaletteRowWindow()
    private var applying = false
    private var windowChanged = false
    private var revealRequest = 0
    private var revealedRequest: Int?

    private let key = ShellBarKey(monitor: .fallback)
    private let onNetworkApprovals: ([ShellNetworkApproval]) -> Void
    private let onProviderApprovals: ([ShellProviderApproval]) -> Void
    private var text = ShellTextStore()
    private var epoch: Int?
    private var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
    private var worker: Task<Void, Never>?
    private var package: ShellWidgetPackage?
    private(set) var published: ShellCommandPaletteData?
    private var reportedQuery = ""
    private var closed = false
    private(set) var hasTree = false
    private var lastNodes: [UInt8] = []
    private var lastSequence = 0
    private var drawn: ShellCommandPaletteData?

    init(
        source: ShellCommandPaletteSource,
        scale: CGFloat,
        fieldFrame: CGRect,
        onNetworkApprovals: @escaping ([ShellNetworkApproval]) -> Void = { _ in },
        onProviderApprovals: @escaping ([ShellProviderApproval]) -> Void = { _ in }
    ) {
        config = source.config
        fingerprint = source.fingerprint
        self.onNetworkApprovals = onNetworkApprovals
        self.onProviderApprovals = onProviderApprovals
        self.fieldFrame = fieldFrame
        surface = ShellWidgetSurface(scale: scale, resources: source.resources, directories: source.directories)
        chrome = ShellChromeView(content: surface.view)
        _ = field
        surface.onAction = { [weak self] click in
            guard let self, !closed else { return }
            perform(click)
        }
        surface.onMove = { [weak self] in
            self?.scrolled()
        }
        let outbox = ShellWidgetOutbox { [weak self] batch in
            self?.receive(batch)
        }
        let package = ShellWidgetPackage(
            name: ShellWidgetHost.commandPaletteWidget,
            generation: 0,
            outbox: outbox,
            permissions: source.permissions,
            resourceStore: source.resourceStore,
            retireResourceImages: { [images = source.resources.resourceImages] owner in await images?.retire(owner) }
        )
        self.package = package
        let mailbox = startWorker(package, source: source.source)
        mailbox.yield(.bars([key: ShellBarData()]))
        mailbox.yield(.popout(key, true))
    }

    isolated deinit {
        close()
    }

    func publish(_ data: ShellCommandPaletteData, reveal request: Int? = nil) {
        if let request { revealRequest = request }
        guard !closed, data != published else { return }
        published = data
        if data.query != reportedQuery, !field.hasMarkedText {
            field.setText(data.query)
            reportedQuery = data.query
        }
        var widgetData = ShellWidgetData()
        widgetData.commandPalette = data
        mailbox?.yield(.update(widgetData))
    }

    func resize(to size: CGSize) {
        surface.setRootLimit(size)
    }

    func beginSession() {
        rowWindow.reset()
        revealedRequest = nil
    }

    func revealPending(for request: Int) -> Bool {
        revealedRequest != request
    }

    func slice(ids: [String], selected: Int?, limit: Float) -> CommandPaletteRowWindow.Slice {
        rowWindow.slice(ids: ids, selected: selected, limit: limit)
    }

    func setVisible(_ visible: Bool) {
        surface.setVisible(visible)
    }

    func focusField(in window: NSWindow) {
        window.makeFirstResponder(field.responder)
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
        surface.onAction = nil
        chrome.removeFromSuperview()
    }

    private func startWorker(
        _ package: ShellWidgetPackage, source: ShellWidgetSource
    ) -> AsyncStream<ShellWidgetMessage>.Continuation {
        let retiring = Array(ShellWidgetHost.retiringTasks.values)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        package.capture.attach(mailbox)
        ShellWidgetHost.joinTraceCapture(package)
        package.services.attachWake { mailbox.yield(.services) }
        package.providerInbox.attachWake { mailbox.yield(.providers) }
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

    private func receiveText(_ event: ShellEvent) {
        guard !closed, event.kind == .textChange, let query = event.text else { return }
        reportedQuery = query
        onQuery?(query)
    }

    private func perform(_ click: ShellClick) {
        guard click.action & OMNI_ACTION_HANDLER != 0 else {
            let command = text.string(click.action)
            guard command.hasPrefix(Self.commandPrefix) else { return }
            onCommand?(String(command.dropFirst(Self.commandPrefix.count)))
            return
        }
        var event = click.event
        let id = ShellInvocation.next()
        event.invocationID = id
        event.sourceID = surface.sourceID
        if let token = event.trackingToken { surface.bindGestureInvocation(trackToken: token, invocationID: id) }
        var enqueued = false
        defer { if !enqueued { surface.acknowledgeGesture(through: id) } }
        guard let package, let mailbox else { return }
        let sequence = click.sequence ?? surface.sequence
        if event.isGesture {
            let gesture = ShellGestureBox.Gesture(
                bar: key, view: .popout, action: click.action, sequence: sequence, event: event
            )
            if let pending = package.gestures.post(gesture) {
                if case .enqueued = mailbox.yield(.gesture(pending)) { enqueued = true }
            } else { enqueued = true }
        } else {
            package.gestures.seal()
            if case .enqueued = mailbox.yield(.invoke(
                key, .popout, action: click.action, sequence: sequence, event: event
            )) {
                enqueued = true
            }
        }
    }

    private func receive(_ batch: [String: ShellWidgetDelivery]) {
        guard !closed, let delivery = batch[ShellWidgetHost.commandPaletteWidget] else { return }
        if !delivery.networkApprovals.isEmpty { onNetworkApprovals(delivery.networkApprovals) }
        if !delivery.providerApprovals.isEmpty { onProviderApprovals(delivery.providerApprovals) }
        guard delivery.failure == nil else {
            fail()
            return
        }
        let treeKey = ShellTreeKey(bar: key, view: .popout)
        let acknowledgement = delivery.acknowledgements[treeKey]?.invocationID ?? 0
        guard let tree = delivery.trees[treeKey] else {
            surface.acknowledgeGesture(through: acknowledgement)
            return
        }
        let anchor = visibleAnchor()
        applying = true
        drawn = nil
        if epoch != delivery.epoch {
            epoch = delivery.epoch
            text = ShellTextStore()
            surface.reset(text: text)
        }
        text.ingest(delivery.strings, count: delivery.stringCount)
        surface.sequence = tree.sequence
        guard surface.apply(tree.nodes, text: text, gestureAcknowledgement: acknowledgement, keeping: anchor) else {
            fail()
            return
        }
        lastNodes = tree.nodes
        lastSequence = tree.sequence
        applied()
    }

    func redraw() {
        guard !closed, !lastNodes.isEmpty else { return }
        let anchor = visibleAnchor()
        applying = true
        drawn = nil
        surface.reset(text: text)
        surface.sequence = lastSequence
        guard surface.apply(lastNodes, text: text, keeping: anchor) else {
            fail()
            return
        }
        applied()
    }

    private func applied() {
        hasTree = true
        let current = drawsPublishedList()
        drawn = current ? published : nil
        windowChanged = recordViewport() || windowChanged
        if current {
            windowChanged = measureRows() || windowChanged
            revealIfRequested()
        }
        applying = false
        if windowChanged {
            windowChanged = false
            onWindowChange?()
        }
        onTree?()
    }

    private func fail() {
        guard !closed else { return }
        Log.shell.error("The command palette widget failed; using the built-in palette")
        close()
        onFailure?()
    }
}

extension CommandPaletteShellPresenter {
    private func visibleAnchor() -> ShellScrollAnchor? {
        guard let container = surface.layout.handle(forKey: Self.resultsKey) else { return nil }
        let row = firstVisibleRow(in: container)
        return ShellScrollAnchor(
            container: Self.resultsElement,
            item: row?.key,
            top: row?.top ?? 0,
            offset: surface.layout.core.scrollOffset(of: container)
        )
    }

    private struct VisibleRow {
        let index: Int
        let key: UInt64
        let top: Float
    }

    private func firstVisibleRow(in container: ElementHandle) -> VisibleRow? {
        let offset = surface.layout.core.scrollOffset(of: container)
        var index = 0
        var found: VisibleRow?
        surface.layout.core.forEachChild(of: container) { child, key in
            guard found == nil, key != Self.beforeKey, key != Self.afterKey else { return }
            let frame = surface.layout.core.layoutFrame(of: child)
            if frame.y + frame.height > offset { found = VisibleRow(index: index, key: key, top: frame.y - offset) }
            index += 1
        }
        return found
    }

    func drawsPublishedList() -> Bool {
        guard let published, let container = surface.layout.handle(forKey: Self.resultsKey) else { return false }
        let leading = published.before > 0 ? 1 : 0
        let count = leading + published.rows.count + (published.after > 0 ? 1 : 0)
        var position = 0
        var matches = true
        surface.layout.core.forEachChild(of: container) { child, key in
            defer { position += 1 }
            guard matches, position < count else {
                matches = false
                return
            }
            let row = position - leading
            if row < 0 {
                matches = key == Self.beforeKey
                    && surface.layout.core.layoutFrame(of: child).height == Float(published.before)
            } else if row < published.rows.count {
                matches = key == ShellWidgetLayout.elementKey(published.rows[row].id)
            } else {
                matches = key == Self.afterKey
                    && surface.layout.core.layoutFrame(of: child).height == Float(published.after)
            }
        }
        return matches && position == count
    }

    private func revealIfRequested() {
        guard revealedRequest != revealRequest, let selected = published?.selected else { return }
        if !selected.isEmpty {
            surface.reveal(key: selected, within: Self.resultsKey)
        }
        revealedRequest = revealRequest
    }

    private func scrolled() {
        guard !closed, recordViewport(), !coversViewport() else { return }
        if applying {
            windowChanged = true
        } else {
            onWindowChange?()
        }
    }

    private func coversViewport() -> Bool {
        guard let published, rowWindow.viewport > 0 else { return false }
        let view = rowWindow.viewport
        var bottom = Float(published.before)
        for row in published.rows {
            bottom += rowWindow.advance(of: row.id)
        }
        let coversTop = published.first == 0 || Float(published.before) <= max(rowWindow.offset - view / 2, 0)
        let coversBottom = published.first + published.rows.count >= published.total
            || bottom >= rowWindow.offset + view * 3 / 2
        return coversTop && coversBottom
    }

    private func recordViewport() -> Bool {
        guard let container = surface.layout.handle(forKey: Self.resultsKey) else { return false }
        let viewport = rowWindow.record(
            viewport: surface.layout.core.layoutFrame(of: container).height,
            offset: surface.layout.core.scrollOffset(of: container),
            gap: surface.layout.core.layoutStyle(of: container).gap
        )
        var id: String?
        var top: Float = 0
        if let rows = drawn?.rows, let row = firstVisibleRow(in: container), row.index < rows.count {
            id = rows[row.index].id
            top = row.top
        }
        let anchor = rowWindow.record(anchor: id, top: top)
        return viewport || anchor
    }

    private func measureRows() -> Bool {
        guard let rows = published?.rows, let container = surface.layout.handle(forKey: Self.resultsKey) else {
            return false
        }
        let gap = surface.layout.core.layoutStyle(of: container).gap
        var changed = false
        var index = 0
        var previous: Rect?
        surface.layout.core.forEachChild(of: container) { child, key in
            guard key != Self.beforeKey, key != Self.afterKey else { return }
            let frame = surface.layout.core.layoutFrame(of: child)
            if let previous {
                changed = rowWindow.record(advance: frame.y - previous.y, for: rows[index - 1].id) || changed
            }
            previous = frame
            index += 1
        }
        if let previous {
            changed = rowWindow.record(advance: previous.height + gap, for: rows[index - 1].id) || changed
        }
        return changed
    }
}
