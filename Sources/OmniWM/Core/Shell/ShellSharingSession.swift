// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellSharingSession: NSObject, @MainActor NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let values: [ShellResourceStore.Value]
    private let serviceName: String?
    private let source: ShellDesktopSource
    private let anchor: ShellDesktopAnchor
    private var completion: ShellDesktopPlatform.PresentationCompletion?
    private var picker: NSSharingServicePicker?
    private var menu: NSMenu?
    private var serviceSelected = false
    private var service: NSSharingService?
    private var endFocus: ShellDesktopSource.FocusEnd?

    init(
        values: [ShellResourceStore.Value],
        service: String?,
        source: ShellDesktopSource,
        anchor: ShellDesktopAnchor,
        completion: @escaping ShellDesktopPlatform.PresentationCompletion
    ) {
        self.values = values
        serviceName = service
        self.source = source
        self.anchor = anchor
        self.completion = completion
        super.init()
    }

    func present() throws {
        guard let (view, rect) = anchor.resolve(in: source) else { throw ShellResourceFailure("anchor_unavailable") }
        let items: [Any] = values.map { value in
            switch value {
            case let .file(url),
                 let .url(url): url as NSURL
            case let .text(text): text as NSString
            }
        }
        if let serviceName {
            guard serviceName == "airdrop", let service = NSSharingService(named: .sendViaAirDrop),
                  service.canPerform(withItems: items) else { throw ShellResourceFailure("service_unavailable") }
            endFocus = try source.beginFocus(nil)
            self.service = service
            serviceSelected = true
            service.delegate = self
            service.perform(withItems: items)
        } else {
            let picker = NSSharingServicePicker(items: items)
            endFocus = try source.beginFocus(nil)
            self.picker = picker
            picker.delegate = self
            let menu = NSMenu()
            menu.addItem(picker.standardShareMenuItem)
            self.menu = menu
            let selected = menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY), in: view)
            self.menu = nil
            if !selected, !serviceSelected { finish("cancelled") }
        }
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        guard picker === sharingServicePicker, completion != nil else { return nil }
        service = sharingService
        return self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose sharingService: NSSharingService?
    ) {
        guard picker === sharingServicePicker, completion != nil else { return }
        guard let sharingService else {
            if !serviceSelected { finish("cancelled") }
            return
        }
        serviceSelected = true
        service = sharingService
        let endFocus = endFocus
        self.endFocus = nil
        endFocus?(false)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard service === sharingService else { return }
        finish(nil)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        guard service === sharingService else { return }
        finish(String(error.localizedDescription.prefix(1024)))
    }

    func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        source.isCurrent() ? source.window : nil
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        guard let (view, rect) = anchor.resolve(in: source), let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    func cancel() {
        guard !serviceSelected else { return }
        if let menu { menu.cancelTracking() }
        else { picker?.close() }
    }

    private func finish(_ error: String?) {
        guard let completion else { return }
        self.completion = nil
        menu?.cancelTracking()
        menu = nil
        picker?.delegate = nil
        picker = nil
        service?.delegate = nil
        service = nil
        let endFocus = endFocus
        self.endFocus = nil
        endFocus?(true)
        completion(error)
    }
}
