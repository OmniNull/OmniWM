// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptModules.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string_view>

namespace {

using namespace omni_detail;

constexpr int actionTag = 1;
constexpr size_t maximumRuleFields = 14;
constexpr size_t maximumDestinationFields = 8;
std::atomic<uint64_t> liveVMs{0};
std::atomic<uint64_t> vmEntries{0};

struct Callback {
    int ref;
    omni_config_location declaration;
    bool event;
    bool timer;
    uint16_t reads;
};

struct ConfigVM : ModuleRuntime {
    omni_config_callbacks callbacks;
    std::vector<Callback> functions;
    std::vector<omni_config_timer> configuredTimers;
    uint32_t cancelledTimers = 0;
    unsigned commands = 0;
    unsigned logs = 0;
    unsigned actions = 0;
    unsigned bindings = 0;
    unsigned rules = 0;

    ConfigVM(const omni_config_callbacks &callbacks, void *context)
        : ModuleRuntime(callbacks.read_module, context, trackConfigMetrics ? &vmEntries : nullptr), callbacks(callbacks) {}
    ~ConfigVM() {
        if (main != nullptr) {
            closeRuntime(*this);
            liveVMs.fetch_sub(1, std::memory_order_relaxed);
        }
    }
};

ConfigVM &declarations(lua_State *L) {
    auto &vm = *static_cast<ConfigVM *>(static_cast<ModuleRuntime *>(lua_callbacks(L)->userdata));
    if (vm.rejected) {
        luaL_error(L, "%s", vm.failure);
    }
    return vm;
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

struct CallbackOptions {
    omni_config_span modeKey{};
    uint16_t reads = 0;
};

constexpr std::array readNames{"workspaceWindows", "windows", "workspaces", "monitors", "placement", "focusTarget"};
constexpr std::array<uint8_t, 6> readBits{
    OMNI_CONFIG_READ_WORKSPACE_WINDOWS, OMNI_CONFIG_READ_WINDOWS, OMNI_CONFIG_READ_WORKSPACES, OMNI_CONFIG_READ_MONITORS,
    OMNI_CONFIG_READ_PLACEMENT, OMNI_CONFIG_READ_FOCUS_TARGET
};
constexpr std::string_view framesRead = "frames";
constexpr uint16_t framedLists = OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS | OMNI_CONFIG_READ_MONITORS;
static_assert((framedLists << OMNI_CONFIG_READ_FRAME_SHIFT) ==
    (OMNI_CONFIG_READ_WORKSPACE_WINDOW_FRAMES | OMNI_CONFIG_READ_WINDOW_FRAMES | OMNI_CONFIG_READ_MONITOR_FRAMES));
static_assert(OMNI_CONFIG_READ_LISTS == (OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS |
    OMNI_CONFIG_READ_WORKSPACES | OMNI_CONFIG_READ_MONITORS | OMNI_CONFIG_READ_PLACEMENT | OMNI_CONFIG_READ_FOCUS_TARGET));

uint16_t readMask(lua_State *L, ConfigVM &vm, omni_config_location site) {
    if (!lua_istable(L, -1)) {
        reject(L, vm, site, "reads expects an array of lookup names");
    }
    const int table = lua_gettop(L);
    const int length = lua_objlen(L, table);
    if (length > static_cast<int>(readNames.size()) + 1) {
        reject(L, vm, site, "too many lookup names in reads");
    }
    uint16_t mask = 0;
    bool frames = false;
    int count = 0;
    lua_pushnil(L);
    while (lua_next(L, table)) {
        const double index = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(index >= 1 && index <= length && index == static_cast<int>(index))) {
            reject(L, vm, site, "reads expects consecutive array indices");
        }
        auto word = token(L, vm, -1, site);
        const std::string_view name(word.data, word.length);
        const bool framesName = name == framesRead;
        auto it = std::find(readNames.begin(), readNames.end(), name);
        if (it == readNames.end() && !framesName) {
            reject(L, vm, site, "unknown read; expected workspaceWindows, windows, workspaces, monitors, placement, focusTarget or frames");
        }
        const uint16_t bit = framesName ? 0 : readBits[it - readNames.begin()];
        if (framesName ? frames : (mask & bit) != 0) {
            reject(L, vm, site, "duplicate lookup name in reads");
        }
        frames |= framesName;
        mask |= bit;
        ++count;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "reads expects consecutive array indices");
    }
    if (frames) {
        const uint16_t framed = mask & framedLists;
        if (!framed) {
            reject(L, vm, site, "frames needs workspaceWindows, windows or monitors in the same reads");
        }
        mask |= framed << OMNI_CONFIG_READ_FRAME_SHIFT;
    }
    return mask;
}

