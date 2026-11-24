// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptARCCounters.h"
#include "Counters.h"
#include "Foreign.h"
#include <dispatch/dispatch.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *swift_task_getCurrent(void);
extern void *swift_retain_n(void *, uint32_t);
extern void swift_release_n(void *, uint32_t);

enum phase { producer, dequeue, config, completion, phase_count };
static const char *const phase_names[] = {"producer", "dequeue", "config", "completion"};
struct sample {
    arc_audit_counts swift;
    uint64_t foreign[foreign_count];
    uint64_t vm;
};
static struct sample samples[phase_count], native_key;
static _Atomic bool producing, skipping_seed, resumed;
static _Atomic(const void *) worker;
static unsigned seed_entries, expected_seeds, wake_count;
static bool followed;
static uint64_t wake_retains, wake_releases;
static void *park_observer;
static const void *observed_task;
static bool notifying_main_observer;
extern __attribute__((swiftcall)) void swift_continuation_throwingResume(void *);

static void require(bool passed, const char *reason) {
    if (!passed) {
        fprintf(stderr, "script-arc-audit: %s\n", reason);
        exit(EXIT_FAILURE);
    }
}

static struct sample *current(void) {
    bool on_main = pthread_main_np();
    if (on_main && notifying_main_observer) return NULL;
    if (on_main && atomic_load_explicit(&producing, memory_order_relaxed)) return &samples[producer];
    const void *task = atomic_load_explicit(&worker, memory_order_acquire);
    if (!task || swift_task_getCurrent() != task || atomic_load(&skipping_seed)) return NULL;
    if (!on_main) return &samples[config];
    return &samples[atomic_load(&resumed) ? completion : dequeue];
}

static arc_audit_counts *swift_scope(void) {
    struct sample *s = current();
    return s ? &s->swift : NULL;
}

void script_arc_foreign(enum script_foreign_call call) { script_arc_foreign_n(call, 1); }

void script_arc_foreign_n(enum script_foreign_call call, unsigned n) {
    struct sample *s = current();
    if (s) s->foreign[call] += n;
}

void script_arc_check_dequeue(void) {
    if (!atomic_load_explicit(&skipping_seed, memory_order_relaxed) || !atomic_load(&resumed)) return;
    if (!pthread_main_np() || swift_task_getCurrent() != atomic_load(&worker)) return;
    atomic_store(&resumed, false);
    atomic_store(&skipping_seed, false);
}

static _Atomic(void *) blocked_entry_observer;
static dispatch_semaphore_t entry_permission;

void script_arc_hold_next_entry(void *observer) {
    require(pthread_main_np() && !entry_permission, "overlapping callback lifetime probes");
    entry_permission = dispatch_semaphore_create(0);
    atomic_store(&blocked_entry_observer, observer);
}

void script_arc_release_entry(void) {
    require(pthread_main_np() && !atomic_load(&blocked_entry_observer), "worker did not reach the VM");
    dispatch_semaphore_signal(entry_permission);
}

void script_arc_finish_entry(void) {
    dispatch_release(entry_permission);
    entry_permission = NULL;
}

void script_arc_vm_entry(void) {
    void *observer = atomic_exchange(&blocked_entry_observer, NULL);
    if (observer) {
        require(!pthread_main_np(), "blocked config invocation entered on main");
        swift_continuation_throwingResume(observer);
        dispatch_semaphore_wait(entry_permission, DISPATCH_TIME_FOREVER);
    }
    const void *task = atomic_load(&worker);
    if (task) {
        require(task == swift_task_getCurrent() && !pthread_main_np(), "VM entered outside the config worker");
        atomic_store(&resumed, true);
        if (atomic_load(&skipping_seed)) {
            seed_entries++;
            return;
        }
    }
    struct sample *s = current();
    if (s) s->vm++;
}

void script_arc_watch_park(const void *task, void *observer) {
    require(pthread_main_np() && task && !park_observer, "overlapping park observations");
    observed_task = task;
    park_observer = observer;
}

void script_arc_observe_park(void) {
    if (!pthread_main_np() || !park_observer || swift_task_getCurrent() != observed_task) return;
    void *observer = park_observer;
    park_observer = NULL;
    observed_task = NULL;
    notifying_main_observer = true;
    swift_continuation_throwingResume(observer);
    notifying_main_observer = false;
}

