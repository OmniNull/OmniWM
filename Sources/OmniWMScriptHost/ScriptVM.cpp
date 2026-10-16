// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"
#include "OmniWMLuauCommon.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <time.h>

namespace {

constexpr uint64_t unboundedBudget = UINT64_MAX / 2;
constexpr uint64_t maximumArm = 3600ull * 1000000000ull;

constexpr char prelude[] = R"(
ui = {}
local function element(kind, axis)
    return function(props)
        props.kind = kind
        if axis ~= nil then
            props.axis = axis
        end
        return props
    end
end
ui.row = element(0, 0)
ui.column = element(0, 1)
ui.stack = element(0, 2)
ui.box = element(1, nil)
ui.text = element(2, nil)
ui.symbol = element(3, nil)
ui.icon = element(4, nil)
ui.image = element(5, nil)
ui.progress = element(6, nil)
ui.shader = element(7, nil)
ui.slider = element(8, nil)
ui.path = element(9, nil)
ui.input = element(10, nil)
omniwm = { components = {} }
local componentHost = _omniComponentHost
_omniComponentHost = nil
local configured = {}
local configuredOrder = {}
local displays = setmetatable({}, { __mode = "k" })
local function setStatus(entry, status, message)
    componentHost.set(entry.metadata, "status", status)
    componentHost.set(entry.metadata, "error", status == "failed" and componentHost.message(message) or nil)
end
local function fail(entry, message)
    setStatus(entry, "failed", message)
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in a do
        if not equal(value, b[key]) then return false end
    end
    for key in b do
        if a[key] == nil then return false end
    end
    return true
end
local function lifecycle(entry, name, previous)
    local fn = entry.definition and rawget(entry.definition, name)
    if fn == nil then return true end
    if type(fn) ~= "function" then
        fail(entry, name .. " must be a function")
        return false
    end
    local ok, result = componentHost.call(fn, entry.instance, previous)
    if not ok then fail(entry, result) end
    return ok
end
local function retire(entry)
    if entry.instance then
        lifecycle(entry, "deinit")
        componentHost.alive(entry.instance, false)
        entry.instance = nil
    end
end
componentHost.reloader(function(widgets)
    local selected = {}
    for _, widget in widgets do selected[widget] = true end
    local result = {}
    for id, entry in configured do
        if selected[entry.metadata.widget] then
            if entry.instance then
                table.insert(result, { entry.instance, rawget(entry.definition, "deinit") })
            end
            configured[id] = nil
        end
    end
    return result
end)
componentHost.receiver(function(instance)
    local entry = configured[instance.id]
    if entry and entry.instance == instance then return rawget(entry.definition, "receive") end
    return nil
end)
componentHost.configure(function(items)
    assert(type(items) == "table" and #items <= 64, "at most 64 components may be configured")
    local incoming = {}
    for _, item in items do
        assert(type(item.id) == "string" and #item.id > 0 and #item.id <= 128, "invalid component id")
        assert(type(item.widget) == "string" and #item.widget > 0, "invalid component widget")
        assert(not incoming[item.id], "duplicate component id")
        incoming[item.id] = item
    end
    for id, entry in configured do
        local nextItem = incoming[id]
        if not nextItem or nextItem.widget ~= entry.metadata.widget or (nextItem.enabled ~= false) ~= entry.metadata.enabled then
            retire(entry)
            configured[id] = nil
        end
    end
    local metadata = {}
    for _, item in items do
        local entry = configured[item.id]
        if not entry then
            entry = { metadata = table.freeze({
                id = item.id, widget = item.widget, title = item.title or item.widget,
                enabled = item.enabled ~= false, status = item.enabled == false and "disabled" or "ready",
                options = item.options or table.freeze({}),
            }) }
            configured[item.id] = entry
            if item.enabled ~= false then
                local ok, definition = pcall(componentHost.requireComponent, item.widget)
                if ok and type(definition) == "table" and type(rawget(definition, "views")) == "table" then
                    entry.definition = definition
                    entry.instance = table.freeze({ id = item.id, widget = item.widget, options = item.options or table.freeze({}),
                        state = {}, provider = table.freeze({ status = "stopped", state = table.freeze({}) }) })
                    componentHost.alive(entry.instance, true, item.provider == true)
                    lifecycle(entry, "init")
                else
                    fail(entry, ok and "component must return a table with views" or definition)
                end
            end
        else
            componentHost.set(entry.metadata, "title", item.title or item.widget)
            componentHost.set(entry.metadata, "options", item.options or table.freeze({}))
            if entry.instance then componentHost.alive(entry.instance, true, item.provider == true) end
            if entry.instance and not equal(entry.instance.options, item.options or {}) then
                local previous = entry.instance.options
                componentHost.set(entry.instance, "options", item.options or table.freeze({}))
                setStatus(entry, "ready", nil)
                lifecycle(entry, "options", previous)
            end
        end
        table.insert(metadata, entry.metadata)
    end
    configuredOrder = metadata
    componentHost.publish(table.freeze(metadata))
end, function(instance, message)
    local entry = configured[instance.id]
    if entry and entry.instance == instance then fail(entry, message) end
end)
local function context(entry, view, root)
    root = root or componentHost.context()
    local states = displays[root]
    if not states then
        states = setmetatable({}, { __mode = "k" })
        displays[root] = states
    end
    local state = states[entry.instance]
    if not state then state = {}; states[entry.instance] = state end
    return table.freeze({ data = root.data, select = root.select, format = root.format,
        state = state, instance = entry.instance, view = view })
end
local function prepareTree(tree, name, ctx)
    local child = table.clone(tree)
    rawset(child, "key", name)
    componentHost.tag(child, ctx)
    return child
end
componentHost.renderer(function(fn, ctx)
    local tree = fn(ctx)
    if tree == nil then return nil end
    assert(type(tree) == "table", "component view must return a ui element or nil")
    return prepareTree(tree, ctx.view.name, ctx)
end)
ui.component = function(props)
    assert(type(props) == "table" and type(props.id) == "string", "ui.component requires an instance id")
    componentHost.context()
    local wrapper = table.clone(props)
    wrapper.kind, wrapper.axis, wrapper.key = 0, 2, props.id
    for index in ipairs(wrapper) do wrapper[index] = nil end
    local entry = configured[props.id]
    if not entry or not entry.instance then return wrapper end
    local name = props.view or "compact"
    local views = rawget(entry.definition, "views")
    local fn = type(views) == "table" and type(name) == "string" and rawget(views, name)
    if type(fn) ~= "function" then fail(entry, "unknown component view"); return wrapper end
    local ok, inputs = pcall(componentHost.props, props.props)
    if not ok then fail(entry, inputs); return wrapper end
    for _, key in { "w", "h" } do
        local value = props[key]
        if value ~= nil and (type(value) ~= "number" or value ~= value or math.abs(value) == math.huge) then
            fail(entry, "component size offers must be finite numbers"); return wrapper
        end
    end
    local ctx = context(entry, table.freeze({ name = name, w = props.w, h = props.h, props = inputs }))
    wrapper[1] = componentHost.mount(fn, ctx)
    return wrapper
end
componentHost.activities(function(root)
    local result = {}
    for _, metadata in configuredOrder do
        local entry = configured[metadata.id]
        local fn = entry and entry.definition and rawget(entry.definition, "activity")
        if entry and entry.instance and fn ~= nil then
            if type(fn) == "function" then
                table.insert(result, { fn, context(entry, nil, root) })
            else
                fail(entry, "activity must be a function")
            end
        end
    end
    return result
end)
omniwm.components.activity = function(id)
    componentHost.context()
    local entry = configured[id]
    if not entry or not entry.instance then return nil end
    return componentHost.activity(entry.instance)
end

local sort = table.sort
local function ascending(a, b)
    return a < b
end
table.sort = function(list, comparator)
    if comparator == nil then
        sort(list, ascending)
    else
        sort(list, comparator)
    end
end
)";

void budgetHook(lua_State *L, int gc);

dispatch_queue_t watchdogQueue() {
    static dispatch_queue_t queue = dispatch_queue_create_with_target(
        "omniwm.script.watchdog",
        DISPATCH_QUEUE_SERIAL,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
    );
    return queue;
}

void watchdogFired(void *context) {
    auto *vm = static_cast<omni_vm *>(context);
    vm->pending.store(true, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    lua_callbacks(vm->main)->interrupt = budgetHook;
}

void armWatchdog(omni_vm *vm, uint64_t afterNanoseconds) {
    dispatch_source_set_timer(
        vm->timer,
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(std::min(afterNanoseconds, maximumArm))),
        DISPATCH_TIME_FOREVER,
        0
    );
}

void disarmWatchdog(omni_vm *vm) {
    dispatch_source_set_timer(vm->timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}

bool registerDataKeys(lua_State *L, omni_detail::ShellPackage &package, const char *keys, size_t length) {
    lua_createtable(L, 0, 64);
    int index = 0;
    size_t start = 0;
    for (size_t i = 0; i <= length; i++) {
        if (i < length && keys[i] != '\n') {
            continue;
        }
        if (i > start) {
            if (index == 64) {
                lua_pop(L, 1);
                return false;
            }
            lua_pushlstring(L, keys + start, i - start);
            lua_pushinteger(L, index);
            lua_rawset(L, -3);
            index++;
        }
        start = i + 1;
    }
    lua_rawgetfield(L, -1, "seconds");
    if (lua_isnumber(L, -1)) {
        package.secondsBit = 1ull << lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
    lua_rawgetfield(L, -1, "components");
    if (lua_isnumber(L, -1)) {
        package.componentsBit = 1ull << lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
    package.dataKeysRef = lua_ref(L, -1);
    lua_pop(L, 1);
    return true;
}

[[noreturn]] void raiseBudget(lua_State *L) {
    luaL_error(L, "script exceeded its CPU budget");
}

void budgetHook(lua_State *L, int gc) {
    if (gc >= 0) {
        return;
    }
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    if (vm == nullptr || !vm->inCall) {
        return;
    }
    if (vm->latched) {
        raiseBudget(L);
    }
    if (!vm->pending.exchange(false, std::memory_order_acq_rel)) {
        return;
    }
    uint64_t used = omni_detail::threadCPU() - vm->callStartCPU;
    if (used > vm->budget) {
        vm->latched = true;
        raiseBudget(L);
    }
    lua_callbacks(L)->interrupt = nullptr;
    std::atomic_thread_fence(std::memory_order_seq_cst);
    armWatchdog(vm, vm->budget - used);
}

void enableLuauFlags() {
    static std::once_flag once;
    std::call_once(once, [] {
        for (Luau::FValue<bool> *flag = Luau::FValue<bool>::list; flag != nullptr; flag = flag->next) {
            if (std::strcmp(flag->name, "LuauTableMoveTimeoutFix") == 0) {
                flag->value = true;
            }
        }
    });
}

void *allocate(void *ud, void *ptr, size_t oldSize, size_t newSize) {
    auto *vm = static_cast<omni_vm *>(ud);
    if (newSize == 0) {
        std::free(ptr);
        vm->used -= oldSize;
        return nullptr;
    }
    if (newSize > oldSize && vm->used - oldSize + newSize > vm->limit) {
        return nullptr;
    }
    void *result = std::realloc(ptr, newSize);
    if (result != nullptr) {
        vm->used = vm->used - oldSize + newSize;
    }
    return result;
}

struct FreeDeleter {
    void operator()(char *pointer) const { std::free(pointer); }
};

bool runPrelude(lua_State *L) {
    size_t bytecodeSize = 0;
    std::unique_ptr<char, FreeDeleter> bytecode(luau_compile(prelude, sizeof prelude - 1, nullptr, &bytecodeSize));
    if (!bytecode || luau_load(L, "=prelude", bytecode.get(), bytecodeSize, 0) != 0) {
        return false;
    }
    return lua_pcall(L, 0, 0, 0) == LUA_OK;
}

}

namespace omni_detail {

lua_CompileOptions scriptCompileOptions() {
    static const char *const mutableGlobals[] = {"omniwm", nullptr};
    lua_CompileOptions options{};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    options.mutableGlobals = mutableGlobals;
    return options;
}

uint64_t threadCPU() noexcept {
    return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
}

void copyMessage(const char *message, char *error, size_t capacity) {
    if (error == nullptr || capacity == 0) {
        return;
    }
    std::strncpy(error, message != nullptr ? message : "(no message)", capacity - 1);
    error[capacity - 1] = '\0';
}

void copyValueMessage(lua_State *L, int index, char *error, size_t capacity) {
    switch (lua_type(L, index)) {
    case LUA_TSTRING:
        copyMessage(lua_tostring(L, index), error, capacity);
        break;
    case LUA_TNUMBER: {
        char buffer[64];
        std::snprintf(buffer, sizeof buffer, "%.17g", lua_tonumber(L, index));
        copyMessage(buffer, error, capacity);
        break;
    }
    default:
        copyMessage("(non-string error)", error, capacity);
        break;
    }
}

CallScope::CallScope(omni_vm *vm, uint64_t budget) : vm(vm) {
    uint64_t start = threadCPU();
    vm->pending.store(false, std::memory_order_release);
    lua_callbacks(vm->main)->interrupt = nullptr;
    if (budget != 0) {
        armWatchdog(vm, budget);
    }
    vm->latched = false;
    vm->budget = budget == 0 ? unboundedBudget : budget;
    vm->callStartCPU = start;
    vm->inCall = true;
}

CallScope::~CallScope() {
    disarmWatchdog(vm);
    vm->lastCallCPU = threadCPU() - vm->callStartCPU;
    vm->inCall = false;
    vm->pending.store(false, std::memory_order_release);
    lua_callbacks(vm->main)->interrupt = nullptr;
}

omni_status enforceBudget(omni_vm *vm, omni_status status, char *error, size_t capacity) {
    if (status != OMNI_OK || vm->lastCallCPU <= vm->budget) {
        return status;
    }
    copyMessage("script exceeded its CPU budget", error, capacity);
    return OMNI_ERR_TIMEOUT;
}

omni_status finish(omni_vm *vm, lua_State *L, int status, char *error, size_t capacity) {
    if (vm->latched) {
        copyValueMessage(L, -1, error, capacity);
        lua_settop(L, 0);
        return OMNI_ERR_TIMEOUT;
    }
    if (status == LUA_OK) {
        return OMNI_OK;
    }
    copyValueMessage(L, -1, error, capacity);
    lua_settop(L, 0);
    if (status == LUA_ERRMEM) {
        lua_gc(vm->main, LUA_GCCOLLECT, 0);
        return OMNI_ERR_MEMORY;
    }
    return OMNI_ERR_RUNTIME;
}

}

using namespace omni_detail;

omni_vm *omni_vm_create(size_t memory_limit_bytes, const char *data_keys, size_t data_keys_length) noexcept {
    std::unique_ptr<omni_vm> owned;
    try {
        enableLuauFlags();
        owned = std::make_unique<omni_vm>();
        owned->limit = memory_limit_bytes;
        owned->main = lua_newstate(allocate, owned.get());
        if (owned->main == nullptr) {
            return nullptr;
        }
        lua_State *L = owned->main;
        lua_callbacks(L)->userdata = owned.get();
        lua_callbacks(L)->useratom = shellAtom;
        luaL_openlibs(L);
        if (!registerDataKeys(L, owned->package, data_keys, data_keys_length)) {
            throw std::bad_alloc();
        }
        markTimeReads(L);
        installComponentHost(L, owned->package);
        if (!runPrelude(L)) {
            throw std::bad_alloc();
        }
        lua_getfield(L, LUA_GLOBALSINDEX, "ui");
        lua_pushcfunction(L, popoutAction, "popout");
        lua_setfield(L, -2, "popout");
        lua_pop(L, 1);
        lua_pushcfunction(L, encodeEntry, "encode");
        owned->package.encodeRef = lua_ref(L, -1);
        lua_pop(L, 1);
        lua_getglobal(L, "omniwm");
        lua_pushcfunction(L, runRequest, "run");
        lua_setfield(L, -2, "run");
        lua_pushcfunction(L, logMessage, "log");
        lua_setfield(L, -2, "log");
        lua_pushcfunction(L, localizeMessage, "l10n");
        lua_setfield(L, -2, "l10n");
        lua_pushcfunction(L, assetReference, "asset");
        lua_setfield(L, -2, "asset");
        lua_setglobal(L, "omniwm");
        installFormat(L, owned->package);
        lua_pushcfunction(L, logMessage, "print");
        lua_setglobal(L, "print");
        lua_pushcfunction(L, requireModule, "require");
        lua_setglobal(L, "require");
        lua_newtable(L);
        owned->package.modulesRef = lua_ref(L, -1);
        lua_pop(L, 1);
        installJSON(L);
        installServices(L, owned->package);
        luaL_sandbox(L);
        owned->thread = lua_newthread(L);
        luaL_sandboxthread(owned->thread);
        owned->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, watchdogQueue());
        if (owned->timer == nullptr) {
            throw std::bad_alloc();
        }
        dispatch_set_context(owned->timer, owned.get());
        dispatch_source_set_event_handler_f(owned->timer, watchdogFired);
        disarmWatchdog(owned.get());
        dispatch_activate(owned->timer);
        return owned.release();
    } catch (...) {
        if (owned && owned->main != nullptr) {
            try {
                lua_close(owned->main);
            } catch (...) {
            }
        }
        if (owned) { destroyServices(owned.get()); }
        return nullptr;
    }
}

template <typename Value, typename Read>
static omni_status readGlobal(omni_vm *vm, const char *name, int type, Value *out, Read read) noexcept {
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    try {
        lua_State *L = vm->thread;
        lua_rawgetfield(L, LUA_GLOBALSINDEX, name);
        bool matches = lua_type(L, -1) == type;
        if (matches) {
            *out = read(L);
        }
        lua_pop(L, 1);
        return matches ? OMNI_OK : OMNI_ERR_RUNTIME;
    } catch (...) {
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_global_number(omni_vm *vm, const char *name, double *out) noexcept {
    return readGlobal(vm, name, LUA_TNUMBER, out, [](lua_State *L) { return lua_tonumber(L, -1); });
}

omni_status omni_vm_global_boolean(omni_vm *vm, const char *name, bool *out) noexcept {
    return readGlobal(vm, name, LUA_TBOOLEAN, out, [](lua_State *L) { return lua_toboolean(L, -1) != 0; });
}

omni_status omni_vm_global_function(omni_vm *vm, const char *name) noexcept {
    bool present = false;
    return readGlobal(vm, name, LUA_TFUNCTION, &present, [](lua_State *) { return true; });
}

omni_status omni_vm_add_module(omni_vm *vm, const char *path, size_t path_length, const char *source, size_t source_length) noexcept {
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    try {
        std::string key(path, path_length);
        if (vm->package.modules.count(key) == 0 && vm->package.modules.size() >= vm->package.moduleLimit) {
            return OMNI_ERR_MEMORY;
        }
        vm->package.modules[key] = std::string(source, source_length);
        return OMNI_OK;
    } catch (...) {
        return OMNI_ERR_MEMORY;
    }
}

omni_status omni_vm_set_module_limit(omni_vm *vm, size_t limit) noexcept {
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (limit == 0 || limit > 512 || limit < vm->package.modules.size()) { return OMNI_ERR_RUNTIME; }
    vm->package.moduleLimit = limit;
    return OMNI_OK;
}

bool omni_vm_module_matches(const omni_vm *vm, const char *path, size_t path_length, const char *source, size_t source_length) noexcept {
    if (vm->inCall) {
        return false;
    }
    try {
        auto found = vm->package.modules.find(std::string(path, path_length));
        return found != vm->package.modules.end() && found->second.size() == source_length
            && (source_length == 0 || std::memcmp(found->second.data(), source, source_length) == 0);
    } catch (...) {
        return false;
    }
}

void omni_vm_set_localizer(omni_vm *vm, omni_localizer localizer, void *context) noexcept {
    vm->localizer = localizer;
    vm->localizerContext = context;
}

void omni_vm_set_formatter(omni_vm *vm, omni_formatter formatter, void *context) noexcept {
    vm->formatter = formatter;
    vm->formatterContext = context;
}

omni_status omni_vm_destroy(omni_vm *vm) noexcept {
    if (vm == nullptr) {
        return OMNI_OK;
    }
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    dispatch_source_cancel(vm->timer);
    dispatch_sync_f(watchdogQueue(), nullptr, [](void *) {});
    dispatch_release(vm->timer);
    try {
        lua_close(vm->main);
    } catch (...) {
    }
    destroyServices(vm);
    delete vm;
    return OMNI_OK;
}

omni_status omni_vm_load(omni_vm *vm, const char *chunk_name, const char *source, size_t source_length, uint64_t budget_ns, char *error, size_t error_capacity) noexcept {
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    try {
        size_t bytecodeSize = 0;
        lua_CompileOptions options = scriptCompileOptions();
        std::unique_ptr<char, FreeDeleter> bytecode(luau_compile(source, source_length, &options, &bytecodeSize));
        if (!bytecode) {
            copyMessage("compiler allocation failed", error, error_capacity);
            return OMNI_ERR_MEMORY;
        }
        lua_State *L = vm->thread;
        lua_settop(L, 0);
        vm->package.rootSource = chunk_name != nullptr && chunk_name[0] == '@' ? chunk_name + 1 : "";
        if (vm->loads > 0) {
            lua_setsafeenv(L, LUA_GLOBALSINDEX, false);
        }
        if (luau_load(L, chunk_name, bytecode.get(), bytecodeSize, 0) != 0) {
            copyValueMessage(L, -1, error, error_capacity);
            lua_settop(L, 0);
            return bytecodeSize > 0 && bytecode.get()[0] == 0 ? OMNI_ERR_COMPILE : OMNI_ERR_MEMORY;
        }
        vm->loads++;
        omni_status status;
        {
            CallScope scope(vm, budget_ns);
            status = finish(vm, L, lua_pcall(L, 0, 0, 0), error, error_capacity);
        }
        return enforceBudget(vm, status, error, error_capacity);
    } catch (...) {
        copyMessage("unexpected exception", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

void omni_vm_collect(omni_vm *vm) noexcept {
    try {
        lua_gc(vm->main, LUA_GCCOLLECT, 0);
    } catch (...) {
    }
}

size_t omni_vm_bytes_in_use(const omni_vm *vm) noexcept {
    return vm->used;
}