CallbackOptions callbackOptions(lua_State *L, ConfigVM &vm, omni_config_location site, bool binding, bool function) {
    CallbackOptions options;
    if (lua_isnoneornil(L, 3)) {
        return options;
    }
    if (!lua_istable(L, 3)) {
        reject(L, vm, site, "callback options must be a table");
    }
    lua_pushnil(L);
    while (lua_next(L, 3)) {
        auto span = token(L, vm, -2, site);
        std::string_view key(span.data, span.length);
        if (binding && key == "modeKey") {
            options.modeKey = token(L, vm, -1, site);
        } else if (function && key == "reads") {
            options.reads = readMask(L, vm, site);
        } else {
            reject(L, vm, site, binding ? "unknown keymap.set option; expected modeKey or reads on a function" :
                "unknown callback option; expected reads");
        }
        lua_pop(L, 1);
    }
    return options;
}

uint32_t registerFunction(lua_State *L, ConfigVM &vm, omni_config_location site, uint16_t reads, bool event = false, bool timer = false) {
    if (vm.functions.size() == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config function limit exceeded");
    }
    uint32_t id = static_cast<uint32_t>(vm.functions.size());
    vm.functions.push_back({lua_ref(L, 2), site, event, timer, reads});
    return id;
}

int cancelTimer(lua_State *L) {
    auto &vm = declarations(L);
    if (lua_gettop(L) != 0) {
        reject(L, vm, declarationSite(L, vm), "timer.cancel expects no arguments");
    }
    vm.cancelledTimers |= uint32_t(1) << lua_tointeger(L, lua_upvalueindex(1));
    return 0;
}

int addTimer(lua_State *L) {
    auto &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (vm.invoking) {
        reject(L, vm, site, "omniwm.timer is only available while loading the config");
    }
    if (lua_gettop(L) < 2 || lua_gettop(L) > 3 || !lua_istable(L, 1) || !lua_isfunction(L, 2)) {
        reject(L, vm, site, "omniwm.timer expects an interval table and a function");
    }
    static_assert(OMNI_CONFIG_TIMER_LIMIT <= sizeof(vm.cancelledTimers) * 8);
    if (vm.configuredTimers.size() >= OMNI_CONFIG_TIMER_LIMIT) {
        reject(L, vm, site, "timer limit exceeded");
    }
    lua_pushnil(L);
    if (!lua_next(L, 1)) {
        reject(L, vm, site, "a timer needs afterSeconds or everySeconds");
    }
    auto key = token(L, vm, -2, site);
    std::string_view name(key.data, key.length);
    bool repeats = name == "everySeconds";
    if ((!repeats && name != "afterSeconds") || lua_type(L, -1) != LUA_TNUMBER) {
        reject(L, vm, site, "a timer needs numeric afterSeconds or everySeconds");
    }
    double seconds = lua_tonumber(L, -1);
    if (!std::isfinite(seconds) || seconds < OMNI_CONFIG_TIMER_MINIMUM_SECONDS ||
        seconds > static_cast<double>(INT64_MAX / 1000000000)) {
        std::snprintf(vm.failure, sizeof vm.failure, "timer interval must be at least %u second and fit in signed nanoseconds",
            OMNI_CONFIG_TIMER_MINIMUM_SECONDS);
        reject(L, vm, site, vm.failure);
    }
    lua_pop(L, 1);
    if (lua_next(L, 1)) {
        reject(L, vm, site, "a timer accepts only one interval");
    }
    auto index = static_cast<int>(vm.configuredTimers.size());
    const auto options = callbackOptions(L, vm, site, false, true);
    if (!lua_isnoneornil(L, 3) && !options.reads) {
        reject(L, vm, site, "timer callback options must declare at least one read");
    }
    vm.configuredTimers.push_back({registerFunction(L, vm, site, options.reads, false, true), repeats, seconds, options.reads});
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, index);
    lua_pushcclosure(L, cancelTimer, "cancel", 1);
    lua_setfield(L, -2, "cancel");
    lua_setreadonly(L, -1, true);
    return 1;
}

