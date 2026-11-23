// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#pragma once

#include "ScriptHostInternal.h"

namespace omni_detail {

#if defined(DEBUG) || defined(OMNIWM_LIVE_CHECKS)
inline constexpr bool trackConfigMetrics = true;
#else
inline constexpr bool trackConfigMetrics = false;
#endif

struct Module {
    std::string chunk;
    int result = LUA_NOREF;
};

struct ModuleRuntime : ScriptRuntime {
    void *context;
    omni_read_module readModule;
    std::atomic<uint64_t> *entryCounter;
    bool invoking = false;
    size_t tokenBytes = 0;
    unsigned moduleExecutions = 0;
    std::vector<Module> modules;
    std::vector<uint32_t> chain;
    char failure[OMNI_CONFIG_ERROR_CAPACITY]{};
    omni_config_location location{};
    bool rejected = false;

    ModuleRuntime(omni_read_module read, void *ctx, std::atomic<uint64_t> *counter = nullptr)
        : context(ctx), readModule(read), entryCounter(counter) {}

    void recordEntry() const {
        if constexpr (trackConfigMetrics) {
            if (entryCounter) entryCounter->fetch_add(1, std::memory_order_relaxed);
        }
    }
};

omni_config_location declarationSite(lua_State *L, ModuleRuntime &vm);
void trimUTF8End(char *bytes, size_t capacity);
[[noreturn]] void reject(lua_State *L, ModuleRuntime &vm, omni_config_location location, const char *reason);
omni_config_span token(lua_State *L, ModuleRuntime &vm, int index, omni_config_location location);
omni_status loadChunk(lua_State *L, const char *name, omni_config_span source, int &line, char *error, size_t capacity);
int requireConfigModule(lua_State *L);
omni_status finishModuleCall(ModuleRuntime &vm, lua_State *L, int result, char *error, size_t capacity);

}
