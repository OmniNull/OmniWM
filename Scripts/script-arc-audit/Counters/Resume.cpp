// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct lua_State;
int lua_resume(lua_State *, lua_State *, int);
extern "C" void script_arc_vm_entry();

int script_arc_lua_resume(lua_State *state, lua_State *parent, int arguments) {
    script_arc_vm_entry();
    return lua_resume(state, parent, arguments);
}