template<bool event>
int namedFunction(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (vm.invoking) {
        reject(L, vm, site, event ? "omniwm.on is only available while loading the config" :
            "omniwm.command is only available while loading the config");
    }
    if (!vm.callbacks.named_function || lua_gettop(L) < 2 || lua_gettop(L) > 3 || !lua_isfunction(L, 2)) {
        reject(L, vm, site, event ? "omniwm.on expects an event name and a function" :
            "omniwm.command expects a name and a function");
    }
    auto name = token(L, vm, 1, site);
    const auto options = callbackOptions(L, vm, site, false, true);
    uint32_t id = registerFunction(L, vm, site, options.reads, event);
    if (!vm.callbacks.named_function(vm.context, event, name, id, options.reads, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid named function");
    }
    return 0;
}

int bindKey(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    const int count = lua_gettop(L);
    if (vm.invoking) {
        reject(L, vm, site, "keymap.set is only available while loading the config");
    }
    if (count < 2 || count > 3 || (!lua_isnoneornil(L, 3) && !lua_istable(L, 3))) {
        reject(L, vm, site, "keymap.set expects a chord, a command or function, and an optional table");
    }
    if (vm.bindings == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config binding limit exceeded");
    }
    omni_config_span chord = token(L, vm, 1, site);
    const auto *action = static_cast<const uint32_t *>(lua_touserdatatagged(L, 2, actionTag));
    const bool function = lua_isfunction(L, 2) && vm.callbacks.bind_function;
    if (action == nullptr && !function) {
        reject(L, vm, site, "expected a function or an action from omniwm.cmd or omniwm.act");
    }
    const auto options = callbackOptions(L, vm, site, true, function);
    bool bound = function
        ? vm.callbacks.bind_function(vm.context, chord, registerFunction(L, vm, site, options.reads),
            options.modeKey, options.reads, site, vm.failure, sizeof vm.failure)
        : vm.callbacks.bind(vm.context, chord, *action, options.modeKey, site, vm.failure, sizeof vm.failure);
    if (!bound) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid binding");
    }
    vm.bindings++;
    return 0;
}

struct FieldMessages {
    const char *tooMany;
    const char *badValue;
};

size_t readFields(lua_State *L, ConfigVM &vm, int index, omni_config_location site, omni_config_field *fields,
    size_t capacity, FieldMessages messages) {
    size_t count = 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (count == capacity) {
            reject(L, vm, site, messages.tooMany);
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
            reject(L, vm, site, messages.badValue);
        }
        fields[count++] = field;
        lua_pop(L, 1);
    }
    return count;
}

int addRule(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (vm.invoking) {
        reject(L, vm, site, "omniwm.rule is only available while loading the config");
    }
    if (!vm.callbacks.rule || lua_gettop(L) != 1 || !lua_istable(L, 1)) {
        reject(L, vm, site, "omniwm.rule expects one table of rule fields");
    }
    if (vm.rules == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config rule limit exceeded");
    }
    std::array<omni_config_field, maximumRuleFields> fields;
    const size_t count = readFields(L, vm, 1, site, fields.data(), fields.size(),
        {"too many fields in rule", "rule fields must be strings, numbers or booleans"});
    if (!vm.callbacks.rule(vm.context, fields.data(), count, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid rule");
    }
    vm.rules++;
    return 0;
}

int dispatchAction(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (!vm.invoking || !vm.callbacks.dispatch) {
        reject(L, vm, site, "omniwm.dispatch is only available in a callback");
    }
    if (vm.commands == OMNI_CONFIG_COMMAND_LIMIT) {
        reject(L, vm, site, "callback command limit exceeded");
    }
    bool staged = false;
    if (lua_type(L, 1) == LUA_TSTRING) {
        const auto prefix = token(L, vm, 1, site);
        const int top = lua_gettop(L);
        const bool tableDestination = top == 4 && lua_istable(L, 4);
        const int count = top - 1 - (tableDestination ? 1 : 0);
        std::array<omni_config_span, LUA_MINSTACK> words;
        if (!vm.callbacks.window || std::string_view(prefix.data, prefix.length) != "window" ||
            count < 2 || static_cast<size_t>(count) > words.size()) {
            reject(L, vm, site, "omniwm.dispatch expects 'window', an action, a window ID and any action arguments");
        }
        for (int i = 0; i < count; i++) {
            words[i] = token(L, vm, i + 2, site);
        }
        std::array<omni_config_field, maximumDestinationFields> destination;
        const size_t fields = tableDestination
            ? readFields(L, vm, 4, site, destination.data(), destination.size(),
                {"too many fields in a window table",
                    "window table fields must be strings, numbers or booleans"})
            : 0;
        staged = vm.callbacks.window(vm.context, words.data(), count, tableDestination ? destination.data() : nullptr,
            fields, site, vm.failure, sizeof vm.failure);
    } else {
        const auto *action = static_cast<const uint32_t *>(lua_touserdatatagged(L, 1, actionTag));
        if (lua_gettop(L) != 1 || !action) {
            reject(L, vm, site, "omniwm.dispatch expects one native action");
        }
        staged = vm.callbacks.dispatch(vm.context, *action, site, vm.failure, sizeof vm.failure);
    }
    if (!staged) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid callback action");
    }
    vm.commands++;
    return 0;
}

