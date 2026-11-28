// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include <stdint.h>

void arc_audit_install(void);
void arc_audit_start(void);
void arc_audit_stop(void);
uint64_t arc_audit_retains(void);
uint64_t arc_audit_releases(void);
uint64_t arc_audit_allocations(void);
uint64_t arc_audit_mallocs(void);

typedef struct {
    uint64_t retains, releases, allocations, mallocs;
} arc_audit_counts;

void arc_audit_install_scoped(arc_audit_counts *(*scope)(void));
