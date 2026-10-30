// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMIPC

struct ShellIslandData: Equatable, Sendable {
    let display: String
    let usableRect: CGRect
    let size: CGSize
    let notch: CGRect?
    let menuBar: CGFloat
    let scale: CGFloat
    let main: Bool
    let visible: Bool
    let fullscreen: Bool
    var focused: Bool
    var drag: ShellIslandDragState
    let navigation: IslandNavigationSnapshot?
    let drawer: String?
    private let sessionToken: String

    init(
        monitor: Monitor,
        geometry: ShellIslandGeometry,
        visible: Bool,
        fullscreen: Bool,
        reservedInsets: Struts = .zero,
        focused: Bool = false,
        drag: ShellIslandDragState = .init(),
        navigation: IslandNavigationSnapshot? = nil,
        sessionToken: String = "",
        drawer: String? = nil
    ) {
        display = monitor.name
        let working = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: monitor.backingScale,
            struts: reservedInsets
        )
        let intersection = working.intersection(geometry.frame)
        let safe = intersection
            .isNull ? CGRect(x: geometry.frame.minX, y: geometry.frame.minY, width: 0, height: 0) : intersection
        let top = max(geometry.frame.maxY - safe.maxY, geometry.notch?.height ?? 0)
        usableRect = CGRect(
            x: max(0, safe.minX - geometry.frame.minX),
            y: top,
            width: max(0, safe.width),
            height: max(
                0,
                geometry.frame.height - top - max(0, safe.minY - geometry.frame.minY)
            )
        )
        size = geometry.frame.size
        notch = geometry.notch
        menuBar = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        scale = monitor.backingScale
        main = monitor.isMain
        self.visible = visible
        self.fullscreen = fullscreen
        self.focused = focused
        self.drag = drag
        self.navigation = navigation
        self.drawer = drawer
        self.sessionToken = sessionToken
    }

    func write(to writer: inout ShellValueWriter) {
        writer.map(13)
        writer.key("display")
        writer.string(display)
        writer.key("usableRect")
        writer.map(4)
        writer.key("x")
        writer.number(usableRect.minX)
        writer.key("y")
        writer.number(usableRect.minY)
        writer.key("w")
        writer.number(usableRect.width)
        writer.key("h")
        writer.number(usableRect.height)
        writer.key("size")
        writer.map(2)
        writer.key("w")
        writer.number(size.width)
        writer.key("h")
        writer.number(size.height)
        writer.key("notch")
        if let notch {
            writer.map(3)
            writer.key("x")
            writer.number(notch.minX)
            writer.key("w")
            writer.number(notch.width)
            writer.key("h")
            writer.number(notch.height)
        } else {
            writer.null()
        }
        writer.key("menuBar")
        writer.number(menuBar)
        writer.key("scale")
        writer.number(scale)
        writer.key("main")
        writer.bool(main)
        writer.key("visible")
        writer.bool(visible)
        writer.key("fullscreen")
        writer.bool(fullscreen)
        writer.key("focused")
        writer.bool(focused)
        writer.key("drag")
        drag.write(to: &writer)
        writer.key("navigation")
        writeNavigation(to: &writer)
        writer.key("drawer")
        writeDrawer(to: &writer)
    }

    private func writeDrawer(to writer: inout ShellValueWriter) {
        guard let drawer else {
            writer.null()
            return
        }
        writer.string(drawer)
    }

    private func writeNavigation(to writer: inout ShellValueWriter) {
        guard let navigation else {
            writer.null()
            return
        }
        writer.map(5)
        writer.key("workspace")
        writer.string(navigation.workspace)
        writer.key("name")
        writer.string(navigation.name)
        writer.key("layout")
        writer.string(navigation.layout)
        writer.key("focused")
        if let focused = navigation.focused {
            writer.string(windowID(focused))
        } else {
            writer.null()
        }
        writer.key("windows")
        writer.array(navigation.windows.count)
        for window in navigation.windows {
            writer.map(5)
            writer.key("id")
            writer.string(windowID(window.token))
            writer.key("bundle")
            writer.string(window.bundle)
            writer.key("name")
            writer.string(window.name)
            writer.key("title")
            writer.string(window.title)
            writer.key("column")
            writer.number(Double(window.column))
        }
    }

    private func windowID(_ token: WindowToken) -> String {
        IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }
}