size_t readArguments(lua_State *L, ConfigVM &vm, omni_config_location site, omni_config_span *words) {
    if (!lua_istable(L, 1)) {
        reject(L, vm, site, "run expects an array of strings");
    }
    const int length = lua_objlen(L, 1);
    if (length < 1 || length > static_cast<int>(OMNI_CONFIG_ARGC_LIMIT)) {
        reject(L, vm, site, "run needs an executable and a bounded number of arguments");
    }
    int count = 0;
    size_t bytes = 0;
    lua_pushnil(L);
    while (lua_next(L, 1)) {
        double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(key >= 1 && key <= length && key == static_cast<int>(key))) {
            reject(L, vm, site, "run expects consecutive array indices starting at one");
        }
        auto value = token(L, vm, -1, site);
        if (value.length > OMNI_CONFIG_ARG_BYTE_LIMIT || value.length > OMNI_CONFIG_ARGV_BYTE_LIMIT - bytes ||
            std::memchr(value.data, 0, value.length)) {
            reject(L, vm, site, "run arguments exceed the byte limit or contain a NUL");
        }
        words[static_cast<int>(key) - 1] = value;
        bytes += value.length;
        count++;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "run expects an array without holes");
    }
    const std::string_view executable(words[0].data, words[0].length);
    if (executable.empty() || (executable.front() != '/' && executable.find('/') != executable.npos)) {
        reject(L, vm, site, "run needs an absolute executable path or a bare program name");
    }
    return static_cast<size_t>(count);
}

template<omni_config_effect_kind kind, bool build>
int nativeEffect(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if constexpr (!build) {
        if (!vm.invoking) {
            constexpr const char *guide = kind == OMNI_CONFIG_OPEN_APP ? "during config load, use omniwm.act.open to build an action" :
                kind == OMNI_CONFIG_RUN_PROGRAM ? "during config load, use omniwm.act.run to build an action" :
                "during config load, use omniwm.act.notify to build an action";
            reject(L, vm, site, guide);
        }
    }
    if (!vm.callbacks.effect || lua_gettop(L) != 1) {
        reject(L, vm, site, "expected one argument to the action");
    }
    if (build ? vm.actions == OMNI_CONFIG_DECLARATION_LIMIT : vm.commands == OMNI_CONFIG_COMMAND_LIMIT) {
        reject(L, vm, site, build ? "config action limit exceeded" : "callback command limit exceeded");
    }
    std::array<omni_config_span, kind == OMNI_CONFIG_RUN_PROGRAM ? OMNI_CONFIG_ARGC_LIMIT : 1> words;
    size_t count = 1;
    if constexpr (kind == OMNI_CONFIG_RUN_PROGRAM) {
        count = readArguments(L, vm, site, words.data());
    } else {
        constexpr size_t limit = kind == OMNI_CONFIG_OPEN_APP ? OMNI_CONFIG_BUNDLE_BYTE_LIMIT : OMNI_CONFIG_NOTICE_BYTE_LIMIT;
        const auto word = token(L, vm, 1, site);
        if (!word.length || word.length > limit || std::memchr(word.data, 0, word.length)) {
            reject(L, vm, site, kind == OMNI_CONFIG_OPEN_APP ? "invalid or overlong bundle ID" : "invalid or overlong notice text");
        }
        words[0] = word;
    }
    auto *action = build ? static_cast<uint32_t *>(lua_newuserdatatagged(L, sizeof(uint32_t), actionTag)) : nullptr;
    if (!vm.callbacks.effect(vm.context, kind, words.data(), count, site, action, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid action");
    }
    if constexpr (build) {
        vm.actions++;
        return 1;
    } else {
        vm.commands++;
        return 0;
    }
}

int writeConfigLog(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (!vm.callbacks.log || vm.logs >= OMNI_CONFIG_COMMAND_LIMIT) {
        reject(L, vm, site, "config log limit exceeded");
    }
    vm.logs++;
    std::array<char, OMNI_CONFIG_ERROR_CAPACITY> message;
    size_t size = 0;
    int count = lua_gettop(L);
    for (int i = 1; i <= count; i++) {
        if (i > 1) {
            if (size == message.size()) {
                reject(L, vm, site, "config log message is too long");
            }
            message[size++] = '\t';
        }
        size_t length;
        const char *value = luaL_tolstring(L, i, &length);
        if (length > message.size() - size) {
            reject(L, vm, site, "config log message is too long");
        }
        std::memcpy(message.data() + size, value, length);
        size += length;
        lua_pop(L, 1);
    }
    vm.callbacks.log(vm.context, {message.data(), size}, site);
    return 0;
}

template<bool build>
void installEffectFunctions(lua_State *L) {
    lua_pushcfunction(L, (nativeEffect<OMNI_CONFIG_OPEN_APP, build>), "open");
    lua_setfield(L, -2, "open");
    lua_pushcfunction(L, (nativeEffect<OMNI_CONFIG_RUN_PROGRAM, build>), "run");
    lua_setfield(L, -2, "run");
    lua_pushcfunction(L, (nativeEffect<OMNI_CONFIG_SHOW_NOTICE, build>), "notify");
    lua_setfield(L, -2, "notify");
}

void installConfig(lua_State *L) {
    for (lua_CFunction open : {luaopen_base, luaopen_table, luaopen_string, luaopen_math, luaopen_bit32, luaopen_utf8, luaopen_os}) {
        lua_pushcfunction(L, open, nullptr);
        lua_call(L, 0, 0);
    }
    for (const char *name : {"print", "getfenv", "setfenv"}) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    lua_pushcfunction(L, requireConfigModule, "require");
    lua_setglobal(L, "require");
    lua_createtable(L, 0, 12);
    lua_pushcfunction(L, addTimer, "timer");
    lua_setfield(L, -2, "timer");
    lua_pushcfunction(L, command, "cmd");
    lua_setfield(L, -2, "cmd");
    lua_pushcfunction(L, namedFunction<false>, "command");
    lua_setfield(L, -2, "command");
    lua_pushcfunction(L, namedFunction<true>, "on");
    lua_setfield(L, -2, "on");
    installEffectFunctions<false>(L);
    lua_createtable(L, 0, 3);
    installEffectFunctions<true>(L);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "act");
    lua_pushcfunction(L, addRule, "rule");
    lua_setfield(L, -2, "rule");
    lua_pushcfunction(L, dispatchAction, "dispatch");
    lua_setfield(L, -2, "dispatch");
    lua_pushcfunction(L, writeConfigLog, "log");
    lua_setfield(L, -2, "log");
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, bindKey, "set");
    lua_setfield(L, -2, "set");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "keymap");
    lua_setreadonly(L, -1, true);
    lua_setglobal(L, "omniwm");
}

