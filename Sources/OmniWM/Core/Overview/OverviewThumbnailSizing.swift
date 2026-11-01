// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct OverviewPreviewRequest: Equatable {
    let handle: WindowHandle
    let token: WindowToken
    let pixelWidth: Int
    let pixelHeight: Int

    init(handle: WindowHandle, pixelWidth: Int, pixelHeight: Int) {
        self.handle = handle
        token = handle.token
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }
}

struct OverviewPreviewProjection {
    let layout: OverviewLayout
    let viewportFrame: CGRect
    let backingScaleFactor: CGFloat
}

enum OverviewThumbnailSizing {
    static func captureRequests(projections: [OverviewPreviewProjection]) -> [OverviewPreviewRequest] {
        var requests: [OverviewPreviewRequest] = []
        var positions: [WindowHandle: Int] = [:]

        for projection in projections {
            let visibleContent = OverviewRenderGeometry.visibleContentRect(
                bounds: projection.viewportFrame,
                scrollOffset: projection.layout.scrollOffset
            )
            let scale = max(projection.backingScaleFactor, 1)
            for section in projection.layout.workspaceSections {
                for window in section.windows {
                    guard window.isDisplayed,
                          window.overviewFrame.size.hasFinitePositiveDimensions(),
                          section.clipFrame(for: window).isEmpty || section.clipFrame(for: window)
                              .intersects(window.overviewFrame),
                          OverviewRenderGeometry.shouldRender(
                              frame: window.overviewFrame,
                              visibleContentRect: visibleContent
                          )
                    else { continue }
                    let width = max(1, Int(ceil(window.overviewFrame.width * scale)))
                    let height = max(1, Int(ceil(window.overviewFrame.height * scale)))
                    if let position = positions[window.handle] {
                        let previous = requests[position]
                        requests[position] = OverviewPreviewRequest(
                            handle: window.handle,
                            pixelWidth: max(previous.pixelWidth, width),
                            pixelHeight: max(previous.pixelHeight, height)
                        )
                    } else {
                        positions[window.handle] = requests.count
                        requests.append(OverviewPreviewRequest(
                            handle: window.handle,
                            pixelWidth: width,
                            pixelHeight: height
                        ))
                    }
                }
            }
        }
        return requests
    }

    static func collectRequests(
        represented: Set<WindowHandle>,
        visible: [OverviewPreviewRequest],
        selectedHandle: WindowHandle?,
        sourceOrder: inout [ObjectIdentifier]
    ) -> [ObjectIdentifier: OverviewPreviewRequest] {
        var requests: [ObjectIdentifier: OverviewPreviewRequest] = [:]
        sourceOrder.removeAll(keepingCapacity: true)
        for index in visible.indices {
            let request = visible[index]
            guard represented.contains(request.handle), request.token == request.handle.token else { continue }
            let key = ObjectIdentifier(request.handle)
            if let previous = requests[key] {
                requests[key] = OverviewPreviewRequest(
                    handle: request.handle,
                    pixelWidth: max(previous.pixelWidth, request.pixelWidth),
                    pixelHeight: max(previous.pixelHeight, request.pixelHeight)
                )
            } else {
                requests[key] = request
                sourceOrder.append(key)
            }
        }
        if let selectedHandle,
           let index = sourceOrder.firstIndex(of: ObjectIdentifier(selectedHandle)), index != 0
        {
            sourceOrder.insert(sourceOrder.remove(at: index), at: 0)
        }
        return requests
    }
}
