// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#pragma once

enum script_foreign_call {
    weak_swift, weak_unknown, weak_objc, objc_own, objc_drop, objc_return_own,
    objc_return_auto, cf_own, cf_drop, unknown_own, unknown_drop, bridge_own, bridge_drop, foreign_count
};

void script_arc_foreign(enum script_foreign_call call);
void script_arc_foreign_n(enum script_foreign_call call, unsigned n);
void script_arc_observe_park(void);
void script_arc_record_wake(void (*resume)(void *), void *continuation);
