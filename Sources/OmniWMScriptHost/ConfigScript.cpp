// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptModules.h"
#include "ScriptUTF8.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>
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
    uint32_t reads;
};

struct ConfigVM : ModuleRuntime {
    omni_config_callbacks callbacks;
    std::vector<Callback> functions;
    std::vector<omni_config_timer> configuredTimers;
    uint32_t cancelledTimers = 0;
    unsigned commands = 0;
    unsigned storeWrites = 0;
    bool storeUsed = false;
    std::vector<char> storeBytes;
    bool dwindleStaged = false;
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

struct CommandGroup {
    const char *member;
    size_t firstWordLength;
};

#include "ConfigCommandGroups.h"

static_assert(commandGroups.size() <= UINT16_MAX + size_t{1});

uint64_t integerSelector(lua_State *L, ConfigVM &vm, int index, omni_config_location site) {
    const double number = lua_tonumber(L, index);
    if (!(number >= 1 && number <= OMNI_CONFIG_MAX_SAFE_INTEGER) || std::trunc(number) != number) {
        reject(L, vm, site, "expected a positive safe integer selector");
    }
    chargeTokenBytes(L, vm, sizeof(number), site);
    return static_cast<uint64_t>(number);
}

int command(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    std::array<omni_config_word, LUA_MINSTACK> words;
    const int count = lua_gettop(L);
    if (static_cast<size_t>(count) >= words.size()) {
        reject(L, vm, site, "invalid number of command words");
    }
    if (vm.actions == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config action limit exceeded");
    }
    const auto group = static_cast<uint16_t>(lua_tointeger(L, lua_upvalueindex(1)));
    chargeTokenBytes(L, vm, commandGroups[group].firstWordLength, site);
    for (int i = 0; i < count; i++) {
        const int index = i + 1;
        words[i] = lua_type(L, index) == LUA_TNUMBER
            ? omni_config_word{{}, integerSelector(L, vm, index, site)}
            : omni_config_word{token(L, vm, index, site), 0};
    }
    auto *action = static_cast<uint32_t *>(lua_newuserdatatagged(L, sizeof(uint32_t), actionTag));
    if (!vm.callbacks.resolve(vm.context, group, words.data(), count, site, action, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid command");
    }
    vm.actions++;
    return 1;
}

int unknownCommandMember(lua_State *L) {
    ConfigVM &vm = declarations(L);
    const auto site = declarationSite(L, vm);
    const auto key = token(L, vm, 2, site);
    for (size_t offset = 0; offset < key.length;) {
        const size_t width = utf8Width(key.data + offset, key.length - offset);
        if (width == 0) {
            reject(L, vm, site, "expected a valid UTF-8 command member");
        }
        offset += width;
    }
    std::snprintf(vm.failure, sizeof vm.failure, "Unknown command member '%.*s'.", static_cast<int>(key.length), key.data);
    reject(L, vm, site, vm.failure);
}

void installCommands(lua_State *L) {
    lua_createtable(L, 0, static_cast<int>(commandGroups.size()));
    for (size_t group = 0; group < commandGroups.size(); ++group) {
        const char *member = commandGroups[group].member;
        lua_pushinteger(L, static_cast<int>(group));
        lua_pushcclosure(L, command, member, 1);
        lua_setfield(L, -2, member);
    }
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, unknownCommandMember, "cmd");
    lua_setfield(L, -2, "__index");
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true);
    lua_setmetatable(L, -2);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "cmd");
}

struct CallbackOptions {
    omni_config_span modeKey{};
    omni_config_span mode{};
    uint32_t reads = 0;
};

constexpr std::array readNames{"workspaceWindows", "windows", "workspaces", "monitors", "placement", "focusTarget"};
constexpr std::array<uint8_t, 6> readBits{
    OMNI_CONFIG_READ_WORKSPACE_WINDOWS, OMNI_CONFIG_READ_WINDOWS, OMNI_CONFIG_READ_WORKSPACES, OMNI_CONFIG_READ_MONITORS,
    OMNI_CONFIG_READ_PLACEMENT, OMNI_CONFIG_READ_FOCUS_TARGET
};
constexpr std::string_view framesRead = "frames";
constexpr std::string_view columnsRead = "columns";
constexpr std::string_view detailsRead = "details";
constexpr std::string_view dwindleRead = "dwindle";
constexpr std::array dwindleDirections{"left", "right", "up", "down"};
static_assert(OMNI_CONFIG_DWINDLE_DOWN == dwindleDirections.size());
constexpr uint16_t framedLists = OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS | OMNI_CONFIG_READ_MONITORS;
constexpr uint16_t columnedLists = OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS;
constexpr uint32_t detailedLists = OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS |
    OMNI_CONFIG_READ_WORKSPACES | OMNI_CONFIG_READ_MONITORS;
constexpr uint32_t detailsMask = detailedLists << OMNI_CONFIG_READ_DETAIL_SHIFT;
static_assert(detailsMask == (OMNI_CONFIG_READ_WORKSPACE_WINDOW_DETAILS | OMNI_CONFIG_READ_WINDOW_DETAILS |
    OMNI_CONFIG_READ_WORKSPACE_DETAILS | OMNI_CONFIG_READ_MONITOR_DETAILS));
static_assert((framedLists << OMNI_CONFIG_READ_FRAME_SHIFT) ==
    (OMNI_CONFIG_READ_WORKSPACE_WINDOW_FRAMES | OMNI_CONFIG_READ_WINDOW_FRAMES | OMNI_CONFIG_READ_MONITOR_FRAMES));
static_assert((columnedLists << OMNI_CONFIG_READ_COLUMN_SHIFT) ==
    (OMNI_CONFIG_READ_WORKSPACE_WINDOW_COLUMNS | OMNI_CONFIG_READ_WINDOW_COLUMNS));
static_assert(((OMNI_CONFIG_READ_LISTS << OMNI_CONFIG_READ_FRAME_SHIFT) &
    (OMNI_CONFIG_READ_WORKSPACE_WINDOW_COLUMNS | OMNI_CONFIG_READ_WINDOW_COLUMNS)) == 0);
static_assert(OMNI_CONFIG_READ_LISTS == (OMNI_CONFIG_READ_WORKSPACE_WINDOWS | OMNI_CONFIG_READ_WINDOWS |
    OMNI_CONFIG_READ_WORKSPACES | OMNI_CONFIG_READ_MONITORS | OMNI_CONFIG_READ_PLACEMENT | OMNI_CONFIG_READ_FOCUS_TARGET));