omni_status resumeConfig(ConfigVM &vm, int arguments, uint64_t budget, char *error, size_t capacity) {
    lua_State *L = vm.thread;
    omni_status status;
    {
        CallScope scope(&vm, budget);
        vm.recordEntry();
        int result = lua_resume(L, nullptr, arguments);
        status = finishModuleCall(vm, L, result, error, capacity);
    }
    return enforceBudget(&vm, status, error, capacity);
}

void setRect(lua_State *L, const char *key, const omni_config_rect &rect) {
    if (!rect.present) return;
    lua_createtable(L, 0, 4);
    lua_pushnumber(L, rect.x);
    lua_rawsetfield(L, -2, "x");
    lua_pushnumber(L, rect.y);
    lua_rawsetfield(L, -2, "y");
    lua_pushnumber(L, rect.width);
    lua_rawsetfield(L, -2, "width");
    lua_pushnumber(L, rect.height);
    lua_rawsetfield(L, -2, "height");
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, key);
}

struct InvalidSnapshot {};

std::string_view takeBytes(std::string_view &input, size_t length) {
    if (length > input.size()) {
        throw InvalidSnapshot{};
    }
    auto result = input.substr(0, length);
    input.remove_prefix(length);
    return result;
}

template<typename T> T readUnsigned(std::string_view &input) {
    const auto bytes = takeBytes(input, sizeof(T));
    T value = 0;
    for (size_t i = 0; i < sizeof(T); ++i) {
        value |= static_cast<T>(static_cast<uint8_t>(bytes[i])) << (8 * i);
    }
    return value;
}

void readStringField(lua_State *L, std::string_view &rows, const char *name) {
    const auto length = readUnsigned<uint32_t>(rows);
    if (length != UINT32_MAX) {
        const auto text = takeBytes(rows, length);
        lua_pushlstring(L, text.data(), text.size());
        lua_rawsetfield(L, -2, name);
    }
}

double readDouble(std::string_view &rows) {
    const auto bits = readUnsigned<uint64_t>(rows);
    double value;
    std::memcpy(&value, &bits, sizeof value);
    return value;
}

constexpr size_t rectBytes = sizeof(double[4]);

void readRectField(lua_State *L, std::string_view &rows, const char *name, bool pushes) {
    if (!pushes) {
        takeBytes(rows, rectBytes);
        return;
    }
    omni_config_rect rect{};
    rect.x = readDouble(rows);
    rect.y = readDouble(rows);
    rect.width = readDouble(rows);
    rect.height = readDouble(rows);
    rect.present = true;
    setRect(L, name, rect);
}

