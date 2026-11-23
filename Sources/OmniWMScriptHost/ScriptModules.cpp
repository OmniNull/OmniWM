// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptModules.h"

#include <algorithm>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace omni_detail {

static omni_config_location scriptLocation(lua_State *L, ModuleRuntime &vm, lua_Debug &frame) {
    for (int level = 0; lua_getinfo(L, level, "sl", &frame); level++) {
        if (frame.currentline <= 0 || frame.source == nullptr) {
            continue;
        }
        for (uint32_t id = 0; id < vm.modules.size(); id++) {
            if (vm.modules[id].chunk == frame.source) {
                return {id, frame.currentline};
            }
        }
    }
    return vm.invoking ? vm.location : omni_config_location{vm.chain.back(), 0};
}

omni_config_location declarationSite(lua_State *L, ModuleRuntime &vm) {
    lua_Debug frame{};
    return scriptLocation(L, vm, frame);
}

void trimUTF8End(char *bytes, size_t capacity) {
    if (!bytes || !capacity) {
        return;
    }
    size_t end = std::strlen(bytes);
    if (end == 0 || end != capacity - 1) {
        return;
    }
    size_t start = end - 1;
    while (start != 0 && (static_cast<unsigned char>(bytes[start]) & 0xC0) == 0x80) {
        --start;
    }
    unsigned char lead = static_cast<unsigned char>(bytes[start]);
    size_t width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
    if (end - start < width) {
        bytes[start] = '\0';
    }
}

[[noreturn]] void reject(lua_State *L, ModuleRuntime &vm, omni_config_location location, const char *reason) {
    if (!vm.rejected) {
        vm.rejected = true;
        vm.location = location;
        if (reason != vm.failure) {
            copyMessage(reason, vm.failure, sizeof vm.failure);
        }
        trimUTF8End(vm.failure, sizeof vm.failure);
    }
    luaL_error(L, "%s", vm.failure);
}

omni_config_span token(lua_State *L, ModuleRuntime &vm, int index, omni_config_location location) {
    if (lua_type(L, index) != LUA_TSTRING) {
        reject(L, vm, location, "expected a string token");
    }
    omni_config_span span;
    span.data = lua_tolstring(L, index, &span.length);
    if (span.length > OMNI_CONFIG_BYTE_LIMIT - vm.tokenBytes) {
        reject(L, vm, location, "config declarations exceeded their byte limit");
    }
    vm.tokenBytes += span.length;
    return span;
}

static void removeLocationPrefix(const lua_Debug &frame, int line, char *error) {
    if (!frame.short_src || !error || !line) {
        return;
    }
    char prefix[LUA_IDSIZE + 16];
    int size = std::snprintf(prefix, sizeof prefix, "%s:%d: ", frame.short_src, line);
    if (size > 0 && static_cast<size_t>(size) < sizeof prefix && std::strncmp(error, prefix, size) == 0) {
        std::memmove(error, error + size, std::strlen(error + size) + 1);
    }
}

static int captureModuleError(lua_State *L) {
    auto &vm = *static_cast<ModuleRuntime *>(lua_callbacks(L)->userdata);
    if (!vm.rejected) {
        lua_Debug frame{};
        vm.location = scriptLocation(L, vm, frame);
        copyValueMessage(L, 1, vm.failure, sizeof vm.failure);
        trimUTF8End(vm.failure, sizeof vm.failure);
        removeLocationPrefix(frame, vm.location.line, vm.failure);
        vm.rejected = true;
    }
    return 1;
}

static void compileError(const char *bytes, size_t size, int &line, char *error, size_t capacity) {
    const char *end = bytes + size;
    if (bytes != end && *bytes == ':') {
        auto parsed = std::from_chars(bytes + 1, end, line);
        if (parsed.ec == std::errc{} && end - parsed.ptr >= 2 && parsed.ptr[0] == ':' && parsed.ptr[1] == ' ') {
            bytes = parsed.ptr + 2;
        }
    }
    if (error != nullptr && capacity > 0) {
        size_t length = std::min(static_cast<size_t>(end - bytes), capacity - 1);
        std::memcpy(error, bytes, length);
        error[length] = '\0';
        trimUTF8End(error, capacity);
    }
}

