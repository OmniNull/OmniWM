// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

enum AXAttributeValue {
    static func value(at index: Int, in values: CFArray) -> CFTypeRef? {
        guard index >= 0,
              index < CFArrayGetCount(values),
              let pointer = CFArrayGetValueAtIndex(values, index)
        else {
            return nil
        }
        return unsafeBitCast(pointer, to: CFTypeRef.self)
    }

    static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: NSString.self) as String
    }

    static func isElement(_ value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

    static func rectValue(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    static func frame(positionValue: Any?, sizeValue: Any?) -> CGRect? {
        guard let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAXValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: CGRect(origin: position, size: size))
    }
}
