// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    func orderWindow(_ wid: UInt32, relativeTo targetWid: UInt32, order: SkyLightWindowOrder = .above) {
        let cid = getMainConnectionID()
        guard let transaction = transactions.transactionCreate(cid)?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return
        }
        transactions.transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        commit(transaction)
    }

    func isWindowOrderedIn(_ wid: UInt32) -> Bool? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var orderedIn: UInt8 = 0
        let result = transactions.windowIsOrderedIn(cid, wid, &orderedIn)
        guard result == .success else { return nil }
        return orderedIn != 0
    }

    func moveWindow(_ wid: UInt32, to point: CGPoint) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var pt = point
        let result = transactions.moveWindow(cid, wid, &pt)
        return result == .success
    }

    func currentWindowBounds(_ wid: UInt32) -> CGRect? {
        var bounds = CGRect.zero
        return transactions.getWindowBounds(getMainConnectionID(), wid, &bounds) == .success ? bounds : nil
    }

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        MainThreadAXSpanTrace.measure(.windowServerBounds, windowId: Int(wid)) {
            queryWindowBounds(wid)
        } succeeded: { $0 != nil }
    }

    func getWindowBounds(_ windowIds: [UInt32]) -> [UInt32: CGRect] {
        MainThreadAXSpanTrace.measure(.windowServerBatchQuery, count: windowIds.count) {
            queryWindowBounds(windowIds)
        }
    }

    func moveJoiningOpenTransaction(_ wid: UInt32, origin: CGPoint) -> Bool {
        scopedTransaction == nil ? moveWindow(wid, to: origin) : transactionMove(wid, origin: origin)
    }

    @discardableResult
    func transactionMove(_ wid: UInt32, origin: CGPoint) -> Bool {
        withTransaction { transaction in
            transactions.transactionMoveWindowWithGroup(transaction, wid, origin)
        }
    }

    func transactionReshape(_ wid: UInt32, origin: CGPoint, size: CGSize) -> Bool {
        guard let setShape = surfaces.transactionSetWindowShape else { return false }
        var region: CFTypeRef?
        var rect = CGRect(origin: .zero, size: size)
        _ = surfaces.newRegionWithRect(&rect, &region)
        guard let region else { return false }
        return withTransaction { transaction in
            setShape(transaction, wid, 0, 0, region)
            transactions.transactionMoveWindowWithGroup(transaction, wid, origin)
        }
    }

    func transactionMoveAndOrder(
        _ wid: UInt32,
        origin: CGPoint,
        level: Int32,
        relativeTo targetWid: UInt32,
        order: SkyLightWindowOrder
    ) {
        withTransaction { transaction in
            transactions.transactionMoveWindowWithGroup(transaction, wid, origin)
            surfaces.transactionSetWindowLevel(transaction, wid, level)
            transactions.transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        }
    }

    func transactionHide(_ wid: UInt32) {
        withTransaction { transaction in
            transactions.transactionOrderWindow(transaction, wid, SkyLightWindowOrder.out.rawValue, 0)
        }
    }
}
