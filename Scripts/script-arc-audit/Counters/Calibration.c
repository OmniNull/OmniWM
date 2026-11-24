// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdlib.h>
#include "ScriptARCCounters.h"

extern void *objc_retain(void *);
extern void objc_release(void *);
extern void script_arc_check_weighted(void *object, uint32_t multiplicity);
extern void *swift_bridgeObjectRetain_n(void *, uint32_t);
extern void swift_bridgeObjectRelease_n(void *, uint32_t);
extern void *swift_unknownObjectRetain(void *);
extern void swift_unknownObjectRelease(void *);
extern void *swift_unknownObjectWeakInit(void *, void *);
extern void *swift_unknownObjectWeakLoadStrong(void *);
extern void swift_unknownObjectWeakDestroy(void *);
extern void *objc_initWeak(void **, void *);
extern void *objc_loadWeakRetained(void **);
extern void objc_destroyWeak(void **);
extern void *objc_retainAutoreleasedReturnValue(void *);
extern void *objc_autoreleaseReturnValue(void *);
extern void *swift_weakLoadStrong(void *);
extern void *swift_weakInit(void *, void *);
extern void swift_weakDestroy(void *);
extern void swift_release(void *);

void script_arc_calibration_calls(void *object, void *ns_object, uint32_t multiplicity) {
    script_arc_check_weighted(object, multiplicity);
    void *weak = NULL;
    swift_weakInit(&weak, object);
    swift_release(swift_weakLoadStrong(&weak));
    swift_weakDestroy(&weak);
    swift_unknownObjectWeakInit(&weak, ns_object);
    swift_unknownObjectRelease(swift_unknownObjectWeakLoadStrong(&weak));
    swift_unknownObjectWeakDestroy(&weak);
    objc_initWeak(&weak, ns_object);
    objc_release(objc_loadWeakRetained(&weak));
    objc_destroyWeak(&weak);
    objc_release(objc_retain(ns_object));
    objc_release(objc_retainAutoreleasedReturnValue(objc_autoreleaseReturnValue(objc_retain(ns_object))));
    swift_unknownObjectRelease(swift_unknownObjectRetain(ns_object));
    swift_bridgeObjectRelease_n(swift_bridgeObjectRetain_n(object, multiplicity), multiplicity);
    CFRelease(CFRetain(ns_object));
    void *allocation = malloc(sizeof(weak));
    script_arc_sink(allocation);
    free(allocation);
}
