// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

enum MenuExtractionError: Error, Equatable {
    case ax(AXError)
    case invalidResponse
    case deadlineExceeded
}

struct MenuAXDeadline {
    let expiresAt: TimeInterval

    init(start: TimeInterval, timeout: TimeInterval) {
        expiresAt = start + timeout
    }

    func remaining(at time: TimeInterval) throws -> Float {
        let remaining = expiresAt - time
        guard remaining > 0 else { throw MenuExtractionError.deadlineExceeded }
        return Float(remaining)
    }
}

@MainActor
struct MenuExtractorEnvironment {
    var now: @MainActor () -> TimeInterval
    var readAttribute: @MainActor (AXUIElement, CFString, Float) throws -> Any?
    var readAttributes: @MainActor (AXUIElement, CFArray, Float) throws -> [Any]

    static var live: MenuExtractorEnvironment {
        MenuExtractorEnvironment(
            now: { ProcessInfo.processInfo.systemUptime },
            readAttribute: readMenuAttribute,
            readAttributes: readMenuAttributes
        )
    }
}

struct MenuItemSnapshot {
    let element: AXUIElement
    let attributes: [String: Any]
    let submenuRoot: AXUIElement?
}

@MainActor
struct MenuAXReader {
    static let itemAttributeKeys = [
        "AXTitle", "AXRole", "AXRoleDescription", "AXEnabled",
        "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren"
    ]

    private let environment: MenuExtractorEnvironment
    private let submenuTimeout: TimeInterval

    init(environment: MenuExtractorEnvironment, submenuTimeout: TimeInterval) {
        self.environment = environment
        self.submenuTimeout = submenuTimeout
    }

    func readSubmenuSnapshots(from element: AXUIElement) throws -> [MenuItemSnapshot] {
        let deadline = MenuAXDeadline(start: environment.now(), timeout: submenuTimeout)
        return try readSnapshots(from: element, content: nil, deadline: deadline)
    }

    func readMenuBarSnapshots(from element: AXUIElement, content: MenuContent) throws -> [MenuItemSnapshot] {
        let deadline = MenuAXDeadline(start: environment.now(), timeout: submenuTimeout)
        return try readSnapshots(from: element, content: content, deadline: deadline)
    }

    private func readSnapshots(
        from element: AXUIElement,
        content: MenuContent?,
        deadline: MenuAXDeadline
    ) throws -> [MenuItemSnapshot] {
        let childrenValue = try environment.readAttribute(
            element,
            kAXChildrenAttribute as CFString,
            deadline.remaining(at: environment.now())
        )
        guard let childrenValue,
              let children = childrenValue as? [AXUIElement]
        else {
            throw MenuExtractionError.invalidResponse
        }

        let attributes = Self.itemAttributeKeys as CFArray
        var snapshots: [MenuItemSnapshot] = []
        snapshots.reserveCapacity(children.count)

        for child in children {
            let values = try environment.readAttributes(
                child,
                attributes,
                deadline.remaining(at: environment.now())
            )
            var decoded = try Self.decodeAttributeValues(
                names: Self.itemAttributeKeys,
                values: values
            )
            let role = try Self.validateMenuItemAttributes(&decoded)
            let isApple = Self.isAppleMenuItem(decoded)
            if content == .application, isApple { continue }
            if content == .apple, !isApple { continue }
            let submenuRoot = try readSubmenuRoot(
                from: decoded,
                role: role,
                deadline: deadline
            )
            if content == .apple {
                guard let submenuRoot else { throw MenuExtractionError.invalidResponse }
                return try readSnapshots(from: submenuRoot, content: nil, deadline: deadline)
            }
            snapshots.append(
                MenuItemSnapshot(
                    element: child,
                    attributes: decoded,
                    submenuRoot: submenuRoot
                )
            )
        }

        if content == .apple { throw MenuExtractionError.invalidResponse }
        return snapshots
    }

    static func isAppleMenuItem(_ attributes: [String: Any]) -> Bool {
        (attributes[kAXTitleAttribute as String] as? String) == "Apple"
            || (attributes[kAXRoleDescriptionAttribute as String] as? String) == "Apple menu"
    }

    private func readSubmenuRoot(
        from attributes: [String: Any],
        role: String,
        deadline: MenuAXDeadline
    ) throws -> AXUIElement? {
        guard role != "AXSeparator",
              let childrenValue = attributes[kAXChildrenAttribute as String]
        else {
            return nil
        }
        guard let children = childrenValue as? [AXUIElement] else {
            throw MenuExtractionError.invalidResponse
        }
        guard let submenuRoot = children.first else { return nil }

        let roleValue = try environment.readAttribute(
            submenuRoot,
            kAXRoleAttribute as CFString,
            deadline.remaining(at: environment.now())
        )
        guard let submenuRole = roleValue as? String,
              submenuRole == (kAXMenuRole as String)
        else {
            throw MenuExtractionError.invalidResponse
        }
        return submenuRoot
    }

