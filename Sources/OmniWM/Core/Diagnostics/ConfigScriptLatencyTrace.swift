// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#if OMNIWM_CONFIG_CALLBACK_TRACE
    import Dispatch
    import Synchronization

    enum ConfigScriptLatencyTrace {
        enum Stage: String, CaseIterable {
            case chord
            case eventPublished
            case enqueued
            case callback
            case nativeCommand
            case visible
        }

        private static let stamps = Mutex<[Stage: UInt64]>([:])
        private static let eventPayloads = Atomic<Int>(0)
        private static let windowStateIDs = Atomic<Int>(0)
        private static let enqueues = Atomic<Int>(0)

        static var enqueueCount: Int {
            enqueues.load(ordering: .relaxed)
        }

        static var builtEventPayloads: Int {
            eventPayloads.load(ordering: .relaxed)
        }

        static func eventPayloadBuilt() {
            _ = eventPayloads.wrappingAdd(1, ordering: .relaxed)
        }

        static var encodedWindowStateIDs: Int {
            windowStateIDs.load(ordering: .relaxed)
        }

        static func windowStateIDEncoded() {
            _ = windowStateIDs.wrappingAdd(1, ordering: .relaxed)
        }

        static func reset() {
            eventPayloads.store(0, ordering: .relaxed)
            windowStateIDs.store(0, ordering: .relaxed)
            enqueues.store(0, ordering: .relaxed)
            stamps.withLock { $0.removeAll(keepingCapacity: true) }
        }

        static func mark(_ stage: Stage) {
            let now = DispatchTime.now().uptimeNanoseconds
            if stage == .enqueued { _ = enqueues.wrappingAdd(1, ordering: .relaxed) }
            stamps.withLock {
                if $0[stage] == nil { $0[stage] = now }
            }
        }

        static func read() -> [Stage: UInt64] {
            stamps.withLock { $0 }
        }
    }
#endif
