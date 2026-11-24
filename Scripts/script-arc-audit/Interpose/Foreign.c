// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "Foreign.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define INTERPOSE(original, replacement) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_fn, *old_fn; } hook_##original = { replacement, original };
#define RETURNING(fn, tag) \
    extern void *fn(void *); \
    static void *measured_##fn(void *p) { script_arc_foreign(tag); __attribute__((musttail)) return fn(p); } \
    INTERPOSE(fn, measured_##fn)
#define RELEASING(fn, tag) \
    extern void fn(void *); \
    static void measured_##fn(void *p) { script_arc_foreign(tag); __attribute__((musttail)) return fn(p); } \
    INTERPOSE(fn, measured_##fn)

RETURNING(objc_retain, objc_own)
RELEASING(objc_release, objc_drop)
RETURNING(CFRetain, cf_own)
RELEASING(CFRelease, cf_drop)
RETURNING(swift_weakLoadStrong, weak_swift)
RETURNING(swift_unknownObjectWeakLoadStrong, weak_unknown)
RETURNING(objc_loadWeakRetained, weak_objc)
RETURNING(objc_retainAutoreleasedReturnValue, objc_return_own)
RETURNING(objc_autoreleaseReturnValue, objc_return_auto)
RETURNING(swift_unknownObjectRetain, unknown_own)
RELEASING(swift_unknownObjectRelease, unknown_drop)

RETURNING(swift_bridgeObjectRetain, bridge_own)
RELEASING(swift_bridgeObjectRelease, bridge_drop)

extern void *swift_bridgeObjectRetain_n(void *, unsigned);
extern void swift_bridgeObjectRelease_n(void *, unsigned);

static void *measured_bridge_retain_n(void *object, unsigned n) {
    script_arc_foreign_n(bridge_own, n);
    __attribute__((musttail)) return swift_bridgeObjectRetain_n(object, n);
}
static void measured_bridge_release_n(void *object, unsigned n) {
    script_arc_foreign_n(bridge_drop, n);
    __attribute__((musttail)) return swift_bridgeObjectRelease_n(object, n);
}
INTERPOSE(swift_bridgeObjectRetain_n, measured_bridge_retain_n)
INTERPOSE(swift_bridgeObjectRelease_n, measured_bridge_release_n)

extern __attribute__((swiftcall)) bool swift_task_isCancelled(void *);
extern __attribute__((swiftcall, weak_import)) bool swift_task_isCancelledWithFlags(void *, uint64_t);

static __attribute__((swiftcall)) bool measured_is_cancelled(void *task) {
    script_arc_check_dequeue();
    return swift_task_isCancelled(task);
}
static __attribute__((swiftcall)) bool measured_is_cancelled_with_flags(void *task, uint64_t flags) {
    script_arc_check_dequeue();
    return swift_task_isCancelledWithFlags(task, flags);
}
INTERPOSE(swift_task_isCancelled, measured_is_cancelled)
INTERPOSE(swift_task_isCancelledWithFlags, measured_is_cancelled_with_flags)

extern __attribute__((swiftcall)) void *swift_continuation_init(void *, uintptr_t);
extern __attribute__((swiftcall)) void swift_continuation_throwingResume(void *);
static __attribute__((swiftcall)) void *observed_init(void *frame, uintptr_t flags) {
    void *result = swift_continuation_init(frame, flags);
    script_arc_observe_park();
    return result;
}
static void resume_real(void *continuation) { swift_continuation_throwingResume(continuation); }
static __attribute__((swiftcall)) void observed_resume(void *continuation) {
    script_arc_record_wake(resume_real, continuation);
}
INTERPOSE(swift_continuation_init, observed_init)
INTERPOSE(swift_continuation_throwingResume, observed_resume)
