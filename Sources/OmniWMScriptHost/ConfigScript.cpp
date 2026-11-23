// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string_view>

namespace {

using namespace omni_detail;

constexpr int actionTag = 1;
constexpr size_t maximumRuleFields = 14;
std::atomic<uint64_t> liveVMs{0};
std::atomic<uint64_t> vmEntries{0};

struct Module {
    std::string chunk;
    int result = LUA_NOREF;
};

struct ConfigVM : ScriptRuntime {
    const omni_config_callbacks &callbacks;
    void *context;
    size_t tokenBytes = 0;
    unsigned actions = 0;
    unsigned bindings = 0;
    unsigned rules = 0;
    unsigned moduleExecutions = 0;
    std::vector<Module> modules;
    std::vector<uint32_t> chain;
    char failure[OMNI_CONFIG_ERROR_CAPACITY]{};
    omni_config_location location{};
    bool rejected = false;

    ConfigVM(const omni_config_callbacks &callbacks, void *context) : callbacks(callbacks), context(context) {}
    ~ConfigVM() {
        if (main != nullptr) {
            closeRuntime(*this);
            liveVMs.fetch_sub(1, std::memory_order_relaxed);
        }
    }
};

omni_config_location scriptLocation(lua_State *L, ConfigVM &vm, lua_Debug &frame) {
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
    return {vm.chain.back(), 0};
}

omni_config_location declarationSite(lua_State *L, ConfigVM &vm) {
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

[[noreturn]] void reject(lua_State *L, ConfigVM &vm, omni_config_location location, const char *reason) {
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

ConfigVM &declarations(lua_State *L) {
    auto &vm = *static_cast<ConfigVM *>(lua_callbacks(L)->userdata);
    if (vm.rejected) {
        luaL_error(L, "%s", vm.failure);
    }
    return vm;
}

omni_config_span token(lua_State *L, ConfigVM &vm, int index, omni_config_location location) {
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

int command(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    std::array<omni_config_span, LUA_MINSTACK> words;
    int count = lua_gettop(L);
    if (count == 0 || static_cast<size_t>(count) > words.size()) {
        reject(L, vm, site, "invalid number of command words");
    }
    if (vm.actions == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config action limit exceeded");
    }
    for (int i = 0; i < count; i++) {
        words[i] = token(L, vm, i + 1, site);
    }
    auto *action = static_cast<uint32_t *>(lua_newuserdatatagged(L, sizeof(uint32_t), actionTag));
    if (!vm.callbacks.resolve(vm.context, words.data(), count, site, action, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid command");
    }
    vm.actions++;
    return 1;
}

int bindKey(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    const int count = lua_gettop(L);
    if (count < 2 || count > 3 || (!lua_isnoneornil(L, 3) && !lua_istable(L, 3))) {
        reject(L, vm, site, "keymap.set expects a chord, a command and an optional table");
    }
    if (vm.bindings == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config binding limit exceeded");
    }
    omni_config_span chord = token(L, vm, 1, site);
    const auto *action = static_cast<const uint32_t *>(lua_touserdatatagged(L, 2, actionTag));
    if (action == nullptr) {
        reject(L, vm, site, "expected an action returned by omniwm.cmd");
    }
    omni_config_span modeKey{};
    if (lua_istable(L, 3)) {
        lua_pushnil(L);
        while (lua_next(L, 3)) {
            const auto name = token(L, vm, -2, site);
            if (std::string_view(name.data, name.length) != "modeKey") {
                reject(L, vm, site, "unknown keymap.set option; expected modeKey");
            }
            modeKey = token(L, vm, -1, site);
            lua_pop(L, 1);
        }
    }
    if (!vm.callbacks.bind(vm.context, chord, *action, modeKey, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid binding");
    }
    vm.bindings++;
    return 0;
}

int addRule(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (!vm.callbacks.rule || lua_gettop(L) != 1 || !lua_istable(L, 1)) {
        reject(L, vm, site, "omniwm.rule expects one table of rule fields");
    }
    if (vm.rules == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config rule limit exceeded");
    }
    std::array<omni_config_field, maximumRuleFields> fields;
    size_t count = 0;
    lua_pushnil(L);
    while (lua_next(L, 1)) {
        if (count == fields.size()) {
            reject(L, vm, site, "too many fields in rule");
        }
        omni_config_field field{};
        field.name = token(L, vm, -2, site);
        switch (lua_type(L, -1)) {
        case LUA_TSTRING:
            field.kind = OMNI_CONFIG_STRING;
            field.string_value = token(L, vm, -1, site);
            break;
        case LUA_TNUMBER:
            field.kind = OMNI_CONFIG_NUMBER;
            field.number_value = lua_tonumber(L, -1);
            break;
        case LUA_TBOOLEAN:
            field.kind = OMNI_CONFIG_BOOLEAN;
            field.bool_value = lua_toboolean(L, -1) != 0;
            break;
        default:
            reject(L, vm, site, "rule fields must be strings, numbers or booleans");
        }
        fields[count++] = field;
        lua_pop(L, 1);
    }
    if (!vm.callbacks.rule(vm.context, fields.data(), count, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid rule");
    }
    vm.rules++;
    return 0;
}

void removeLocationPrefix(const lua_Debug &frame, int line, char *error) {
    if (!frame.short_src || !error || !line) {
        return;
    }
    char prefix[LUA_IDSIZE + 16];
    int size = std::snprintf(prefix, sizeof prefix, "%s:%d: ", frame.short_src, line);
    if (size > 0 && static_cast<size_t>(size) < sizeof prefix && std::strncmp(error, prefix, size) == 0) {
        std::memmove(error, error + size, std::strlen(error + size) + 1);
    }
}

int captureModuleError(lua_State *L) {
    auto &vm = *static_cast<ConfigVM *>(lua_callbacks(L)->userdata);
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

void compileError(const char *bytes, size_t size, int &line, char *error, size_t capacity) {
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

int requireModule(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (lua_gettop(L) != 1 || !vm.callbacks.read_module) {
        reject(L, vm, site, "require expects one relative module path");
    }
    omni_config_span spec = token(L, vm, 1, site);
    omni_config_module module{};
    if (!vm.callbacks.read_module(vm.context, site.source_id, spec, &module, vm.failure, sizeof vm.failure)) {
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
    vmEntries.fetch_add(1, std::memory_order_relaxed);
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

void installConfig(lua_State *L) {
    for (lua_CFunction open : {luaopen_base, luaopen_table, luaopen_string, luaopen_math, luaopen_bit32, luaopen_utf8}) {
        lua_pushcfunction(L, open, nullptr);
        lua_call(L, 0, 0);
    }
    for (const char *name : {"print", "getfenv", "setfenv"}) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    lua_pushcfunction(L, requireModule, "require");
    lua_setglobal(L, "require");
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, command, "cmd");
    lua_setfield(L, -2, "cmd");
    lua_pushcfunction(L, addRule, "rule");
    lua_setfield(L, -2, "rule");
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, bindKey, "set");
    lua_setfield(L, -2, "set");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "keymap");
    lua_setreadonly(L, -1, true);
    lua_setglobal(L, "omniwm");
}

omni_status runConfig(ConfigVM &vm, const char *name, omni_config_span source, uint64_t budget, char *error, size_t capacity) {
    vm.modules.push_back({name});
    vm.chain.push_back(0);
    lua_State *L = vm.thread;
    auto status = loadChunk(L, name, source, vm.location.line, error, capacity);
    if (status != OMNI_OK) {
        return status;
    }
    {
        CallScope scope(&vm, budget);
        vmEntries.fetch_add(1, std::memory_order_relaxed);
        int result = lua_resume(L, nullptr, 0);
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
        status = finish(&vm, L, result, error, capacity);
        trimUTF8End(error, capacity);
        if (capacity > 0) {
            removeLocationPrefix(frame, vm.location.line, error);
        }
    }
    return enforceBudget(&vm, status, error, capacity);
}

}

omni_status omni_config_evaluate(const char *chunk_name, omni_config_span source,
    size_t heap_limit, uint64_t cpu_budget_ns, const omni_config_callbacks *callbacks,
    void *context, omni_config_stats *stats, char *error, size_t error_capacity) noexcept {
    using namespace omni_detail;
    if (stats != nullptr) {
        *stats = {};
    }
    if (error != nullptr && error_capacity > 0) {
        error[0] = '\0';
    }
    if (!chunk_name || (!source.data && source.length) || !callbacks || !callbacks->resolve || !callbacks->bind || !cpu_budget_ns) {
        copyMessage("invalid config evaluator arguments", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
    if (source.length > OMNI_CONFIG_BYTE_LIMIT) {
        copyMessage("config source exceeds 1 MiB", error, error_capacity);
        return OMNI_ERR_COMPILE;
    }
    ConfigVM vm(*callbacks, context);
    omni_status status = OMNI_ERR_MEMORY;
    try {
        if (openRuntime(vm, heap_limit, &vm, true)) {
            liveVMs.fetch_add(1, std::memory_order_relaxed);
            installConfig(vm.main);
            sandboxRuntime(vm);
            status = runConfig(vm, chunk_name, source, cpu_budget_ns, error, error_capacity);
        } else {
            copyMessage("unable to allocate the config VM", error, error_capacity);
        }
    } catch (const std::bad_alloc &) {
        copyMessage("config allocation failed", error, error_capacity);
    } catch (...) {
        if (vm.timer == nullptr) {
            copyMessage("unable to initialize the config VM within its heap limit", error, error_capacity);
        } else {
            copyMessage("unexpected config evaluator error", error, error_capacity);
            status = OMNI_ERR_INTERNAL;
        }
    }
    trimUTF8End(error, error_capacity);
    if (stats != nullptr) {
        stats->peak_bytes = vm.peak;
        stats->location = vm.location;
        stats->module_executions = vm.moduleExecutions;
    }
    return status;
}

uint64_t omni_config_live_vm_count(void) noexcept {
    return liveVMs.load(std::memory_order_relaxed);
}

uint64_t omni_config_vm_entry_count(void) noexcept {
    return vmEntries.load(std::memory_order_relaxed);
}