void script_arc_record_wake(void (*resume)(void *), void *continuation) {
    if (!atomic_load_explicit(&producing, memory_order_relaxed) || !pthread_main_np()) { resume(continuation); return; }
    arc_audit_counts before = samples[producer].swift;
    resume(continuation);
    wake_count++;
    wake_retains += samples[producer].swift.retains - before.retains;
    wake_releases += samples[producer].swift.releases - before.releases;
}

void script_arc_install(void) { arc_audit_install_scoped(swift_scope); }

void script_arc_begin(void) {
    require(!atomic_load(&worker) && !atomic_load(&producing), "overlapping workloads");
    memset(samples, 0, sizeof(samples));
    seed_entries = wake_count = 0;
    wake_retains = wake_releases = 0;
    followed = false;
    atomic_store(&resumed, false);
    atomic_store(&producing, true);
}

void script_arc_end(void) { atomic_store(&producing, false); }

void script_arc_follow(const void *task, bool has_seed) {
    require(task != NULL && !atomic_load(&producing), "missing worker or open producer scope");
    followed = true;
    expected_seeds = has_seed ? 1 : 0;
    atomic_store(&skipping_seed, has_seed);
    atomic_store(&worker, task);
}

void script_arc_follow_timer(void) {
    require(!pthread_main_np(), "timer clock ticked on main");
    script_arc_begin();
    script_arc_end();
    script_arc_follow(swift_task_getCurrent(), false);
}

void script_arc_finish(void) {
    require(!park_observer, "worker did not park");
    atomic_store(&worker, NULL);
    require(seed_entries == expected_seeds && !atomic_load(&skipping_seed), "busy-worker seed never handed off to the measured key");
}

void script_arc_sink(const void *value) {
    __asm__ volatile("" : : "r"(value) : "memory");
}

void script_arc_check_weighted(void *object, uint32_t multiplicity) {
    arc_audit_counts *s = swift_scope();
    require(s != NULL && multiplicity > 1, "weighted calibration needs a live scope and multiple references");
    uint64_t retains = s->retains, releases = s->releases;
    swift_release_n(swift_retain_n(object, multiplicity), multiplicity);
    require(s->retains - retains == multiplicity && s->releases - releases == multiplicity,
            "Swift _n hook lost its multiplicity");
}

void script_arc_config_return(void) {
    require(current() == &samples[config], "calibration did not reach the worker executor");
    atomic_store(&resumed, true);
}

void script_arc_check_calibration(void) {
    for (enum phase p = producer; p < phase_count; p++) {
        struct sample *s = &samples[p];
        require(s->swift.retains && s->swift.releases && s->swift.allocations && s->swift.mallocs,
                "Swift ownership or allocator hooks missed calibration");
        for (unsigned i = 0; i < foreign_count; i++) {
            if (!s->foreign[i]) {
                fprintf(stderr, "script-arc-audit: foreign import %u missed calibration in %s\n", i, phase_names[p]);
                exit(EXIT_FAILURE);
            }
        }
    }
}

void script_arc_save_native_key(void) { native_key = samples[producer]; }

void script_arc_check_native_key(void) {
    require(memcmp(&native_key, &samples[producer], sizeof(native_key)) == 0,
            "plain script and Settings keys must cost exactly the same through the matched handler");
}

void script_arc_report(const char *route, const char *control, unsigned callbacks) {
    require(samples[producer].vm == 0 && samples[dequeue].vm == 0 && samples[completion].vm == 0,
            "main entered the config VM");
    require(samples[config].vm == callbacks, "delivered callback count differs from accepted work");
    if (!strcmp(route, "key/idle") || !strcmp(route, "key/busy"))
        printf("wake/%s resumes=%u retains=%" PRIu64 " releases=%" PRIu64 "\n", route, wake_count, wake_retains, wake_releases);
    for (enum phase p = producer; p < phase_count; p++) {
        struct sample *s = &samples[p];
        if (!followed && !callbacks && p != producer) {
            struct sample empty = {0};
            require(memcmp(&empty, s, sizeof(empty)) == 0, "native control scheduled script work");
        }
        printf("%-20s %-17s %-10s %5" PRIu64 " %5" PRIu64 " %3" PRIu64 " %4" PRIu64,
               route, control, phase_names[p], s->swift.retains, s->swift.releases, s->swift.allocations, s->swift.mallocs);
        for (unsigned i = 0; i < foreign_count; i++) printf(" %3" PRIu64, s->foreign[i]);
        printf(" %2" PRIu64 "\n", s->vm);
    }
}

void script_arc_checkpoint(void) { __asm__ volatile("" : : : "memory"); }
