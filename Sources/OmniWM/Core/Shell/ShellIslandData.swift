// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMIPC

struct ShellIslandData: Equatable, Sendable {
    let display: String
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
    private let sessionToken: String

    init(
        monitor: Monitor,
        geometry: ShellIslandGeometry,
        visible: Bool,
        fullscreen: Bool,
        focused: Bool = false,
        drag: ShellIslandDragState = .init(),
        navigation: IslandNavigationSnapshot? = nil,
        sessionToken: String = ""
    ) {
        display = monitor.name
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
        self.sessionToken = sessionToken
    }

    func write(to writer: inout ShellValueWriter) {
        writer.map(11)
        writer.key("display")
        writer.string(display)
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
