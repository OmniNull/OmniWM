// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var rect = CGRect.zero
        let result = MainThreadAXSpanTrace.measure(.windowServerBounds, windowId: Int(wid)) {
            transactions.getWindowBounds(cid, wid, &rect)
        } succeeded: { $0 == .success } status: { $0.rawValue }
        guard result == .success else { return nil }
        return rect
    }

    func transactionMove(_ wid: UInt32, origin: CGPoint) {
        withTransaction { transaction in
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
