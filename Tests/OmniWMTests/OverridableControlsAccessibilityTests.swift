// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class OverridableControlsAccessibilityTests: XCTestCase {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        if !application.isRunning { application.finishLaunching() }
        return application
    }()

    private enum Control: String, CaseIterable {
        case slider, toggle, picker
    }

    private enum Choice: String, CaseIterable, Identifiable {
        case first, second
        var id: String {
            rawValue
        }
    }

    private struct ResettableRow: View {
        let control: Control
        @State private var sliderValue: Double? = 3
        @State private var toggleValue: Bool? = false
        @State private var pickerValue: Choice? = .second

        var body: some View {
            Form {
                switch control {
                case .slider:
                    OverridableSlider(
                        label: "Gaps", value: sliderValue, globalValue: 2, range: 1 ... 5, step: 1,
                        formatter: { "\(Int($0))" }, onChange: { sliderValue = $0 }, onReset: { sliderValue = nil }
                    )
                case .toggle:
                    OverridableToggle(
                        label: "Gaps", value: toggleValue, globalValue: true,
                        onChange: { toggleValue = $0 }, onReset: { toggleValue = nil }
                    )
                case .picker:
                    OverridablePicker(
                        label: "Gaps", value: pickerValue, globalValue: .first, options: Choice.allCases,
                        displayName: \.rawValue, onChange: { pickerValue = $0 }, onReset: { pickerValue = nil }
                    )
                }
            }
            .formStyle(.grouped)
        }
    }

    private struct Element {
        let role: String?
        let value: String?
        let description: String?
        let reference: AXUIElement
    }

    func testResettingAnOverrideLeavesAReadableGlobalLabel() throws {
        _ = Self.application
        for control in Control.allCases {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 160),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.title = "OverridableControlsAccessibilityTests.\(control.rawValue)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ResettableRow(control: control))
            defer { window.contentView = nil
                window.close()
            }
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
            window.display()

            let reset = try XCTUnwrap(
                elements(in: window).first { $0.description == "Reset Gaps to global default" },
                control.rawValue
            )
            XCTAssertEqual(AXUIElementPerformAction(reset.reference, kAXPressAction as CFString), .success)

            let after = elements(in: window)
            XCTAssertFalse(after.contains { $0.description == "Reset Gaps to global default" }, control.rawValue)
            let global = try XCTUnwrap(after.first { $0.value == "Gaps uses global default" }, control.rawValue)
            XCTAssertEqual(global.role, kAXStaticTextRole, control.rawValue)
            XCTAssertFalse(after.contains { $0.value == "Global" }, control.rawValue)
        }
    }

    private func elements(in window: NSWindow) -> [Element] {
        let application = AXUIElementCreateApplication(getpid())
        var pending = (attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []).filter {
            attribute(kAXTitleAttribute, of: $0) as? String == window.title
        }
        var found: [Element] = []
        while let element = pending.popLast() {
            _ = attribute(kAXTitleAttribute, of: element)
            found.append(Element(
                role: attribute(kAXRoleAttribute, of: element) as? String,
                value: attribute(kAXValueAttribute, of: element) as? String,
                description: attribute(kAXDescriptionAttribute, of: element) as? String,
                reference: element
            ))
            pending.append(contentsOf: attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [])
        }
        return found
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