void pushLookupRow(lua_State *L, std::string_view &rows, uint8_t kind, bool framed, bool pushesFrames) {
    const bool window = kind == OMNI_CONFIG_READ_WORKSPACE_WINDOWS || kind == OMNI_CONFIG_READ_WINDOWS;
    lua_createtable(L, 0, window ? 8 : kind == OMNI_CONFIG_READ_WORKSPACES ? 3 : 2 + 2 * pushesFrames);
    readStringField(L, rows, "id");
    if (window) {
        readStringField(L, rows, "bundleId");
        readStringField(L, rows, "title");
        readStringField(L, rows, "workspace");
        readStringField(L, rows, "monitor");
        const auto flags = readUnsigned<uint8_t>(rows);
        lua_pushboolean(L, flags & OMNI_CONFIG_WINDOW_FLOATING);
        lua_rawsetfield(L, -2, "floating");
        if (flags & OMNI_CONFIG_WINDOW_FULLSCREEN) {
            lua_pushstring(L, flags & OMNI_CONFIG_WINDOW_NATIVE_FULLSCREEN ? "native" : "omniwm");
            lua_rawsetfield(L, -2, "fullscreen");
        }
        lua_pushboolean(L, flags & OMNI_CONFIG_WINDOW_MINIMIZED);
        lua_rawsetfield(L, -2, "minimized");
        if (framed && readUnsigned<uint8_t>(rows) == OMNI_CONFIG_FRAME_PRESENT) {
            readRectField(L, rows, "frame", pushesFrames);
        }
    } else {
        readStringField(L, rows, "name");
        if (kind == OMNI_CONFIG_READ_WORKSPACES) {
            readStringField(L, rows, "monitor");
        } else if (framed) {
            readRectField(L, rows, "frame", pushesFrames);
            readRectField(L, rows, "visibleFrame", pushesFrames);
        }
    }
    lua_setreadonly(L, -1, true);
}

void pushPlacement(lua_State *L, std::string_view &rows) {
    lua_createtable(L, 0, 6);
    readStringField(L, rows, "workspace");
    readStringField(L, rows, "display");
    const auto flags = readUnsigned<uint8_t>(rows);
    if (flags & OMNI_CONFIG_PLACEMENT_COLUMN) {
        lua_pushnumber(L, readUnsigned<uint16_t>(rows));
        lua_rawsetfield(L, -2, "column");
        lua_pushnumber(L, readUnsigned<uint16_t>(rows));
        lua_rawsetfield(L, -2, "columns");
        const auto members = readUnsigned<uint16_t>(rows);
        lua_createtable(L, members, 0);
        for (int member = 1; member <= members; ++member) {
            const auto id = takeBytes(rows, readUnsigned<uint32_t>(rows));
            lua_pushlstring(L, id.data(), id.size());
            lua_rawseti(L, -2, member);
        }
        lua_setreadonly(L, -1, true);
        lua_rawsetfield(L, -2, "members");
        lua_pushboolean(L, flags & OMNI_CONFIG_PLACEMENT_VERTICAL);
        lua_rawsetfield(L, -2, "vertical");
    }
    lua_setreadonly(L, -1, true);
}

void pushFocusTarget(lua_State *L, std::string_view &rows) {
    lua_createtable(L, 0, 2);
    readStringField(L, rows, "id");
    lua_pushboolean(L, readUnsigned<uint8_t>(rows) & OMNI_CONFIG_FOCUS_TARGET_NATIVE_FULLSCREEN);
    lua_rawsetfield(L, -2, "nativeFullscreen");
    lua_setreadonly(L, -1, true);
}

void pushLookups(lua_State *L, omni_config_span snapshot, uint16_t reads) {
    if (!snapshot.data) {
        throw InvalidSnapshot{};
    }
    const int context = lua_gettop(L);
    const auto fieldCount = __builtin_popcount(reads & OMNI_CONFIG_READ_LISTS);
    lua_createtable(L, 0, fieldCount);
    std::string_view input(snapshot.data, snapshot.length);
    while (!input.empty()) {
        const auto kind = readUnsigned<uint8_t>(input);
        const auto flags = readUnsigned<uint8_t>(input);
        const auto count = readUnsigned<uint16_t>(input);
        const auto length = readUnsigned<uint32_t>(input);
        auto rows = takeBytes(input, length);
        if (!(kind & reads)) {
            continue;
        }
        const auto bit = std::find(readBits.begin(), readBits.end(), kind);
        if (bit == readBits.end()) {
            throw InvalidSnapshot{};
        }
        reads &= ~kind;
        const bool framed = flags & OMNI_CONFIG_SECTION_FRAMES;
        const bool pushesFrames = reads & (kind << OMNI_CONFIG_READ_FRAME_SHIFT);
        if (pushesFrames && !framed) {
            throw InvalidSnapshot{};
        }
        const auto name = readNames[bit - readBits.begin()];
        lua_pushboolean(L, flags & OMNI_CONFIG_SECTION_TRUNCATED);
        lua_rawsetfield(L, -2, name);
        if (kind == OMNI_CONFIG_READ_PLACEMENT || kind == OMNI_CONFIG_READ_FOCUS_TARGET) {
            if (count > 1) {
                throw InvalidSnapshot{};
            }
            if (count == 1) {
                if (kind == OMNI_CONFIG_READ_PLACEMENT) {
                    pushPlacement(L, rows);
                } else {
                    pushFocusTarget(L, rows);
                }
                lua_rawsetfield(L, context, name);
            }
        } else {
            lua_createtable(L, count, 0);
            for (int row = 1; row <= count; ++row) {
                pushLookupRow(L, rows, kind, framed, pushesFrames);
                lua_rawseti(L, -2, row);
            }
            lua_setreadonly(L, -1, true);
            lua_rawsetfield(L, context, name);
        }
        if (!rows.empty()) {
            throw InvalidSnapshot{};
        }
    }
    if (reads & OMNI_CONFIG_READ_LISTS) {
        throw InvalidSnapshot{};
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, context, "truncated");
}

