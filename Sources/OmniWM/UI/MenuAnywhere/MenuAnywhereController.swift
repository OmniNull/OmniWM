// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
@preconcurrency import ApplicationServices

enum MenuSubmenuLoadResult {
    case loaded([NSMenuItem])
    case unavailable
}

@MainActor
final class MenuAnywhereController: NSObject, NSMenuDelegate {
    typealias SubmenuLoader = @MainActor (AXUIElement, AnyObject?, Selector?) -> MenuSubmenuLoadResult
    typealias MenuLoader = @MainActor (pid_t, MenuContent, AnyObject?, Selector?) -> MenuSubmenuLoadResult
    typealias MenuPresenter = @MainActor (NSMenu, CGPoint) -> Void
    typealias NativeSubmenuOpener = @MainActor (NSRunningApplication, AXUIElement) -> Void

    static let shared = MenuAnywhereController()

    private let menuLoader: MenuLoader
    private let submenuLoader: SubmenuLoader
    private let menuPresenter: MenuPresenter
    private let makeMenu: @MainActor () -> NSMenu
    private let usesNativeSubmenus: @MainActor (NSRunningApplication) -> Bool
    private let openNativeSubmenu: NativeSubmenuOpener
    private var currentApp: NSRunningApplication?
    private var activeMenu: NSMenu?
    private var selectedNativeSubmenu: AXUIElement?
    private var nativeSubmenuTask: Task<Void, Never>?
    var onMenuTrackingChanged: ((Bool) -> Void)?

    private static let kAXPressAction = "AXPress" as CFString
    private static let appActivationDelay: TimeInterval = 0.1

    override private convenience init() {
        let extractor = MenuExtractor()
        self.init(
            menuLoader: Self.makeMenuLoader(using: extractor),
            submenuLoader: { root, target, action in
                do {
                    return .loaded(
                        try extractor.buildSubmenu(from: root, target: target, action: action)
                    )
                } catch {
                    return .unavailable
                }
            }
        )
    }

    convenience init(submenuLoader: @escaping SubmenuLoader) {
        self.init(menuLoader: Self.makeMenuLoader(using: MenuExtractor()), submenuLoader: submenuLoader)
    }

    init(
        menuLoader: @escaping MenuLoader,
        menuPresenter: @escaping MenuPresenter = { menu, location in
            menu.popUp(positioning: nil, at: location, in: nil)
        },
        makeMenu: @escaping @MainActor () -> NSMenu = { NSMenu() },
        usesNativeSubmenus: @escaping @MainActor (NSRunningApplication) -> Bool = MenuAnywhereController
            .bundlesJetBrainsScreenMenu,
        openNativeSubmenu: @escaping NativeSubmenuOpener = MenuAnywhereController.pressNativeSubmenu,
        submenuLoader: @escaping SubmenuLoader
    ) {
        self.menuLoader = menuLoader
        self.menuPresenter = menuPresenter
        self.makeMenu = makeMenu
        self.usesNativeSubmenus = usesNativeSubmenus
        self.openNativeSubmenu = openNativeSubmenu
        self.submenuLoader = submenuLoader
        super.init()
    }

