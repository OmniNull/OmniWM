// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#pragma once
#include <stdint.h>
#include <stdbool.h>

void script_arc_install(void);
void script_arc_check_calibration(void);
void script_arc_begin(void);
void script_arc_end(void);
void script_arc_follow(const void *task, bool has_seed);
void script_arc_finish(void);
void script_arc_follow_timer(void);
void script_arc_report(const char *route, const char *control, unsigned callbacks);
void script_arc_save_native_key(void);
void script_arc_check_native_key(void);
void script_arc_sink(const void *value);
void script_arc_calibration_calls(void *object, void *ns_object, uint32_t multiplicity);
void script_arc_checkpoint(void);
void script_arc_config_return(void);
void script_arc_watch_park(const void *task, void *observer);
void script_arc_hold_next_entry(void *observer);
void script_arc_release_entry(void);
void script_arc_finish_entry(void);