void pushContext(lua_State *L, const omni_config_trigger &trigger, bool event, uint16_t reads) {
    const auto *edge = trigger.edge;
    const char *flag = nullptr;
    int capacity = event ? (trigger.id.data != nullptr) + (trigger.name.data != nullptr)
        + (trigger.bundle_id.data != nullptr) : 4;
    if (edge) {
        switch (edge->kind) {
        case OMNI_WINDOW_MINIMIZED: flag = "minimized"; break;
        case OMNI_WINDOW_FULLSCREEN: flag = "fullscreen"; break;
        case OMNI_WINDOW_FLOATING: flag = "floating"; break;
        default: break;
        }
        capacity += 1 + (edge->id.data != nullptr) + (edge->name.data != nullptr)
            + (edge->previous_id.data != nullptr) + (edge->previous_name.data != nullptr)
            + edge->frame.present + edge->previous_frame.present + edge->visible_frame.present
            + edge->previous_visible_frame.present + (flag != nullptr);
    }
    lua_createtable(L, 0, capacity + (reads ? 1 + __builtin_popcount(reads & OMNI_CONFIG_READ_LISTS) : 0));
    auto field = [L](const char *name, omni_config_span value) {
        if (value.data) {
            lua_pushlstring(L, value.data, value.length);
            lua_rawsetfield(L, -2, name);
        }
    };
    field(event ? "id" : "windowId", trigger.id);
    field("bundleId", trigger.bundle_id);
    field(event ? "name" : "workspace", trigger.name);
    field("layout", trigger.layout);
    if (edge) {
        lua_pushnumber(L, static_cast<double>(edge->missed));
        lua_rawsetfield(L, -2, "missed");
        if (edge->kind == OMNI_WINDOW_TITLE) {
            field("title", edge->name);
        } else if (flag) {
            lua_pushboolean(L, edge->flag);
            lua_rawsetfield(L, -2, flag);
        } else if (edge->kind == OMNI_EDGE_GEOMETRY) {
            setRect(L, "frame", edge->frame);
            setRect(L, "previousFrame", edge->previous_frame);
            setRect(L, "visibleFrame", edge->visible_frame);
            setRect(L, "previousVisibleFrame", edge->previous_visible_frame);
        } else {
            const bool workspace = edge->kind == OMNI_EDGE_WORKSPACE;
            field(workspace ? "workspaceId" : "monitorId", edge->id);
            field(workspace ? "workspaceName" : "monitorName", edge->name);
            field(workspace ? "previousWorkspaceId" : "previousMonitorId", edge->previous_id);
            field(workspace ? "previousWorkspaceName" : "previousMonitorName", edge->previous_name);
        }
    }
    if (reads) {
        pushLookups(L, trigger.snapshot, reads);
    }
    lua_setreadonly(L, -1, true);
}

}

struct omni_config_vm final : ConfigVM {
    using ConfigVM::ConfigVM;
};