    private static func bundlesJetBrainsScreenMenu(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier?.hasPrefix("com.jetbrains.") == true, let bundle = app.bundleURL else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/bin/libmacscreenmenu64.dylib").path
        )
    }

    private static func makeMenuLoader(using extractor: MenuExtractor) -> MenuLoader {
        { pid, content, target, action in
            guard let menuBar = extractor.getMenuBar(for: pid) else { return .unavailable }
            do {
                return .loaded(
                    try extractor.buildMenu(from: menuBar, content: content, target: target, action: action)
                )
            } catch {
                return .unavailable
            }
        }
    }

    func showNativeMenu() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        showNativeMenu(for: app, content: .all) { _ in NSEvent.mouseLocation }
    }

    func showNativeMenu(
        for app: NSRunningApplication,
        content: MenuContent,
        anchor: CGRect,
        edge: PopupAttachment.Edge,
        visibleFrame: CGRect
    ) {
        showNativeMenu(for: app, content: content) { menu in
            let frame = PopupAttachment(sourceFrame: anchor, edge: edge)
                .frame(size: menu.size, visibleFrame: visibleFrame)
            return CGPoint(x: frame.minX, y: frame.maxY)
        }
    }

    func cancelTracking() {
        selectedNativeSubmenu = nil
        cancelNativeSubmenu()
        activeMenu?.cancelTracking()
    }

    private func showNativeMenu(
        for app: NSRunningApplication,
        content: MenuContent,
        location: (NSMenu) -> CGPoint
    ) {
        guard activeMenu == nil else { return }
        cancelNativeSubmenu()
        let result = menuLoader(
            app.processIdentifier, content, self, #selector(menuAction(_:))
        )
        if content == .all, case .unavailable = result { return }

        let menu = makeMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu, with: result, showsStatus: content != .all)
        if content == .application, usesNativeSubmenus(app) {
            routeNativeSubmenus(in: menu)
        }
        currentApp = app
        activeMenu = menu

        onMenuTrackingChanged?(true)
        menuPresenter(menu, location(menu))
        let selection = selectedNativeSubmenu
        selectedNativeSubmenu = nil
        cleanupActiveMenu()
        if let selection { scheduleNativeSubmenu(selection, for: app) }
    }

    private func routeNativeSubmenus(in menu: NSMenu) {
        for item in menu.items where item.submenu != nil {
            item.submenu = nil
            if item.isEnabled {
                item.target = self
                item.action = #selector(selectNativeSubmenu(_:))
            }
        }
    }

    @objc private func selectNativeSubmenu(_ sender: NSMenuItem) {
        guard let activeMenu, sender.menu === activeMenu, sender.isEnabled else { return }
        selectedNativeSubmenu = sender.representedObject.flatMap { AXUIElement.from($0 as CFTypeRef) }
    }

    private func scheduleNativeSubmenu(_ element: AXUIElement, for app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        if !app.isActive { app.activate(options: []) }
        nativeSubmenuTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.appActivationDelay))
            guard let self, !Task.isCancelled else { return }
            nativeSubmenuTask = nil
            openNativeSubmenu(app, element)
        }
    }

    private func cancelNativeSubmenu() {
        nativeSubmenuTask?.cancel()
        nativeSubmenuTask = nil
    }

    private static func pressNativeSubmenu(_ app: NSRunningApplication, _ element: AXUIElement) {
        guard app.isActive, !app.isTerminated else { return }
        performAXAction(element, kAXPressAction, noteKey: "nativeSubmenuPressFailed")
    }

    private func cleanupActiveMenu() {
        guard let menu = activeMenu else { return }

        cleanupMenuItems(menu.items)
        menu.removeAllItems()
        activeMenu = nil
        currentApp = nil
        onMenuTrackingChanged?(false)
    }

    private func cleanupMenuItems(_ items: [NSMenuItem]) {
        for item in items {
            if let submenu = item.submenu {
                cleanupMenuItems(submenu.items)
                submenu.removeAllItems()
            }
            item.representedObject = nil
            item.target = nil
            item.action = nil
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let representedObject = sender.representedObject,
              let element = AXUIElement.from(representedObject as CFTypeRef),
              let app = currentApp, !app.isTerminated
        else { return }

        if !app.isActive {
            app.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appActivationDelay) {
                performAXAction(element, Self.kAXPressAction, noteKey: "performPressFailed")
            }
        } else {
            performAXAction(element, Self.kAXPressAction, noteKey: "performPressFailed")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === activeMenu { return }
        menu.autoenablesItems = false
        guard menu.items.isEmpty, let axRoot = menu.axRootElement else { return }

        populate(menu, with: submenuLoader(axRoot, self, #selector(menuAction(_:))))
    }

    private func populate(_ menu: NSMenu, with result: MenuSubmenuLoadResult, showsStatus: Bool = true) {
        switch result {
        case let .loaded(items) where !items.isEmpty:
            items.forEach(menu.addItem)
        case .loaded:
            if showsStatus { menu.addItem(statusItem(title: "(No items)")) }
        case .unavailable:
            menu.addItem(statusItem(title: "(Unavailable)"))
        }
    }

    private func statusItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