uint32_t readMask(lua_State *L, ConfigVM &vm, omni_config_location site) {
    if (!lua_istable(L, -1)) {
        reject(L, vm, site, "reads expects an array of lookup names");
    }
    const int table = lua_gettop(L);
    const int length = lua_objlen(L, table);
    if (length > static_cast<int>(readNames.size()) + 4) {
        reject(L, vm, site, "too many lookup names in reads");
    }
    uint32_t mask = 0;
    bool frames = false;
    bool columns = false;
    bool details = false;
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
        const bool columnsName = name == columnsRead;
        const bool detailsName = name == detailsRead;
        const bool dwindleName = name == dwindleRead;
        auto it = std::find(readNames.begin(), readNames.end(), name);
        if (it == readNames.end() && !framesName && !columnsName && !detailsName && !dwindleName) {
            reject(L, vm, site,
                "unknown read; expected workspaceWindows, windows, workspaces, monitors, placement, focusTarget, dwindle, "
                "frames, columns or details");
        }
        const bool modifier = framesName || columnsName || detailsName;
        const uint32_t bit = modifier ? 0 : dwindleName ? OMNI_CONFIG_READ_DWINDLE : readBits[it - readNames.begin()];
        if (framesName ? frames : columnsName ? columns : detailsName ? details : (mask & bit) != 0) {
            reject(L, vm, site, "duplicate lookup name in reads");
        }
        frames |= framesName;
        columns |= columnsName;
        details |= detailsName;
        mask |= bit;
        ++count;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "reads expects consecutive array indices");
    }
    const uint32_t lists = mask;
    if (frames) {
        const uint16_t framed = lists & framedLists;
        if (!framed) {
            reject(L, vm, site, "frames needs workspaceWindows, windows or monitors in the same reads");
        }
        mask |= framed << OMNI_CONFIG_READ_FRAME_SHIFT;
    }
    if (columns) {
        const uint16_t columned = lists & columnedLists;
        if (!columned) {
            reject(L, vm, site, "columns needs workspaceWindows or windows in the same reads");
        }
        mask |= columned << OMNI_CONFIG_READ_COLUMN_SHIFT;
    }
    if (details) {
        const auto detailed = lists & detailedLists;
        if (!detailed) {
            reject(L, vm, site, "details needs workspaceWindows, windows, workspaces or monitors in the same reads");
        }
        mask |= detailed << OMNI_CONFIG_READ_DETAIL_SHIFT;
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
        } else if (binding && key == "mode") {
            options.mode = token(L, vm, -1, site);
        } else if (function && key == "reads") {
            options.reads = readMask(L, vm, site);
        } else {
            reject(L, vm, site, binding ? "unknown keymap.set option; expected modeKey, mode or reads on a function" :
                "unknown callback option; expected reads");
        }
        lua_pop(L, 1);
    }
    if (options.modeKey.data && options.mode.data) {
        reject(L, vm, site, "keymap.set takes modeKey or mode, not both");
    }
    return options;
}

uint32_t registerFunction(lua_State *L, ConfigVM &vm, omni_config_location site, uint32_t reads, bool event = false, bool timer = false) {
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
            options.modeKey, options.mode, options.reads, site, vm.failure, sizeof vm.failure)
        : vm.callbacks.bind(vm.context, chord, *action, options.modeKey, options.mode, site, vm.failure,
            sizeof vm.failure);
    if (!bound) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid binding");
    }
    vm.bindings++;
    return 0;
}

int declareMode(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if (vm.invoking) {
        reject(L, vm, site, "keymap.mode is only available while loading the config");
    }
    if (!vm.callbacks.mode || lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TSTRING) {
        reject(L, vm, site, "keymap.mode expects a mode name");
    }
    if (vm.actions == OMNI_CONFIG_DECLARATION_LIMIT) {
        reject(L, vm, site, "config action limit exceeded");
    }
    const auto name = token(L, vm, 1, site);
    auto *action = static_cast<uint32_t *>(lua_newuserdatatagged(L, sizeof(uint32_t), actionTag));
    if (!vm.callbacks.mode(vm.context, name, site, action, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid mode");
    }
    vm.actions++;
    return 1;
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

constexpr std::string_view gatherAction = "gather";
constexpr std::string_view gatherDefaultReach = "workspace";

bool stageGather(lua_State *L, ConfigVM &vm, omni_config_location site, int top) {
    static_assert(OMNI_CONFIG_GATHER_LIMIT == 64, "the gather message names the limit");
    if (top > 4) {
        reject(L, vm, site, "gather expects a list of window IDs and an optional reach");
    }
    const int length = lua_objlen(L, 3);
    if (length < 1 || length > static_cast<int>(OMNI_CONFIG_GATHER_LIMIT)) {
        reject(L, vm, site, "gather expects between 1 and 64 window IDs");
    }
    std::array<omni_config_span, OMNI_CONFIG_GATHER_LIMIT + 2> words;
    words[0] = token(L, vm, 2, site);
    words[1] = lua_isnoneornil(L, 4) ? omni_config_span{gatherDefaultReach.data(), gatherDefaultReach.size()}
                                     : token(L, vm, 4, site);
    int count = 0;
    lua_pushnil(L);
    while (lua_next(L, 3)) {
        const double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(key >= 1 && key <= length && key == static_cast<int>(key))) {
            reject(L, vm, site, "gather expects an array of window IDs");
        }
        words[static_cast<int>(key) + 1] = token(L, vm, -1, site);
        count++;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "gather expects an array without holes");
    }
    return vm.callbacks.window(vm.context, words.data(), static_cast<size_t>(length + 2), 0, nullptr, 0, site,
        vm.failure, sizeof vm.failure);
}

constexpr size_t dwindleNodeLimit = 2 * OMNI_CONFIG_DWINDLE_MEMBER_LIMIT - 1;
constexpr std::array dwindleOrientations{"horizontal", "vertical"};
static_assert(OMNI_CONFIG_DWINDLE_VERTICAL + 1 == dwindleOrientations.size());

void onlyFields(lua_State *L, ConfigVM &vm, omni_config_location site, int table,
    std::initializer_list<std::string_view> names, const char *message) {
    lua_pushnil(L);
    while (lua_next(L, table)) {
        size_t length = 0;
        const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &length) : nullptr;
        if (!key || std::find(names.begin(), names.end(), std::string_view(key, length)) == names.end()) {
            reject(L, vm, site, message);
        }
        lua_pop(L, 1);
    }
}

