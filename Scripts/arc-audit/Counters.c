// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "Counters.h"
#include <pthread.h>
#include <stddef.h>

typedef void Object;
typedef void (MallocLogger)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);

extern Object *(*_swift_allocObject)(const void *, size_t, size_t);
extern Object *(*_swift_retain)(Object *);
extern void (*_swift_release)(Object *);
extern Object *(*_swift_retain_n)(Object *, uint32_t);
extern void (*_swift_release_n)(Object *, uint32_t);
extern MallocLogger *malloc_logger;

static Object *(*saved_alloc)(const void *, size_t, size_t);
static Object *(*saved_retain)(Object *);
static void (*saved_release)(Object *);
static Object *(*saved_retain_n)(Object *, uint32_t);
static void (*saved_release_n)(Object *, uint32_t);
static volatile int active;
static pthread_t counting;
static uint64_t retains, releases, allocations, mallocs;

static int counts(void) {
    return active && pthread_equal(pthread_self(), counting);
}

static Object *count_alloc(const void *metadata, size_t size, size_t align) {
    if (counts()) allocations++;
    return saved_alloc(metadata, size, align);
}

static Object *count_retain(Object *object) {
    if (counts()) retains++;
    return saved_retain(object);
}

static void count_release(Object *object) {
    if (counts()) releases++;
    saved_release(object);
}

static Object *count_retain_n(Object *object, uint32_t n) {
    if (counts()) retains += n;
    return saved_retain_n(object, n);
}

static void count_release_n(Object *object, uint32_t n) {
    if (counts()) releases += n;
    saved_release_n(object, n);
}

static void count_malloc(uint32_t type, uintptr_t zone, uintptr_t size, uintptr_t old, uintptr_t result, uint32_t skip) {
    if ((type & 2) && counts()) mallocs++;
}

void arc_audit_install(void) {
    saved_alloc = _swift_allocObject;
    saved_retain = _swift_retain;
    saved_release = _swift_release;
    saved_retain_n = _swift_retain_n;
    saved_release_n = _swift_release_n;
    _swift_allocObject = count_alloc;
    _swift_retain = count_retain;
    _swift_release = count_release;
    _swift_retain_n = count_retain_n;
    _swift_release_n = count_release_n;
    malloc_logger = count_malloc;
}

void arc_audit_start(void) {
    retains = releases = allocations = mallocs = 0;
    counting = pthread_self();
    active = 1;
}

void arc_audit_stop(void) { active = 0; }
uint64_t arc_audit_retains(void) { return retains; }
uint64_t arc_audit_releases(void) { return releases; }
uint64_t arc_audit_allocations(void) { return allocations; }
uint64_t arc_audit_mallocs(void) { return mallocs; }