omni_status omni_config_load(const char *chunk_name, omni_config_span source,
    size_t heap_limit, uint64_t cpu_budget_ns, const omni_config_callbacks *callbacks,
    void *context, omni_config_stats *stats, char *error, size_t error_capacity, omni_config_vm **resident) noexcept {
    using namespace omni_detail;
    if (resident) {
        *resident = nullptr;
    }
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
    std::unique_ptr<omni_config_vm> owned;
    omni_status status = OMNI_ERR_MEMORY;
    try {
        owned = std::make_unique<omni_config_vm>(*callbacks, context);
        auto &vm = *owned;
        if (openRuntime(vm, heap_limit, static_cast<ModuleRuntime *>(&vm), trackConfigMetrics)) {
            liveVMs.fetch_add(1, std::memory_order_relaxed);
            installConfig(vm.main);
            sandboxRuntime(vm);
            vm.modules.push_back({chunk_name});
            vm.chain.push_back(0);
            status = loadChunk(vm.thread, chunk_name, source, vm.location.line, error, error_capacity);
            if (status == OMNI_OK) {
                status = resumeConfig(vm, 0, cpu_budget_ns, error, error_capacity);
            }
        } else {
            copyMessage("unable to allocate the config VM", error, error_capacity);
        }
    } catch (const std::bad_alloc &) {
        copyMessage("config allocation failed", error, error_capacity);
        status = OMNI_ERR_MEMORY;
    } catch (...) {
        if (!owned || owned->timer == nullptr) {
            copyMessage("unable to initialize the config VM within its heap limit", error, error_capacity);
        } else {
            copyMessage("unexpected config evaluator error", error, error_capacity);
            status = OMNI_ERR_INTERNAL;
        }
    }
    trimUTF8End(error, error_capacity);
    if (stats && owned) {
        if constexpr (trackConfigMetrics) {
            stats->peak_bytes = owned->peak;
            stats->allocations = owned->allocations;
        }
        stats->location = owned->location;
        stats->module_executions = owned->moduleExecutions;
        stats->cancelled_timers = owned->cancelledTimers;
    }
    if (status == OMNI_OK && resident &&
        owned->functions.size() > static_cast<size_t>(__builtin_popcount(owned->cancelledTimers))) {
        lua_settop(owned->thread, 0);
        owned->context = nullptr;
        *resident = owned.release();
    }
    return status;
}

const omni_config_timer *omni_config_timers(const omni_config_vm *vm, size_t *count) noexcept {
    *count = vm->configuredTimers.size();
    return vm->configuredTimers.data();
}

omni_status omni_config_evaluate(const char *chunk_name, omni_config_span source,
    size_t heap_limit, uint64_t cpu_budget_ns, const omni_config_callbacks *callbacks,
    void *context, omni_config_stats *stats, char *error, size_t error_capacity) noexcept {
    return omni_config_load(chunk_name, source, heap_limit, cpu_budget_ns, callbacks, context, stats,
        error, error_capacity, nullptr);
}

omni_status omni_config_invoke(omni_config_vm *vm, uint32_t callback_id, omni_config_trigger trigger,
    uint64_t cpu_budget_ns, void *context, omni_config_stats *stats, char *error, size_t error_capacity) noexcept {
    if (stats) {
        *stats = {};
    }
    if (error && error_capacity) {
        error[0] = '\0';
    }
    if (!vm || callback_id >= vm->functions.size() || !cpu_budget_ns || vm->invoking) {
        copyMessage("invalid config callback", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
    auto &function = vm->functions[callback_id];
    vm->context = context;
    vm->invoking = true;
    vm->location = function.declaration;
    vm->failure[0] = '\0';
    vm->rejected = false;
    vm->commands = 0;
    vm->logs = 0;
    vm->actions = 0;
    vm->tokenBytes = 0;
    const uint64_t allocations = trackConfigMetrics ? vm->allocations : 0;
    uint32_t previouslyCancelled = vm->cancelledTimers;
    omni_status status;
    try {
        lua_getref(vm->thread, function.ref);
        const bool hasContext = !function.timer || function.reads;
        if (hasContext) {
            pushContext(vm->thread, trigger, function.event, function.reads);
        }
        status = resumeConfig(*vm, hasContext ? 1 : 0, cpu_budget_ns, error, error_capacity);
        if (lua_status(vm->thread) != LUA_OK) {
            lua_resetthread(vm->thread);
        } else {
            lua_settop(vm->thread, 0);
        }
    } catch (const InvalidSnapshot &) {
        lua_settop(vm->thread, 0);
        copyMessage("incomplete lookup snapshot", error, error_capacity);
        status = OMNI_ERR_INTERNAL;
    } catch (...) {
        lua_settop(vm->thread, 0);
        copyMessage("unable to run the callback within its heap limit", error, error_capacity);
        status = OMNI_ERR_MEMORY;
    }
    vm->context = nullptr;
    vm->invoking = false;
    if (stats) {
        stats->location = vm->location;
        if constexpr (trackConfigMetrics) {
            stats->allocations = vm->allocations - allocations;
            stats->peak_bytes = vm->peak;
        }
        stats->cancelled_timers = vm->cancelledTimers & ~previouslyCancelled;
    }
    return status;
}

void omni_config_destroy(omni_config_vm *resident) noexcept {
    delete resident;
}

uint64_t omni_config_live_vm_count(void) noexcept {
    return liveVMs.load(std::memory_order_relaxed);
}

uint64_t omni_config_vm_entry_count(void) noexcept {
    return omni_detail::trackConfigMetrics ? vmEntries.load(std::memory_order_relaxed) : 0;
}