int arrayLength(lua_State *L, ConfigVM &vm, omni_config_location site, int table, size_t limit,
    const char *limitMessage, const char *message) {
    const int length = lua_objlen(L, table);
    if (static_cast<size_t>(length) > limit) {
        reject(L, vm, site, limitMessage);
    }
    int count = 0;
    lua_pushnil(L);
    while (lua_next(L, table)) {
        const double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(key >= 1 && key <= length && key == static_cast<int>(key))) {
            reject(L, vm, site, message);
        }
        count++;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, message);
    }
    return length;
}

template <size_t Size>
uint8_t wordIndex(lua_State *L, ConfigVM &vm, omni_config_location site, const std::array<const char *, Size> &words,
    const char *message) {
    const auto word = token(L, vm, -1, site);
    const auto match = std::find(words.begin(), words.end(), std::string_view(word.data, word.length));
    if (match == words.end()) {
        reject(L, vm, site, message);
    }
    return static_cast<uint8_t>(match - words.begin());
}

void readDwindleNode(lua_State *L, ConfigVM &vm, omni_config_location site, omni_config_dwindle_node &node,
    omni_config_span *members, size_t &memberCount) {
    const int table = lua_gettop(L);
    if (!lua_istable(L, table)) {
        reject(L, vm, site, "dwindle nodes must be tables");
    }
    lua_rawgetfield(L, table, "kind");
    const bool split = wordIndex(L, vm, site, std::array{"split", "leaf"}, "a dwindle node is a split or a leaf") == 0;
    lua_pop(L, 1);
    node = omni_config_dwindle_node{};
    if (split) {
        onlyFields(L, vm, site, table, {"kind", "orientation", "ratio"}, "a split has kind, orientation and ratio");
        node.kind = OMNI_CONFIG_DWINDLE_SPLIT;
        lua_rawgetfield(L, table, "orientation");
        node.orientation = wordIndex(L, vm, site, dwindleOrientations, "orientation is horizontal or vertical");
        lua_pop(L, 1);
        lua_rawgetfield(L, table, "ratio");
        if (lua_type(L, -1) != LUA_TNUMBER) {
            reject(L, vm, site, "a split's ratio is a number");
        }
        node.ratio = lua_tonumber(L, -1);
        lua_pop(L, 1);
        return;
    }
    onlyFields(L, vm, site, table, {"kind", "members", "active"}, "a leaf has kind, members and active");
    node.kind = OMNI_CONFIG_DWINDLE_LEAF;
    lua_rawgetfield(L, table, "members");
    const int list = lua_gettop(L);
    if (!lua_istable(L, list)) {
        reject(L, vm, site, "a leaf's members are an array of window IDs");
    }
    constexpr const char *memberLimitMessage = "a dwindle tree has 1 to 256 windows per leaf and in all";
    const int length = arrayLength(L, vm, site, list, OMNI_CONFIG_DWINDLE_MEMBER_LIMIT - memberCount,
        memberLimitMessage, "a leaf's members are an array without holes");
    if (length < 1) {
        reject(L, vm, site, memberLimitMessage);
    }
    node.first_member = static_cast<uint16_t>(memberCount);
    node.member_count = static_cast<uint16_t>(length);
    for (int index = 1; index <= length; index++) {
        lua_rawgeti(L, list, index);
        members[memberCount++] = token(L, vm, -1, site);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_rawgetfield(L, table, "active");
    const double active = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : 0;
    if (!(active >= 1 && active <= length && active == static_cast<int>(active))) {
        reject(L, vm, site, "a leaf's active is the position of one of its members");
    }
    node.active = static_cast<uint16_t>(active);
    lua_pop(L, 1);
}

bool stageDwindleReplace(lua_State *L, ConfigVM &vm, omni_config_location site, int top) {
    static_assert(OMNI_CONFIG_DWINDLE_MEMBER_LIMIT == 256, "the dwindle messages name the limit");
    if (!vm.callbacks.dwindle || top != 3 || lua_type(L, 2) != LUA_TSTRING || !lua_istable(L, 3)) {
        reject(L, vm, site, "omniwm.dispatch expects 'dwindle', 'replace' and one tree");
    }
    const auto action = token(L, vm, 2, site);
    if (std::string_view(action.data, action.length) != "replace") {
        reject(L, vm, site, "omniwm.dispatch expects 'dwindle', 'replace' and one tree");
    }
    if (vm.dwindleStaged) {
        reject(L, vm, site, "a callback replaces at most one dwindle tree");
    }
    onlyFields(L, vm, site, 3, {"workspaceId", "revision", "preselect", "nodes"},
        "a dwindle tree has workspaceId, revision, preselect and nodes");
    omni_config_dwindle_tree tree{};
    lua_rawgetfield(L, 3, "workspaceId");
    tree.workspace_id = token(L, vm, -1, site);
    lua_pop(L, 1);
    lua_rawgetfield(L, 3, "revision");
    tree.revision = token(L, vm, -1, site);
    lua_pop(L, 1);
    lua_rawgetfield(L, 3, "preselect");
    tree.preselect = lua_isnil(L, -1)
        ? 0
        : wordIndex(L, vm, site, dwindleDirections, "preselect is left, right, up or down") + 1;
    lua_pop(L, 1);
    lua_rawgetfield(L, 3, "nodes");
    const int list = lua_gettop(L);
    if (!lua_istable(L, list)) {
        reject(L, vm, site, "a dwindle tree's nodes are an array");
    }
    const int length = arrayLength(L, vm, site, list, dwindleNodeLimit, "a dwindle tree has at most 511 nodes",
        "a dwindle tree's nodes are an array without holes");
    std::array<omni_config_dwindle_node, dwindleNodeLimit> nodes;
    std::array<omni_config_span, OMNI_CONFIG_DWINDLE_MEMBER_LIMIT> members;
    size_t memberCount = 0;
    for (int index = 1; index <= length; index++) {
        lua_rawgeti(L, list, index);
        readDwindleNode(L, vm, site, nodes[index - 1], members.data(), memberCount);
        lua_pop(L, 1);
    }
    tree.nodes = nodes.data();
    tree.node_count = static_cast<size_t>(length);
    tree.members = members.data();
    tree.member_count = memberCount;
    const bool staged = vm.callbacks.dwindle(vm.context, &tree, site, vm.failure, sizeof vm.failure);
    lua_pop(L, 1);
    vm.dwindleStaged = staged;
    return staged;
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
    const int top = lua_gettop(L);
    const bool named = lua_type(L, 1) == LUA_TSTRING;
    const auto prefix = named ? token(L, vm, 1, site) : omni_config_span{};
    const std::string_view kind(prefix.data, prefix.length);
    if (named && kind == "mark") {
        if (!vm.callbacks.mark || top != 3) {
            reject(L, vm, site, "omniwm.dispatch expects 'mark', an action and a mark name");
        }
        const auto action = token(L, vm, 2, site);
        const auto name = token(L, vm, 3, site);
        staged = vm.callbacks.mark(vm.context, action, name, site, vm.failure, sizeof vm.failure);
    } else if (named && kind == "dwindle") {
        staged = stageDwindleReplace(L, vm, site, top);
    } else if (named && top >= 3 && lua_istable(L, 3) && lua_type(L, 2) == LUA_TSTRING) {
        const auto action = token(L, vm, 2, site);
        if (!vm.callbacks.window || kind != "window" || std::string_view(action.data, action.length) != gatherAction) {
            reject(L, vm, site, "omniwm.dispatch takes a list of window IDs only for 'window', 'gather'");
        }
        staged = stageGather(L, vm, site, top);
    } else if (named) {
        const bool tableDestination = top == 4 && lua_istable(L, 4);
        const int count = top - 1 - (tableDestination ? 1 : 0);
        std::array<omni_config_span, LUA_MINSTACK> words;
        if (!vm.callbacks.window || kind != "window" || count < 2 || static_cast<size_t>(count) > words.size()) {
            reject(L, vm, site, "omniwm.dispatch expects 'window', an action, a window ID and any action arguments");
        }
        const bool indexed = count == 3 && lua_type(L, 4) == LUA_TNUMBER;
        const int textCount = count - indexed;
        for (int i = 0; i < textCount; i++) {
            words[i] = token(L, vm, i + 2, site);
        }
        if (std::string_view(words[0].data, words[0].length) == gatherAction) {
            reject(L, vm, site, "gather expects a list of window IDs");
        }
        std::array<omni_config_field, maximumDestinationFields> destination;
        const size_t fields = tableDestination
            ? readFields(L, vm, 4, site, destination.data(), destination.size(),
                {"too many fields in a window table",
                    "window table fields must be strings, numbers or booleans"})
            : 0;
        const uint64_t selector = indexed ? integerSelector(L, vm, 4, site) : 0;
        staged = vm.callbacks.window(vm.context, words.data(), textCount, selector,
            tableDestination ? destination.data() : nullptr, fields, site, vm.failure, sizeof vm.failure);
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
        reject(L, vm, site, "launch expects an array of strings");
    }
    const int length = lua_objlen(L, 1);
    if (length < 1 || length > static_cast<int>(OMNI_CONFIG_ARGC_LIMIT)) {
        reject(L, vm, site, "launch needs an executable and a bounded number of arguments");
    }
    int count = 0;
    size_t bytes = 0;
    lua_pushnil(L);
    while (lua_next(L, 1)) {
        double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(key >= 1 && key <= length && key == static_cast<int>(key))) {
            reject(L, vm, site, "launch expects consecutive array indices starting at one");
        }
        auto value = token(L, vm, -1, site);
        if (value.length > OMNI_CONFIG_ARG_BYTE_LIMIT || value.length > OMNI_CONFIG_ARGV_BYTE_LIMIT - bytes ||
            std::memchr(value.data, 0, value.length)) {
            reject(L, vm, site, "launch arguments exceed the byte limit or contain a NUL");
        }
        words[static_cast<int>(key) - 1] = value;
        bytes += value.length;
        count++;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "launch expects an array without holes");
    }
    const std::string_view executable(words[0].data, words[0].length);
    if (executable.empty() || (executable.front() != '/' && executable.find('/') != executable.npos)) {
        reject(L, vm, site, "launch needs an absolute executable path or a bare program name");
    }
    return static_cast<size_t>(count);
}