    static func decodeAttributeValues(
        names: [String],
        values: [Any]
    ) throws -> [String: Any] {
        guard names.count == values.count else {
            throw MenuExtractionError.invalidResponse
        }

        var decoded: [String: Any] = [:]
        decoded.reserveCapacity(names.count)
        for (name, value) in zip(names, values) {
            if let value = try decodedAttributeValue(value) {
                decoded[name] = value
            }
        }
        return decoded
    }

    private static func decodedAttributeValue(_ value: Any) throws -> Any? {
        let cfValue = value as CFTypeRef
        let typeId = CFGetTypeID(cfValue)
        if typeId == CFNullGetTypeID() {
            return nil
        }
        guard typeId == AXValueGetTypeID() else {
            return value
        }

        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return value
        }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else {
            throw MenuExtractionError.invalidResponse
        }
        switch error {
        case .attributeUnsupported,
             .noValue:
            return nil
        default:
            throw MenuExtractionError.ax(error)
        }
    }

    private static func validateMenuItemAttributes(_ attributes: inout [String: Any]) throws -> String {
        guard let role = attributes[kAXRoleAttribute as String] as? String else {
            throw MenuExtractionError.invalidResponse
        }
        if role != "AXSeparator" {
            guard attributes[kAXTitleAttribute as String] is String else {
                throw MenuExtractionError.invalidResponse
            }
        }
        try validateOptionalType(String.self, key: kAXRoleDescriptionAttribute as String, in: attributes)
        try validateOptionalType(Bool.self, key: kAXEnabledAttribute as String, in: attributes)
        try validateOptionalType(String.self, key: kAXMenuItemMarkCharAttribute as String, in: attributes)
        try validateOptionalType(String.self, key: kAXMenuItemCmdCharAttribute as String, in: attributes)
        try validateOptionalType(Int.self, key: kAXMenuItemCmdModifiersAttribute as String, in: attributes)
        try validateOptionalType([AXUIElement].self, key: kAXChildrenAttribute as String, in: attributes)
        if attributes[kAXEnabledAttribute as String] == nil {
            attributes[kAXEnabledAttribute as String] = false
        }
        return role
    }

    private static func validateOptionalType<T>(
        _: T.Type,
        key: String,
        in attributes: [String: Any]
    ) throws {
        guard let value = attributes[key] else { return }
        guard value is T else { throw MenuExtractionError.invalidResponse }
    }
}

@MainActor
private func readMenuAttribute(
    _ element: AXUIElement,
    _ attribute: CFString,
    _ timeout: Float
) throws -> Any? {
    try MenuAXReader.withMessagingTimeout(on: element, timeout: timeout) {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { throw MenuExtractionError.ax(result) }
        return value
    }
}

@MainActor
private func readMenuAttributes(
    _ element: AXUIElement,
    _ attributes: CFArray,
    _ timeout: Float
) throws -> [Any] {
    try MenuAXReader.withMessagingTimeout(on: element, timeout: timeout) {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        guard result == .success else { throw MenuExtractionError.ax(result) }
        guard let values = values as? [Any] else {
            throw MenuExtractionError.invalidResponse
        }
        return values
    }
}

@MainActor
extension MenuAXReader {
    static func withMessagingTimeout<T>(
        on element: AXUIElement,
        timeout: Float,
        setter: (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) },
        operation: () throws -> T
    ) throws -> T {
        let result = setter(element, timeout)
        guard result == .success else { throw MenuExtractionError.ax(result) }
        defer { _ = setter(element, 0) }
        return try operation()
    }
}

@MainActor
extension AXUIElement {
    func getAttribute(_ name: String) -> Any? {
        autoreleasepool {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success
                ? value : nil
        }
    }

    func getChildren() -> [AXUIElement]? {
        autoreleasepool {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(self, "AXChildren" as CFString, &value) == .success,
                  let children = value as? [AXUIElement], !children.isEmpty
            else {
                return nil
            }
            return children
        }
    }

    func getMultipleAttributes(_ names: [String]) -> [String: Any]? {
        autoreleasepool {
            let attrs = names as CFArray
            var values: CFArray?
            let options = AXCopyMultipleAttributeOptions(rawValue: 0)

            guard AXUIElementCopyMultipleAttributeValues(self, attrs, options, &values) == .success,
                  let results = values as? [Any], results.count == names.count
            else { return nil }

            var dict: [String: Any] = [:]
            dict.reserveCapacity(names.count)

            for i in 0 ..< names.count {
                let value = results[i]
                if !(value is NSNull) {
                    dict[names[i]] = value
                }
            }
            return dict.isEmpty ? nil : dict
        }
    }
}