omni_status loadChunk(lua_State *L, const char *name, omni_config_span source, int &line,
    char *error, size_t capacity) {
    lua_CompileOptions options = scriptCompileOptions();
    size_t size = 0;
    std::unique_ptr<char, decltype(&std::free)> bytecode(
        luau_compile(source.data ? source.data : "", source.length, &options, &size), std::free);
    if (!bytecode || size == 0) {
        copyMessage("compiler allocation failed", error, capacity);
        return OMNI_ERR_MEMORY;
    }
    if (bytecode.get()[0] == 0) {
        compileError(bytecode.get() + 1, size - 1, line, error, capacity);
        return OMNI_ERR_COMPILE;
    }
    if (luau_load(L, name, bytecode.get(), size, 0) != 0) {
        copyValueMessage(L, -1, error, capacity);
        return OMNI_ERR_MEMORY;
    }
    return OMNI_OK;
}

int requireConfigModule(lua_State *L) {
    auto &vm = *static_cast<ModuleRuntime *>(lua_callbacks(L)->userdata);
    if (vm.rejected) luaL_error(L, "%s", vm.failure);
    auto site = declarationSite(L, vm);
    if (vm.invoking) {
        reject(L, vm, site, "require modules while loading the config, before the callback runs");
    }
    if (lua_gettop(L) != 1 || !vm.readModule) {
        reject(L, vm, site, "require expects one relative module path");
    }
    omni_config_span spec = token(L, vm, 1, site);
    omni_config_module module{};
    if (!vm.readModule(vm.context, site.source_id, spec, &module, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "unavailable module");
    }
    if (module.id > OMNI_CONFIG_MODULE_LIMIT || module.id > vm.modules.size()
        || !module.name.data || (!module.source.data && module.source.length)) {
        reject(L, vm, site, "invalid module source");
    }
    if (module.id == vm.modules.size()) {
        vm.modules.push_back({"@" + std::string(module.name.data, module.name.length)});
    }
    if (std::find(vm.chain.begin(), vm.chain.end(), module.id) != vm.chain.end()) {
        std::string chain = "Require cycle: ";
        for (uint32_t id : vm.chain) {
            chain.append(vm.modules[id].chunk, 1).append(" -> ");
        }
        chain.append(vm.modules[module.id].chunk, 1);
        reject(L, vm, site, chain.c_str());
    }
    if (vm.modules[module.id].result != LUA_NOREF) {
        lua_getref(L, vm.modules[module.id].result);
        return 1;
    }
    vm.chain.push_back(module.id);
    lua_pushcfunction(L, captureModuleError, "config module error");
    int handler = lua_gettop(L);
    lua_State *moduleThread = lua_newthread(L);
    lua_xpush(vm.main, moduleThread, LUA_GLOBALSINDEX);
    lua_replace(moduleThread, LUA_GLOBALSINDEX);
    luaL_sandboxthread(moduleThread);
    omni_config_location moduleSite{module.id, 0};
    if (loadChunk(moduleThread, vm.modules[module.id].chunk.c_str(), module.source, moduleSite.line,
        vm.failure, sizeof vm.failure) != OMNI_OK) {
        reject(L, vm, moduleSite, vm.failure);
    }
    lua_xmove(moduleThread, L, 1);
    vm.moduleExecutions++;
    vm.recordEntry();
    int result = lua_pcall(L, 0, 1, handler);
    if (result != LUA_OK || vm.rejected) {
        if (!vm.rejected) {
            copyValueMessage(L, -1, vm.failure, sizeof vm.failure);
        }
        reject(L, vm, moduleSite, vm.failure);
    }
    if (lua_isnil(L, -1)) {
        std::string reason = "Module " + vm.modules[module.id].chunk.substr(1) + " returned no value";
        reject(L, vm, site, reason.c_str());
    }
    vm.modules[module.id].result = lua_ref(L, -1);
    vm.chain.pop_back();
    return 1;
}

omni_status finishModuleCall(ModuleRuntime &vm, lua_State *L, int result, char *error, size_t capacity) {
    if (vm.latched) {
        if (!vm.rejected) {
            vm.location = declarationSite(L, vm);
        }
        copyMessage("script exceeded its CPU budget", error, capacity);
        return OMNI_ERR_TIMEOUT;
    }
    if (vm.rejected) {
        copyMessage(vm.failure, error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    if (vm.chain.size() != 1 && result == LUA_OK) {
        vm.location = {vm.chain.back(), 0};
        copyMessage("module load did not complete", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    lua_Debug frame{};
    if (result != LUA_OK) {
        vm.location = scriptLocation(L, vm, frame);
    }
    auto status = finish(&vm, L, result, error, capacity);
    trimUTF8End(error, capacity);
    if (capacity > 0) {
        removeLocationPrefix(frame, vm.location.line, error);
    }
    return status;
}

}