template<omni_config_effect_kind kind, bool build>
int nativeEffect(lua_State *L) {
    ConfigVM &vm = declarations(L);
    auto site = declarationSite(L, vm);
    if constexpr (!build) {
        if (!vm.invoking) {
            constexpr const char *guide = kind == OMNI_CONFIG_OPEN_APP ? "during config load, use omniwm.act.openApp to build an action" :
                kind == OMNI_CONFIG_RUN_PROGRAM ? "during config load, use omniwm.act.launch to build an action" :
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

void requireStore(lua_State *L, ConfigVM &vm, omni_config_location site) {
    if (!vm.invoking || !vm.callbacks.store.get || !vm.callbacks.store.set || !vm.callbacks.store.clear) {
        reject(L, vm, site, "omniwm.store is only available in a callback");
    }
    vm.storeUsed = true;
}

void countStoreWrite(lua_State *L, ConfigVM &vm, omni_config_location site) {
    if (vm.storeWrites == OMNI_CONFIG_STORE_WRITE_LIMIT) {
        std::snprintf(vm.failure, sizeof vm.failure, "a callback changes the store at most %u times",
            OMNI_CONFIG_STORE_WRITE_LIMIT);
        reject(L, vm, site, vm.failure);
    }
    vm.storeWrites++;
}

omni_config_span storeKey(lua_State *L, ConfigVM &vm, omni_config_location site) {
    if (lua_type(L, 1) != LUA_TSTRING) {
        reject(L, vm, site, "store keys must be strings");
    }
    omni_config_span key;
    key.data = lua_tolstring(L, 1, &key.length);
    return key;
}

omni_config_span storeText(lua_State *L, ConfigVM &vm, int index, omni_config_location site) {
    omni_config_span text;
    text.data = lua_tolstring(L, index, &text.length);
    if (text.length > OMNI_CONFIG_STORE_STRING_LIMIT) {
        std::snprintf(vm.failure, sizeof vm.failure, "store strings are at most %u bytes",
            OMNI_CONFIG_STORE_STRING_LIMIT);
        reject(L, vm, site, vm.failure);
    }
    return text;
}

size_t storeList(lua_State *L, ConfigVM &vm, omni_config_location site, omni_config_span *items) {
    const int length = lua_objlen(L, 2);
    if (length > static_cast<int>(OMNI_CONFIG_STORE_LIST_LIMIT)) {
        std::snprintf(vm.failure, sizeof vm.failure, "store lists hold at most %u strings",
            OMNI_CONFIG_STORE_LIST_LIMIT);
        reject(L, vm, site, vm.failure);
    }
    int count = 0;
    lua_pushnil(L);
    while (lua_next(L, 2)) {
        const double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (!(key >= 1 && key <= length && key == static_cast<int>(key)) || lua_type(L, -1) != LUA_TSTRING) {
            reject(L, vm, site, "store lists must be arrays of strings without holes");
        }
        items[static_cast<int>(key) - 1] = storeText(L, vm, -1, site);
        count++;
        lua_pop(L, 1);
    }
    if (count != length) {
        reject(L, vm, site, "store lists must be arrays of strings without holes");
    }
    return static_cast<size_t>(count);
}

int storeGet(lua_State *L) {
    ConfigVM &vm = declarations(L);
    const auto site = declarationSite(L, vm);
    requireStore(L, vm, site);
    if (lua_gettop(L) != 1) {
        reject(L, vm, site, "omniwm.store.get expects a key");
    }
    const auto key = storeKey(L, vm, site);
    if (vm.storeBytes.empty()) {
        vm.storeBytes.resize(OMNI_CONFIG_STORE_BYTE_LIMIT);
    }
    std::array<omni_config_span, OMNI_CONFIG_STORE_LIST_LIMIT> items;
    omni_config_store_read read{{}, vm.storeBytes.data(), vm.storeBytes.size(), items.data()};
    if (!vm.callbacks.store.get(vm.context, key, &read, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid store read");
    }
    switch (read.value.kind) {
    case OMNI_CONFIG_STORE_BOOLEAN:
        lua_pushboolean(L, read.value.boolean);
        break;
    case OMNI_CONFIG_STORE_NUMBER:
        lua_pushnumber(L, read.value.number);
        break;
    case OMNI_CONFIG_STORE_STRING:
        lua_pushlstring(L, items[0].data, items[0].length);
        break;
    case OMNI_CONFIG_STORE_LIST:
        lua_createtable(L, static_cast<int>(read.value.count), 0);
        for (size_t index = 0; index < read.value.count; index++) {
            lua_pushlstring(L, items[index].data, items[index].length);
            lua_rawseti(L, -2, static_cast<int>(index + 1));
        }
        break;
    default:
        lua_pushnil(L);
        break;
    }
    return 1;
}

int storeSet(lua_State *L) {
    ConfigVM &vm = declarations(L);
    const auto site = declarationSite(L, vm);
    requireStore(L, vm, site);
    if (lua_gettop(L) != 2) {
        reject(L, vm, site, "omniwm.store.set expects a key and a value");
    }
    const auto key = storeKey(L, vm, site);
    std::array<omni_config_span, OMNI_CONFIG_STORE_LIST_LIMIT> items;
    omni_config_store_value value{};
    value.items = items.data();
    switch (lua_type(L, 2)) {
    case LUA_TBOOLEAN:
        value.kind = OMNI_CONFIG_STORE_BOOLEAN;
        value.boolean = lua_toboolean(L, 2) != 0;
        break;
    case LUA_TNUMBER:
        value.kind = OMNI_CONFIG_STORE_NUMBER;
        value.number = lua_tonumber(L, 2);
        if (!std::isfinite(value.number)) {
            reject(L, vm, site, "store numbers must be finite");
        }
        break;
    case LUA_TSTRING:
        value.kind = OMNI_CONFIG_STORE_STRING;
        items[0] = storeText(L, vm, 2, site);
        value.count = 1;
        break;
    case LUA_TTABLE:
        value.kind = OMNI_CONFIG_STORE_LIST;
        value.count = storeList(L, vm, site, items.data());
        break;
    case LUA_TNIL:
        countStoreWrite(L, vm, site);
        if (!vm.callbacks.store.clear(vm.context, &key, site, vm.failure, sizeof vm.failure)) {
            reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid store write");
        }
        return 0;
    default:
        reject(L, vm, site, "store values must be booleans, numbers, strings or lists of strings");
    }
    countStoreWrite(L, vm, site);
    if (!vm.callbacks.store.set(vm.context, key, &value, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid store write");
    }
    return 0;
}

int storeClear(lua_State *L) {
    ConfigVM &vm = declarations(L);
    const auto site = declarationSite(L, vm);
    requireStore(L, vm, site);
    const int count = lua_gettop(L);
    if (count > 1) {
        reject(L, vm, site, "omniwm.store.clear expects one key, or nothing to clear every key");
    }
    const auto key = count == 1 ? storeKey(L, vm, site) : omni_config_span{};
    countStoreWrite(L, vm, site);
    if (!vm.callbacks.store.clear(vm.context, count == 1 ? &key : nullptr, site, vm.failure, sizeof vm.failure)) {
        reject(L, vm, site, vm.failure[0] ? vm.failure : "invalid store write");
    }
    return 0;
}

template<bool build>
void installEffectFunctions(lua_State *L) {
    lua_pushcfunction(L, (nativeEffect<OMNI_CONFIG_OPEN_APP, build>), "openApp");
    lua_setfield(L, -2, "openApp");
    lua_pushcfunction(L, (nativeEffect<OMNI_CONFIG_RUN_PROGRAM, build>), "launch");
    lua_setfield(L, -2, "launch");
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
    lua_createtable(L, 0, 13);
    lua_pushcfunction(L, addTimer, "timer");
    lua_setfield(L, -2, "timer");
    installCommands(L);
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
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, bindKey, "set");
    lua_setfield(L, -2, "set");
    lua_pushcfunction(L, declareMode, "mode");
    lua_setfield(L, -2, "mode");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "keymap");
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, storeGet, "get");
    lua_setfield(L, -2, "get");
    lua_pushcfunction(L, storeSet, "set");
    lua_setfield(L, -2, "set");
    lua_pushcfunction(L, storeClear, "clear");
    lua_setfield(L, -2, "clear");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "store");
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

void pushRect(lua_State *L, const omni_config_rect &rect) {
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
}

void setRect(lua_State *L, const char *key, const omni_config_rect &rect) {
    if (!rect.present) return;
    pushRect(L, rect);
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

omni_config_rect readRect(std::string_view &rows) {
    omni_config_rect rect{};
    rect.x = readDouble(rows);
    rect.y = readDouble(rows);
    rect.width = readDouble(rows);
    rect.height = readDouble(rows);
    rect.present = true;
    return rect;
}

void readRectField(lua_State *L, std::string_view &rows, const char *name, bool pushes) {
    if (!pushes) {
        takeBytes(rows, rectBytes);
        return;
    }
    setRect(L, name, readRect(rows));
}

struct RowLayout {
    bool framed;
    bool pushesFrames;
    bool columned;
    bool pushesColumns;
    bool detailed;
    bool pushesDetails;
};

void pushNumberField(lua_State *L, const char *name, double value) {
    lua_pushnumber(L, value);
    lua_rawsetfield(L, -2, name);
}

void pushDetailFlag(lua_State *L, const char *name, bool value) {
    lua_pushboolean(L, value);
    lua_rawsetfield(L, -2, name);
}

void pushWindowDetails(lua_State *L, std::string_view &row, uint8_t flags) {
    const auto bits = readUnsigned<uint32_t>(row);
    int32_t pid;
    std::memcpy(&pid, &bits, sizeof(pid));
    pushNumberField(L, "pid", pid);
    pushNumberField(L, "windowNumber", readUnsigned<uint32_t>(row));
    readStringField(L, row, "app");
    lua_pushstring(L, flags & OMNI_CONFIG_WINDOW_FLOATING ? "floating" : "tiling");
    lua_rawsetfield(L, -2, "mode");
    const auto detailFlags = readUnsigned<uint8_t>(row);
    lua_pushstring(L, detailFlags & OMNI_CONFIG_DETAIL_NATIVE_FULLSCREEN ? "native-fullscreen" : "standard");
    lua_rawsetfield(L, -2, "layoutReason");
    if (detailFlags & (OMNI_CONFIG_DETAIL_FORCE_TILE | OMNI_CONFIG_DETAIL_FORCE_FLOAT)) {
        lua_pushstring(L, detailFlags & OMNI_CONFIG_DETAIL_FORCE_TILE ? "force-tile" : "force-float");
        lua_rawsetfield(L, -2, "manualOverride");
    }
    const char *hidden = nullptr;
    switch (detailFlags >> OMNI_CONFIG_DETAIL_HIDDEN_SHIFT) {
        case 0: break;
        case OMNI_CONFIG_DETAIL_WORKSPACE_INACTIVE: hidden = "workspace-inactive"; break;
        case OMNI_CONFIG_DETAIL_TAB_INACTIVE: hidden = "tab-inactive"; break;
        case OMNI_CONFIG_DETAIL_LAYOUT_TRANSIENT: hidden = "layout-transient"; break;
        case OMNI_CONFIG_DETAIL_SCRATCHPAD: hidden = "scratchpad"; break;
        default: throw InvalidSnapshot{};
    }
    if (hidden) {
        lua_pushstring(L, hidden);
        lua_rawsetfield(L, -2, "hiddenReason");
    }
    pushDetailFlag(L, "visible", detailFlags & OMNI_CONFIG_DETAIL_VISIBLE);
    pushDetailFlag(L, "appHidden", detailFlags & OMNI_CONFIG_DETAIL_APP_HIDDEN);
    const auto slot = readUnsigned<uint32_t>(row);
    pushDetailFlag(L, "scratchpad", slot != UINT32_MAX);
    if (slot != UINT32_MAX) {
        pushNumberField(L, "scratchpadSlot", slot);
    }
    const auto rank = readUnsigned<uint32_t>(row);
    if (rank != UINT32_MAX) {
        pushNumberField(L, "focusRank", rank);
    }
    const auto position = readUnsigned<uint32_t>(row);
    if (position != 0) {
        pushNumberField(L, "columnPosition", position);
        pushNumberField(L, "columnSize", readUnsigned<uint32_t>(row));
        pushNumberField(L, "columnSpan", readDouble(row));
    }
}

constexpr std::array columnViewports{"before", "intersecting", "after"};
static_assert(OMNI_CONFIG_COLUMN_VIEWPORT_AFTER + 1 == columnViewports.size());
constexpr uint8_t workspaceDetailFlags = OMNI_CONFIG_WORKSPACE_DETAIL_FOCUSED | OMNI_CONFIG_WORKSPACE_DETAIL_VISIBLE |
    OMNI_CONFIG_WORKSPACE_DETAIL_CURRENT | OMNI_CONFIG_WORKSPACE_DETAIL_DWINDLE | OMNI_CONFIG_WORKSPACE_DETAIL_COLUMNS;
constexpr uint8_t monitorDetailFlags = OMNI_CONFIG_MONITOR_DETAIL_MAIN | OMNI_CONFIG_MONITOR_DETAIL_CURRENT |
    OMNI_CONFIG_MONITOR_DETAIL_HAS_NOTCH | OMNI_CONFIG_MONITOR_DETAIL_NOTCH | OMNI_CONFIG_MONITOR_DETAIL_VERTICAL |
    OMNI_CONFIG_MONITOR_DETAIL_FULLSCREEN_OUTER_GAPS;

void pushWorkspaceColumns(lua_State *L, std::string_view &row) {
    const auto count = readUnsigned<uint16_t>(row);
    lua_createtable(L, count, 0);
    for (int column = 1; column <= count; ++column) {
        const auto bits = readUnsigned<uint8_t>(row);
        const auto viewport = bits >> OMNI_CONFIG_COLUMN_VIEWPORT_SHIFT;
        if (viewport >= columnViewports.size()) {
            throw InvalidSnapshot{};
        }
        lua_createtable(L, 0, 2);
        lua_pushstring(L, bits & OMNI_CONFIG_COLUMN_TABBED ? "tabbed" : "normal");
        lua_rawsetfield(L, -2, "mode");
        lua_pushstring(L, columnViewports[viewport]);
        lua_rawsetfield(L, -2, "viewport");
        lua_setreadonly(L, -1, true);
        lua_rawseti(L, -2, column);
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, "columns");
}

void pushWorkspaceDetails(lua_State *L, std::string_view &row) {
    readStringField(L, row, "displayName");
    const auto number = readUnsigned<uint64_t>(row);
    if (number > OMNI_CONFIG_MAX_SAFE_INTEGER) {
        throw InvalidSnapshot{};
    }
    if (number != 0) {
        pushNumberField(L, "number", static_cast<double>(number));
    }
    const auto flags = readUnsigned<uint8_t>(row);
    const bool dwindle = flags & OMNI_CONFIG_WORKSPACE_DETAIL_DWINDLE;
    const bool columns = flags & OMNI_CONFIG_WORKSPACE_DETAIL_COLUMNS;
    if ((flags & ~workspaceDetailFlags) || (dwindle && columns)) {
        throw InvalidSnapshot{};
    }
    lua_pushstring(L, dwindle ? "dwindle" : "niri");
    lua_rawsetfield(L, -2, "layout");
    pushDetailFlag(L, "focused", flags & OMNI_CONFIG_WORKSPACE_DETAIL_FOCUSED);
    pushDetailFlag(L, "visible", flags & OMNI_CONFIG_WORKSPACE_DETAIL_VISIBLE);
    pushDetailFlag(L, "current", flags & OMNI_CONFIG_WORKSPACE_DETAIL_CURRENT);
    lua_createtable(L, 0, 4);
    for (const char *name : {"total", "tiled", "floating", "scratchpad"}) {
        pushNumberField(L, name, readUnsigned<uint32_t>(row));
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, "windowCounts");
    readStringField(L, row, "focusedWindow");
    if (dwindle) {
        return;
    }
    pushNumberField(L, "scrollOffset", readDouble(row));
    if (columns) {
        pushWorkspaceColumns(L, row);
    }
}

void pushEdges(lua_State *L, std::string_view &row, const char *name) {
    lua_createtable(L, 0, 4);
    for (const char *edge : {"left", "right", "top", "bottom"}) {
        pushNumberField(L, edge, readDouble(row));
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, name);
}

void pushMonitorDetails(lua_State *L, std::string_view &row) {
    const auto flags = readUnsigned<uint8_t>(row);
    if (flags & ~monitorDetailFlags) {
        throw InvalidSnapshot{};
    }
    pushDetailFlag(L, "main", flags & OMNI_CONFIG_MONITOR_DETAIL_MAIN);
    pushDetailFlag(L, "current", flags & OMNI_CONFIG_MONITOR_DETAIL_CURRENT);
    pushDetailFlag(L, "hasNotch", flags & OMNI_CONFIG_MONITOR_DETAIL_HAS_NOTCH);
    lua_pushstring(L, flags & OMNI_CONFIG_MONITOR_DETAIL_VERTICAL ? "vertical" : "horizontal");
    lua_rawsetfield(L, -2, "orientation");
    pushDetailFlag(L, "fullscreenUsesOuterGaps", flags & OMNI_CONFIG_MONITOR_DETAIL_FULLSCREEN_OUTER_GAPS);
    readStringField(L, row, "uuid");
    if (flags & OMNI_CONFIG_MONITOR_DETAIL_NOTCH) {
        lua_createtable(L, 0, 2);
        pushNumberField(L, "left", readDouble(row));
        pushNumberField(L, "right", readDouble(row));
        lua_setreadonly(L, -1, true);
        lua_rawsetfield(L, -2, "notch");
    }
    pushNumberField(L, "innerGap", readDouble(row));
    pushEdges(L, row, "outerGaps");
    pushNumberField(L, "menuBarHeight", readDouble(row));
    pushEdges(L, row, "reservedInsets");
    const auto bars = readUnsigned<uint8_t>(row);
    if (bars > OMNI_CONFIG_MONITOR_BAR_FRAME_LIMIT) {
        throw InvalidSnapshot{};
    }
    lua_createtable(L, bars, 0);
    for (int bar = 1; bar <= bars; ++bar) {
        pushRect(L, readRect(row));
        lua_rawseti(L, -2, bar);
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, "barFrames");
}

template<typename Push> void pushRowDetails(std::string_view &rows, RowLayout layout, Push push) {
    if (!layout.detailed) {
        return;
    }
    const auto length = readUnsigned<uint16_t>(rows);
    auto detail = takeBytes(rows, length);
    if (layout.pushesDetails && !detail.empty()) {
        push(detail);
        if (!detail.empty()) {
            throw InvalidSnapshot{};
        }
    }
}

constexpr int windowDetailFields = 15;
constexpr int workspaceDetailFields = 10;
constexpr int monitorDetailFields = 12;

void pushLookupRow(lua_State *L, std::string_view &rows, uint8_t kind, RowLayout layout) {
    const bool window = kind == OMNI_CONFIG_READ_WORKSPACE_WINDOWS || kind == OMNI_CONFIG_READ_WINDOWS;
    const bool workspace = kind == OMNI_CONFIG_READ_WORKSPACES;
    const int fields = window ? 8 + (layout.pushesFrames && layout.pushesColumns)
        : workspace ? 3 : 2 + 2 * layout.pushesFrames;
    const int details = window ? windowDetailFields : workspace ? workspaceDetailFields : monitorDetailFields;
    lua_createtable(L, 0, fields + (layout.pushesDetails ? details : 0));
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
        if (layout.columned) {
            const auto column = readUnsigned<uint16_t>(rows);
            if (layout.pushesColumns && column != 0) {
                lua_pushnumber(L, column);
                lua_rawsetfield(L, -2, "column");
            }
        }
        if (layout.framed && readUnsigned<uint8_t>(rows) == OMNI_CONFIG_FRAME_PRESENT) {
            readRectField(L, rows, "frame", layout.pushesFrames);
        }
        pushRowDetails(rows, layout, [&](std::string_view &detail) { pushWindowDetails(L, detail, flags); });
    } else {
        readStringField(L, rows, "name");
        if (workspace) {
            readStringField(L, rows, "monitor");
            pushRowDetails(rows, layout, [&](std::string_view &detail) { pushWorkspaceDetails(L, detail); });
        } else {
            if (layout.framed) {
                readRectField(L, rows, "frame", layout.pushesFrames);
                readRectField(L, rows, "visibleFrame", layout.pushesFrames);
            }
            pushRowDetails(rows, layout, [&](std::string_view &detail) { pushMonitorDetails(L, detail); });
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

void pushDwindleNode(lua_State *L, std::string_view &rows) {
    const auto tag = readUnsigned<uint8_t>(rows);
    lua_createtable(L, 0, 3);
    if (tag == OMNI_CONFIG_DWINDLE_SPLIT) {
        lua_pushstring(L, "split");
        lua_rawsetfield(L, -2, "kind");
        const auto orientation = readUnsigned<uint8_t>(rows);
        if (orientation > OMNI_CONFIG_DWINDLE_VERTICAL) {
            throw InvalidSnapshot{};
        }
        lua_pushstring(L, orientation == OMNI_CONFIG_DWINDLE_VERTICAL ? "vertical" : "horizontal");
        lua_rawsetfield(L, -2, "orientation");
        lua_pushnumber(L, readDouble(rows));
        lua_rawsetfield(L, -2, "ratio");
    } else if (tag == OMNI_CONFIG_DWINDLE_LEAF) {
        lua_pushstring(L, "leaf");
        lua_rawsetfield(L, -2, "kind");
        const auto active = readUnsigned<uint16_t>(rows);
        const auto members = readUnsigned<uint16_t>(rows);
        if (active == 0 || active > members) {
            throw InvalidSnapshot{};
        }
        lua_createtable(L, members, 0);
        for (int member = 1; member <= members; ++member) {
            const auto id = takeBytes(rows, readUnsigned<uint32_t>(rows));
            lua_pushlstring(L, id.data(), id.size());
            lua_rawseti(L, -2, member);
        }
        lua_setreadonly(L, -1, true);
        lua_rawsetfield(L, -2, "members");
        lua_pushnumber(L, active);
        lua_rawsetfield(L, -2, "active");
    } else {
        throw InvalidSnapshot{};
    }
    lua_setreadonly(L, -1, true);
}

void pushDwindle(lua_State *L, std::string_view &rows) {
    lua_createtable(L, 0, 4);
    readStringField(L, rows, "workspaceId");
    const auto count = readUnsigned<uint16_t>(rows);
    lua_createtable(L, count, 0);
    for (int node = 1; node <= count; ++node) {
        pushDwindleNode(L, rows);
        lua_rawseti(L, -2, node);
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, -2, "nodes");
    const auto preselect = readUnsigned<uint8_t>(rows);
    if (preselect > dwindleDirections.size()) {
        throw InvalidSnapshot{};
    }
    if (preselect != 0) {
        lua_pushstring(L, dwindleDirections[preselect - 1]);
        lua_rawsetfield(L, -2, "preselect");
    }
    readStringField(L, rows, "revision");
    lua_setreadonly(L, -1, true);
}

void pushLookups(lua_State *L, omni_config_span snapshot, uint32_t reads) {
    if (!snapshot.data) {
        throw InvalidSnapshot{};
    }
    const int context = lua_gettop(L);
    const auto fieldCount = __builtin_popcount(reads & (OMNI_CONFIG_READ_LISTS | OMNI_CONFIG_READ_DWINDLE));
    const auto requestedDetails = reads & detailsMask;
    lua_createtable(L, 0, fieldCount + (requestedDetails != 0));
    if (requestedDetails) {
        lua_createtable(L, 0, __builtin_popcount(requestedDetails));
        lua_rawsetfield(L, -2, detailsRead.data());
    }
    std::string_view input(snapshot.data, snapshot.length);
    while (!input.empty()) {
        const auto kind = readUnsigned<uint8_t>(input);
        const auto flags = readUnsigned<uint8_t>(input);
        const auto count = readUnsigned<uint16_t>(input);
        const auto length = readUnsigned<uint32_t>(input);
        auto rows = takeBytes(input, length);
        if (kind == OMNI_CONFIG_SECTION_DWINDLE) {
            if (!(reads & OMNI_CONFIG_READ_DWINDLE)) {
                continue;
            }
            reads &= ~OMNI_CONFIG_READ_DWINDLE;
            if ((flags & ~OMNI_CONFIG_SECTION_TRUNCATED) || count > 1) {
                throw InvalidSnapshot{};
            }
            lua_pushboolean(L, flags & OMNI_CONFIG_SECTION_TRUNCATED);
            lua_rawsetfield(L, -2, dwindleRead.data());
            if (count == 1) {
                pushDwindle(L, rows);
                lua_rawsetfield(L, context, dwindleRead.data());
            }
            if (!rows.empty()) {
                throw InvalidSnapshot{};
            }
            continue;
        }
        if (!(kind & reads)) {
            continue;
        }
        const auto bit = std::find(readBits.begin(), readBits.end(), kind);
        if (bit == readBits.end()) {
            throw InvalidSnapshot{};
        }
        reads &= ~kind;
        const RowLayout layout{
            .framed = (flags & OMNI_CONFIG_SECTION_FRAMES) != 0,
            .pushesFrames = (kind & framedLists) && (reads & (kind << OMNI_CONFIG_READ_FRAME_SHIFT)),
            .columned = (flags & OMNI_CONFIG_SECTION_COLUMNS) != 0,
            .pushesColumns = (kind & columnedLists) && (reads & (kind << OMNI_CONFIG_READ_COLUMN_SHIFT)),
            .detailed = (flags & OMNI_CONFIG_SECTION_DETAILS) != 0,
            .pushesDetails = (kind & detailedLists) && (requestedDetails & (kind << OMNI_CONFIG_READ_DETAIL_SHIFT)),
        };
        if ((layout.pushesFrames && !layout.framed) || (layout.pushesColumns && !layout.columned) ||
            (layout.columned && !(kind & columnedLists)) || (layout.pushesDetails && !layout.detailed) ||
            (layout.detailed && !(kind & detailedLists))) {
            throw InvalidSnapshot{};
        }
        const auto name = readNames[bit - readBits.begin()];
        lua_pushboolean(L, flags & OMNI_CONFIG_SECTION_TRUNCATED);
        lua_rawsetfield(L, -2, name);
        if (layout.pushesDetails) {
            lua_rawgetfield(L, -1, detailsRead.data());
            pushDetailFlag(L, name, flags & OMNI_CONFIG_SECTION_DETAILS_TRUNCATED);
            lua_pop(L, 1);
        }
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
                pushLookupRow(L, rows, kind, layout);
                lua_rawseti(L, -2, row);
            }
            lua_setreadonly(L, -1, true);
            lua_rawsetfield(L, context, name);
        }
        if (!rows.empty()) {
            throw InvalidSnapshot{};
        }
    }
    if (reads & (OMNI_CONFIG_READ_LISTS | OMNI_CONFIG_READ_DWINDLE)) {
        throw InvalidSnapshot{};
    }
    if (requestedDetails) {
        lua_rawgetfield(L, -1, detailsRead.data());
        lua_setreadonly(L, -1, true);
        lua_pop(L, 1);
    }
    lua_setreadonly(L, -1, true);
    lua_rawsetfield(L, context, "truncated");
}

void pushContext(lua_State *L, const omni_config_trigger &trigger, bool event, uint32_t reads) {
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
    lua_createtable(
        L, 0, capacity + (reads ? 1 + __builtin_popcount(reads & (OMNI_CONFIG_READ_LISTS | OMNI_CONFIG_READ_DWINDLE)) : 0));
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
    vm->storeWrites = 0;
    vm->storeUsed = false;
    vm->dwindleStaged = false;
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
        stats->store_used = vm->storeUsed;
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
