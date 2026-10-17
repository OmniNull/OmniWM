// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCAXWriteMetricsBucket) throws {
        begin(123)
        var first = true
        if let fieldValue = value.app {
            self.key("app", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.bundleId {
            self.key("bundleId", &first)
            try self.value(fieldValue)
        }
        self.key("context", &first)
        try self.value(value.context)
        self.key("count", &first)
        try self.value(value.count)
        self.key("failureCount", &first)
        try self.value(value.failureCount)
        self.key("lane", &first)
        try self.value(value.lane)
        self.key("maxMicroseconds", &first)
        try self.value(value.maxMicroseconds)
        self.key("meanMicroseconds", &first)
        try self.value(value.meanMicroseconds)
        self.key("pid", &first)
        try self.value(value.pid)
        self.key("totalMicroseconds", &first)
        try self.value(value.totalMicroseconds)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCAXWriteMetricsBucket]) throws {
        begin(91)
        var first = true
        let span = value.span
        var index = 0
        while index < span.count {
            item(&first)
            try self.value(span[index])
            index += 1
        }
        end(93)
    }

    mutating func value(_ value: borrowing IPCAXWriteMetrics) throws {
        begin(123)
        var first = true
        self.key("byApp", &first)
        try self.value(value.byApp)
        self.key("count", &first)
        try self.value(value.count)
        self.key("failureCount", &first)
        try self.value(value.failureCount)
        self.key("maxMicroseconds", &first)
        try self.value(value.maxMicroseconds)
        self.key("meanMicroseconds", &first)
        try self.value(value.meanMicroseconds)
        self.key("totalMicroseconds", &first)
        try self.value(value.totalMicroseconds)
        end(125)
    }

    mutating func value(_ value: borrowing IPCDisplayTickMetrics) throws {
        begin(123)
        var first = true
        self.key("completionPastTargetCount", &first)
        try self.value(value.completionPastTargetCount)
        self.key("longTimestampGapCount", &first)
        try self.value(value.longTimestampGapCount)
        self.key("maxIntervalMicroseconds", &first)
        try self.value(value.maxIntervalMicroseconds)
        self.key("maxWorkMicroseconds", &first)
        try self.value(value.maxWorkMicroseconds)
        self.key("meanWorkMicroseconds", &first)
        try self.value(value.meanWorkMicroseconds)
        self.key("minCompletionSlackMicroseconds", &first)
        try self.value(value.minCompletionSlackMicroseconds)
        self.key("minEntrySlackMicroseconds", &first)
        try self.value(value.minEntrySlackMicroseconds)
        self.key("tickCount", &first)
        try self.value(value.tickCount)
        self.key("timingAnomalyCount", &first)
        try self.value(value.timingAnomalyCount)
        self.key("timingAnomalyPercent", &first)
        try self.value(value.timingAnomalyPercent)
        self.key("workExceededNominalPeriodCount", &first)
        try self.value(value.workExceededNominalPeriodCount)
        end(125)
    }

    mutating func value(_ value: borrowing IPCLayoutBuildMetrics) throws {
        begin(123)
        var first = true
        self.key("completedRelayoutCycles", &first)
        try self.value(value.completedRelayoutCycles)
        self.key("totalBuilds", &first)
        try self.value(value.totalBuilds)
        end(125)
    }

    mutating func value(_ value: borrowing IPCProcessResourceMetrics) throws {
        begin(123)
        var first = true
        self.key("energyNanojoules", &first)
        try self.value(value.energyNanojoules)
        self.key("interruptWakeups", &first)
        try self.value(value.interruptWakeups)
        self.key("packageIdleWakeups", &first)
        try self.value(value.packageIdleWakeups)
        self.key("physicalFootprintBytes", &first)
        try self.value(value.physicalFootprintBytes)
        self.key("residentSizeBytes", &first)
        try self.value(value.residentSizeBytes)
        self.key("systemTimeNanoseconds", &first)
        try self.value(value.systemTimeNanoseconds)
        self.key("userTimeNanoseconds", &first)
        try self.value(value.userTimeNanoseconds)
        end(125)
    }

    mutating func value(_ value: borrowing IPCMetricsQueryResult) throws {
        begin(123)
        var first = true
        self.key("axWrites", &first)
        try self.value(value.axWrites)
        self.key("displayTicks", &first)
        try self.value(value.displayTicks)
        self.key("layoutBuilds", &first)
        try self.value(value.layoutBuilds)
        if let fieldValue = value.process {
            self.key("process", &first)
            try self.value(fieldValue)
        }
        self.key("traceCaptureActive", &first)
        try self.value(value.traceCaptureActive)
        end(125)
    }

    mutating func value(_ value: borrowing IPCShellWidget) throws {
        begin(123)
        var first = true
        if let fieldValue = value.error {
            self.key("error", &first)
            try self.value(fieldValue)
        }
        self.key("name", &first)
        try self.value(value.name)
        self.key("placements", &first)
        try self.value(value.placements)
        self.key("source", &first)
        try self.value(value.source)
        self.key("state", &first)
        try self.value(value.state)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCShellWidget]) throws {
        begin(91)
        var first = true
        let span = value.span
        var index = 0
        while index < span.count {
            item(&first)
            try self.value(span[index])
            index += 1
        }
        end(93)
    }

    mutating func value(_ value: borrowing IPCShellWidgetsQueryResult) throws {
        begin(123)
        var first = true
        self.key("problems", &first)
        try self.value(value.problems)
        self.key("profile", &first)
        try self.value(value.profile)
        self.key("widgets", &first)
        try self.value(value.widgets)
        end(125)
    }

    mutating func value(_ value: borrowing IPCResult) throws {
        begin(123)
        var first = true
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("payload", &first)
        switch value.payload {
        case let .pong(payload):
            try self.value(payload)
        case let .version(payload):
            try self.value(payload)
        case let .capture(payload):
            try self.value(payload)
        case let .workspaceBar(payload):
            try self.value(payload)
        case let .activeWorkspace(payload):
            try self.value(payload)
        case let .focusedMonitor(payload):
            try self.value(payload)
        case let .apps(payload):
            try self.value(payload)
        case let .focusedWindow(payload):
            try self.value(payload)
        case let .windows(payload):
            try self.value(payload)
        case let .workspaces(payload):
            try self.value(payload)
        case let .displays(payload):
            try self.value(payload)
        case let .rules(payload):
            try self.value(payload)
        case let .ruleActions(payload):
            try self.value(payload)
        case let .queries(payload):
            try self.value(payload)
        case let .commands(payload):
            try self.value(payload)
        case let .subscriptions(payload):
            try self.value(payload)
        case let .capabilities(payload):
            try self.value(payload)
        case let .subscribed(payload):
            try self.value(payload)
        case let .windowMarks(payload):
            try self.value(payload)
        case let .windowGather(payload):
            try self.value(payload)
        case let .metrics(payload):
            try self.value(payload)
        case let .shellWidgets(payload):
            try self.value(payload)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCResponseStatus) throws {
        try self.value(value.rawValue)
    }
}
