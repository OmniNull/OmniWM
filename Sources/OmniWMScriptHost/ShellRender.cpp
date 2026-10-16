// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <map>
#include <string>
#include <time.h>
#include <utility>
#include <unordered_set>

using namespace omni_detail;

namespace {

enum Atom : int16_t {
    AtomKind,
    AtomKey,
    AtomAxis,
    AtomWidth,
    AtomHeight,
    AtomGrow,
    AtomGap,
    AtomPadding,
    AtomCenter,
    AtomFill,
    AtomBorder,
    AtomBorderWidth,
    AtomRadius,
    AtomOpacity,
    AtomText,
    AtomReserve,
    AtomStyle,
    AtomColor,
    AtomName,
    AtomValue,
    AtomOnClick,
    AtomHover,
    AtomAnimate,
    AtomApp,
    AtomPopout,
    AtomSource,
    AtomValues,
    AtomFps,
    AtomAlign,
    AtomTarget,
    AtomMenu,
    AtomPreview,
    AtomDrag,
    AtomDrop,
    AtomDx,
    AtomDy,
    AtomScale,
    AtomShadow,
    AtomShadowRadius,
    AtomOnRightClick,
    AtomOnScroll,
    AtomSize,
    AtomWeight,
    AtomMaxWidth,
    AtomWindow,
    AtomPid,
    AtomPlaceholder,
    AtomHoverScale,
    AtomHoverOpacity,
    AtomHelp,
    AtomImage,
    AtomOnChange,
    AtomScroll,
    AtomMaterial,
    AtomHoverAnimate,
    AtomHoverMaterial,
    AtomLines,
    AtomBridge,
    AtomOpen,
    AtomClose,
    AtomEnter,
    AtomMask,
    AtomD,
    AtomViewBox,
    AtomEvenOdd,
    AtomAttach,
    AtomFont,
    AtomFilled,
    AtomRotate,
    AtomLoop,
    AtomTrail,
    AtomAudio,
    AtomPlaying,
    AtomSpeed,
    AtomOnHover,
    AtomOnPress,
    AtomOnGesture,
    AtomOnKey,
    AtomOnOutsidePress,
    AtomPressScale,
    AtomPressOpacity,
    AtomPressFill,
    AtomPressAnimate,
    AtomHoverDelay,
    AtomHoverGrace,
    AtomGesture,
    AtomGestureEvents,
    AtomFocusable,
    AtomFocusRing,
    AtomKeys,
    AtomScrollMomentum,
    AtomAppear,
    AtomExit,
    AtomOnCommit,
    AtomOnCancel,
    AtomOnFocus,
    AtomMaxLength,
    AtomMultiline,
    AtomFocus,
    AtomThumbnail,
    AtomAccepts,
    AtomOnDrop,
    AtomOnDropHover,
    AtomDragItems,
    AtomOnDragOut,
    AtomTexture,
    AtomBlurRadius,
    AtomSaturation,
    AtomCount
};

struct Name {
    const char *text;
    size_t length;
};

const Name atomNames[AtomCount] = {
    {"kind", 4}, {"key", 3}, {"axis", 4}, {"w", 1}, {"h", 1}, {"grow", 4}, {"gap", 3}, {"pad", 3}, {"center", 6},
    {"fill", 4}, {"border", 6}, {"borderWidth", 11}, {"radius", 6}, {"opacity", 7}, {"text", 4}, {"reserve", 7},
    {"style", 5}, {"color", 5}, {"name", 4}, {"value", 5}, {"onClick", 7}, {"hover", 5},
    {"animate", 7}, {"app", 3}, {"popout", 6}, {"source", 6}, {"values", 6}, {"fps", 3},
    {"align", 5}, {"target", 6}, {"menu", 4}, {"preview", 7}, {"drag", 4}, {"drop", 4},
    {"dx", 2}, {"dy", 2}, {"scale", 5}, {"shadow", 6}, {"shadowRadius", 12}, {"onRightClick", 12},
    {"onScroll", 8}, {"size", 4}, {"weight", 6}, {"maxWidth", 8},
    {"window", 6}, {"pid", 3}, {"placeholder", 11}, {"hoverScale", 10}, {"hoverOpacity", 12}, {"help", 4},
    {"image", 5}, {"onChange", 8}, {"scroll", 6}, {"material", 8}, {"hoverAnimate", 12},
    {"hoverMaterial", 13}, {"lines", 5}, {"bridge", 6}, {"open", 4}, {"close", 5}, {"enter", 5}, {"mask", 4}, {"d", 1}, {"viewBox", 7},
    {"evenOdd", 7}, {"attach", 6}, {"font", 4}, {"filled", 6}, {"rotate", 6}, {"loop", 4}, {"trail", 5}, {"audio", 5}, {"playing", 7}, {"speed", 5},
    {"onHover", 7}, {"onPress", 7}, {"onGesture", 9}, {"onKey", 5}, {"onOutsidePress", 14},
    {"pressScale", 10}, {"pressOpacity", 12}, {"pressFill", 9}, {"pressAnimate", 12},
    {"hoverDelay", 10}, {"hoverGrace", 10}, {"gesture", 7}, {"gestureEvents", 13},
    {"focusable", 9}, {"focusRing", 9}, {"keys", 4}, {"scrollMomentum", 14}, {"appear", 6}, {"exit", 4},
    {"onCommit", 8}, {"onCancel", 8}, {"onFocus", 7}, {"maxLength", 9}, {"multiline", 9}, {"focus", 5},
    {"thumbnail", 9}, {"accepts", 7}, {"onDrop", 6}, {"onDropHover", 11}, {"dragItems", 9}, {"onDragOut", 9}, {"texture", 7}, {"blurRadius", 10}, {"saturation", 10},
};

static_assert(sizeof(omni_wire_node) == 392);
static_assert(offsetof(omni_wire_node, resource_drag_ref) == 376);
static_assert(offsetof(omni_wire_node, resource_drag_action) == 380);
static_assert(offsetof(omni_wire_node, resource_image_ref) == 352);
static_assert(offsetof(omni_wire_node, texture_ref) == 372);

const Name axisNames[] = {{"row", 3}, {"column", 6}, {"stack", 5}};
const Name roleNames[] = {
    {"background", 10}, {"surface", 7}, {"elevatedSurface", 15}, {"foreground", 10},
    {"secondaryForeground", 19}, {"mutedForeground", 15}, {"border", 6}, {"accent", 6},
    {"accentForeground", 16}, {"success", 7}, {"warning", 7}, {"error", 5},
    {"focus", 5}, {"shadow", 6}, {"scrim", 5}, {"badge", 5}, {"red", 3}, {"orange", 6}, {"yellow", 6},
    {"green", 5}, {"mint", 4}, {"teal", 4}, {"cyan", 4}, {"blue", 4}, {"indigo", 6}, {"purple", 6}, {"pink", 4},
    {"brown", 5}, {"gray", 4}, {"highestSurface", 14}, {"accentContainer", 15}, {"accentContainerForeground", 25},
    {"secondaryAccent", 15}, {"secondaryContainer", 18}, {"secondaryContainerForeground", 28}, {"tertiaryAccent", 14},
    {"tertiaryContainer", 17}, {"tertiaryContainerForeground", 27},
};
constexpr size_t roleCount = sizeof roleNames / sizeof roleNames[0];
const Name styleNames[] = {{"body", 4}, {"bold", 4}, {"mono", 4}, {"small", 5}, {"caption", 7}, {"rounded", 7}};
constexpr size_t styleCount = sizeof styleNames / sizeof styleNames[0];
const Name fontNames[] = {{"system", 6}, {"sans", 4}, {"rubik", 5}, {"symbols", 7}};
constexpr size_t fontCount = sizeof fontNames / sizeof fontNames[0];
const Name weightNames[] = {
    {"ultraLight", 10}, {"thin", 4}, {"light", 5}, {"regular", 7}, {"medium", 6},
    {"semibold", 8}, {"bold", 4}, {"heavy", 5}, {"black", 5},
};
const Name materialNames[] = {
    {"none", 4}, {"ultraThin", 9}, {"thin", 4}, {"regular", 7}, {"thick", 5}, {"ultraThick", 10}, {"bar", 3},
    {"popover", 7}, {"glass", 5}, {"clear", 5},
};
constexpr size_t materialCount = sizeof materialNames / sizeof materialNames[0];
static_assert(materialCount == OMNI_MATERIAL_CLEAR + 1);
const Name motionNames[] = {{"none", 4}, {"spring", 6}, {"bouncy", 6}, {"smooth", 6}, {"ease", 4}};
const Name curveNames[] = {
    {"linear", 6}, {"easeIn", 6}, {"easeOut", 7}, {"easeInOut", 9}, {"back", 4},
    {"standard", 8}, {"standardAccel", 13}, {"standardDecel", 13},
    {"emphasized", 10}, {"emphasizedAccel", 15}, {"emphasizedDecel", 15},
    {"fastSpatial", 11}, {"spatial", 7}, {"slowSpatial", 11},
    {"fastEffects", 11}, {"effects", 7}, {"slowEffects", 11},
};
const uint8_t curveHundredths[] = {20, 20, 20, 20, 20, 40, 40, 40, 40, 40, 40, 35, 50, 65, 15, 20, 30};
constexpr size_t curveCount = sizeof curveNames / sizeof curveNames[0];
constexpr uint8_t defaultCurve = 3;
const Name alignNames[] = {
    {"center", 6}, {"leading", 7}, {"trailing", 8}, {"top", 3}, {"bottom", 6},
    {"topLeading", 10}, {"topTrailing", 11}, {"bottomLeading", 13}, {"bottomTrailing", 14},
};
const uint16_t alignValues[] = {0, 1, 2, 4, 8, 5, 6, 9, 10};

constexpr size_t maximumNodes = 4096;
constexpr double maximumExtent = 1.0e6;
constexpr double maximumDuration = 30;
constexpr int maximumDepth = 64;
constexpr uint32_t maximumEncodeSteps = 65536;
constexpr int maximumValueDepth = 16;
constexpr size_t maximumSelections = 256;
constexpr int actionsIndex = 2;
constexpr unsigned viewCount = 2;
const char *const viewEntries[viewCount] = {"render", "popout"};
const char *const missingEntries[viewCount] = {
    "the widget does not define a render function",
    "the widget does not define a popout function",
};

uint64_t fnv1a(const char *s, size_t length) {
    uint64_t hash = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < length; i++) {
        hash ^= static_cast<uint8_t>(s[i]);
        hash *= 0x100000001b3ull;
    }
    return hash;
}

int nameIndex(const Name *names, size_t count, const char *s, size_t length) {
    for (size_t i = 0; i < count; i++) {
        if (names[i].length == length && std::memcmp(names[i].text, s, length) == 0) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

}

namespace omni_detail {

struct DataSelection {
    uint64_t root = 0;
    std::array<int, maximumValueDepth + 1> path;
    int count = 0;
    int value = LUA_NOREF;

    DataSelection() {
        path.fill(LUA_NOREF);
    }
};

struct UnitMount {
    size_t offset;
    uint64_t unit;
    int contextRef = LUA_NOREF;
};

struct ResourceRead {
    omni_owner_token owner;
    omni_resource_id id;
};

bool sameResource(const ResourceRead &left, const ResourceRead &right) {
    return left.owner.generation == right.owner.generation && left.owner.owner == right.owner.owner
        && left.owner.epoch == right.owner.epoch && std::memcmp(left.id.bytes, right.id.bytes, 16) == 0;
}

struct ViewOutput {
    std::vector<UnitMount> mounts;
    std::vector<omni_wire_node> nodes;
    std::vector<uint8_t> output;
    int actionsRef = LUA_NOREF;
    std::vector<uint32_t> activities;
    std::vector<ResourceRead> resources;
    std::vector<DataSelection> selections;
    uint64_t deps = 0;
    uint64_t broadDeps = 0;
    bool ready = false;

};

struct ActionPublication {
    uint32_t first = 0;
    uint32_t count = 0;
    int ref = LUA_NOREF;
};

struct RenderUnit {
    uint64_t id = 0;
    omni_owner_token owner{};
    std::string name;
    int functionRef = LUA_NOREF;
    int contextRef = LUA_NOREF;
    ViewOutput cache;
    std::array<ActionPublication, OMNI_ACTION_HISTORY> actions{};
    int valueRef = LUA_NOREF;
    omni_status failure = OMNI_OK;
    bool live = true;
    bool actionDirty = false;
    bool actionChanged = false;
    bool dirty = true;
    uint64_t visited = 0;
    uint64_t attempted = 0;
};

struct MountInput {
    uint64_t unit;
    int functionRef = LUA_NOREF;
    int contextRef = LUA_NOREF;
};

struct RetainedSurface {
    RenderUnit root;
    std::vector<MountInput> pendingInputs;
    std::map<uint32_t, RenderUnit *> actions;
    std::unordered_map<uint64_t, std::unique_ptr<RenderUnit>> units;
    ViewOutput scratch;
    uint64_t nextUnit = 1;
    uint64_t pass = 0;
    bool active = false;
    bool visible = true;
    bool assemble = false;
    bool forcePublish = false;
};

}

struct omni_instance {
    omni_vm *vm = nullptr;
    uint32_t id = 0;
    lua_State *thread = nullptr;
    int threadRef = LUA_NOREF;
    int ctxRef = LUA_NOREF;
    int dataRef = LUA_NOREF;
    int stateRef = LUA_NOREF;
    uint64_t deps = 0;
    uint32_t encodeSteps = 0;
    uint32_t actionCount = 0;
    int componentContextIndex = 0;
    ViewOutput views[viewCount];
    ViewOutput *encoding = nullptr;
    RetainedSurface retained[viewCount];
    RetainedSurface *retaining = nullptr;
    std::unordered_map<uint32_t, std::unique_ptr<RenderUnit>> activities;
    uint64_t activityRevision = 0;
    uint32_t activityEvaluating = 0;
    uint64_t pendingActivityData = 0;
    uint64_t activityPass = 0;
    bool handling = false;
    std::vector<std::string> messages[2];
};

namespace {

omni_instance *scriptInstance(lua_State *L);

struct ComponentOwnerScope {
    lua_State *L;
    ShellPackage &package;
    int previous;
    omni_owner_token previousOwner;

    ComponentOwnerScope(lua_State *state, ShellPackage &value, int index)
         : L(state), package(value), previous(value.componentOwnerRef), previousOwner(scriptOwner(state)) {
        int next = index == 0 ? LUA_NOREF : lua_ref(L, index);
        try {
            switchScriptOwner(L, index);
        } catch (...) {
            lua_unref(L, next);
            throw;
        }
        package.componentOwnerRef = next;
    }

    ~ComponentOwnerScope() {
        lua_unref(L, package.componentOwnerRef);
        package.componentOwnerRef = previous;
        restoreScriptOwner(L, previousOwner);
    }
};

struct ComponentEncodeScope {
    omni_instance *instance;
    int previous;

    ComponentEncodeScope(omni_instance *value, int index) : instance(value), previous(value->componentContextIndex) {
        instance->componentContextIndex = index;
    }

    ~ComponentEncodeScope() {
        instance->componentContextIndex = previous;
    }
};

void clearSelections(lua_State *L, ViewOutput &view) {
    for (DataSelection &selection : view.selections) {
        for (int index = 0; index < selection.count; index++) {
            lua_unref(L, selection.path[index]);
        }
        lua_unref(L, selection.value);
    }
    view.selections.clear();
    view.deps = 0;
    view.broadDeps = 0;
    view.ready = false;
}

uint32_t unsignedValue(lua_State *L, int index, double maximum) {
    double value = lua_tonumber(L, index);
    if (!(value > 0)) {
        return 0;
    }
    return static_cast<uint32_t>(value >= maximum ? maximum : value);
}

float floatValue(lua_State *L, int index) {
    double value = lua_tonumber(L, index);
    return std::isfinite(value) ? static_cast<float>(std::clamp(value, -maximumExtent, maximumExtent)) : 0;
}

float durationValue(lua_State *L, int index) {
    double value = lua_tonumber(L, index);
    return std::isfinite(value) ? static_cast<float>(std::clamp(value, 0.0, maximumDuration)) : 0;
}

uint8_t enumValue(lua_State *L, int index, const Name *names, size_t count);

constexpr size_t motionPresets = sizeof motionNames / sizeof motionNames[0];

uint8_t easeMotion(double seconds) {
    double hundredths = std::round(seconds * 100.0);
    if (!std::isfinite(hundredths) || hundredths < 1) {
        return 0;
    }
    return static_cast<uint8_t>(motionPresets - 1 + std::fmin(hundredths, 255.0 - (motionPresets - 1)));
}

uint8_t motionValue(lua_State *L, int index) {
    if (lua_type(L, index) != LUA_TNUMBER) {
        return enumValue(L, index, motionNames, motionPresets);
    }
    return easeMotion(lua_tonumber(L, index));
}

uint8_t enumValue(lua_State *L, int index, const Name *names, size_t count) {
    if (lua_type(L, index) == LUA_TSTRING) {
        size_t length = 0;
        const char *s = lua_tolstring(L, index, &length);
        int found = nameIndex(names, count, s, length);
        return static_cast<uint8_t>(found < 0 ? 0 : found);
    }
    return static_cast<uint8_t>(unsignedValue(L, index, static_cast<double>(count - 1)));
}

void countSteps(lua_State *L, omni_instance *instance, size_t steps) {
    instance->encodeSteps += static_cast<uint32_t>(std::min(steps, static_cast<size_t>(maximumEncodeSteps) + 1));
    if (instance->encodeSteps > maximumEncodeSteps) {
        luaL_error(L, "tree encode exceeded %u steps", maximumEncodeSteps);
    }
}

uint32_t internValue(lua_State *L, int index, omni_instance *instance);
uint32_t internString(lua_State *L, const char *s, size_t length, omni_instance *instance);

template <typename Number>
void appendNumber(lua_State *L, std::string &result, Number value) {
    char buffer[64];
    if (value == 0) value = 0;
    auto encoded = std::to_chars(buffer, buffer + sizeof buffer, value);
    if (encoded.ec != std::errc{}) { luaL_error(L, "motion number cannot be encoded"); }
    result.append(buffer, encoded.ptr);
}

bool readSpring(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    if (!lua_istable(L, -1)) return false;
    luaL_checkstack(L, 2, "spring");
    int table = lua_gettop(L);
    lua_rawgetfield(L, table, "response");
    lua_rawgetfield(L, table, "bounce");
    if (lua_isnil(L, -2) && lua_isnil(L, -1)) {
        lua_pop(L, 2);
        return false;
    }
    double response = lua_tonumber(L, -2);
    double bounce = lua_isnil(L, -1) ? 0 : lua_tonumber(L, -1);
    if (lua_type(L, -2) != LUA_TNUMBER || !std::isfinite(response) || response < 0.05 || response > 2.5) {
        luaL_error(L, "spring response must be a finite number between 0.05 and 2.5");
    }
    if ((!lua_isnil(L, -1) && lua_type(L, -1) != LUA_TNUMBER) || !std::isfinite(bounce) || bounce < 0 || bounce > 0.95) {
        luaL_error(L, "spring bounce must be a finite number between 0 and 0.95");
    }
    lua_pop(L, 2);
    for (const char *field : {"duration", "curve"}) {
        lua_rawgetfield(L, table, field);
        if (!lua_isnil(L, -1)) { luaL_error(L, "a spring cannot also specify %s", field); }
        lua_pop(L, 1);
    }
    std::string recipe = "spring:";
    recipe.reserve(96);
    appendNumber(L, recipe, response);
    recipe += ':';
    appendNumber(L, recipe, bounce);
    if (recipe.size() > 96) { luaL_error(L, "spring recipe exceeds its size limit"); }
    node.motion = 1;
    node.motion_curve = OMNI_CURVE_CUSTOM;
    node.motion_curve_ref = internString(L, recipe.data(), recipe.size(), instance);
    return true;
}

uint8_t readCurve(lua_State *L, uint32_t &ref, omni_instance *instance) {
    ref = 0;
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t length = 0;
        const char *s = lua_tolstring(L, -1, &length);
        int found = nameIndex(curveNames, curveCount, s, length);
        return found < 0 ? 0 : static_cast<uint8_t>(found + 1);
    }
    if (!lua_istable(L, -1)) {
        return 0;
    }
    constexpr int maximumPoints = 48;
    int count = lua_objlen(L, -1);
    if (count > maximumPoints || (count != 4 && (count == 0 || count % 6 != 0))) {
        luaL_error(L, "curve must be a curve name, 4 numbers, or 6 numbers per segment");
    }
    char buffer[maximumPoints * 16];
    size_t length = 0;
    for (int i = 1; i <= count; i++) {
        lua_rawgeti(L, -1, i);
        double value = lua_tonumber(L, -1);
        if (lua_type(L, -1) != LUA_TNUMBER || !std::isfinite(value)) {
            luaL_error(L, "curve points must be numbers");
        }
        lua_pop(L, 1);
        if (i > 1) buffer[length++] = ',';
        if (value == 0) value = 0;
        auto encoded = std::to_chars(buffer + length, buffer + sizeof buffer, value, std::chars_format::general, 6);
        if (encoded.ec != std::errc{}) { luaL_error(L, "curve exceeds its encoded size limit"); }
        length = static_cast<size_t>(encoded.ptr - buffer);
    }
    ref = internString(L, buffer, length, instance);
    return OMNI_CURVE_CUSTOM;
}

void readLoop(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    if (!lua_istable(L, -1)) {
        luaL_error(L, "loop must be a table such as { rotate = { 0, 360, 20 } }");
    }
    char buffer[160];
    size_t length = 0;
    for (const char *channel : {"dx", "dy", "rotate"}) {
        lua_rawgetfield(L, -1, channel);
        if (lua_istable(L, -1)) {
            double values[3];
            for (int i = 0; i < 3; i++) {
                lua_rawgeti(L, -1, i + 1);
                values[i] = lua_tonumber(L, -1);
                if (lua_type(L, -1) != LUA_TNUMBER || !std::isfinite(values[i])) {
                    luaL_error(L, "loop.%s must be { from, to, seconds }", channel);
                }
                lua_pop(L, 1);
            }
            if (std::strcmp(channel, "rotate") == 0 && std::fabs(values[1] - values[0]) > 3600) {
                luaL_error(L, "loop.rotate turns at most 3600 degrees");
            }
            if (values[2] > 0) {
                length += static_cast<size_t>(std::snprintf(
                    buffer + length, sizeof buffer - length, "%s%s %.6g %.6g %.6g",
                    length > 0 ? ";" : "", channel, values[0], values[1], values[2]
                ));
            }
        }
        lua_pop(L, 1);
    }
    lua_rawgetfield(L, -1, "paused");
    bool paused = lua_toboolean(L, -1);
    lua_pop(L, 1);
    node.options = static_cast<uint8_t>(
        paused ? node.options | OMNI_NODE_OPTION_LOOP_PAUSED : node.options & ~OMNI_NODE_OPTION_LOOP_PAUSED
    );
    node.loop = length > 0 ? internString(L, buffer, std::min(length, sizeof buffer - 1), instance) : 0;
}

void readAnimate(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    node.motion_curve = 0;
    node.motion_curve_ref = 0;
    if (readSpring(L, node, instance)) return;
    if (lua_type(L, -1) == LUA_TSTRING || lua_istable(L, -1)) {
        bool table = lua_istable(L, -1);
        if (table) {
            lua_rawgetfield(L, -1, "curve");
        }
        uint8_t curve = readCurve(L, node.motion_curve_ref, instance);
        if (table) {
            lua_pop(L, 1);
        }
        if (curve != 0 || table) {
            node.motion_curve = curve;
            double seconds = curve > 0 && curve <= curveCount ? curveHundredths[curve - 1] / 100.0 : 0.2;
            if (table) {
                lua_rawgetfield(L, -1, "duration");
                if (lua_type(L, -1) == LUA_TNUMBER) {
                    seconds = lua_tonumber(L, -1);
                }
                lua_pop(L, 1);
            }
            node.motion = easeMotion(seconds);
            return;
        }
    }
    node.motion = motionValue(L, -1);
}

float enterNumber(lua_State *L, const char *key, float fallback) {
    lua_rawgetfield(L, -1, key);
    float value = lua_type(L, -1) == LUA_TNUMBER ? floatValue(L, -1) : fallback;
    lua_pop(L, 1);
    return value;
}

uint8_t enterFraction(lua_State *L, const char *key, uint8_t fallback) {
    float value = enterNumber(L, key, fallback / 255.0f);
    return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255));
}

void readEnter(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    if (!lua_istable(L, -1)) {
        luaL_error(L, "enter must be a table such as { opacity = 0, from = 0.5 }");
    }
    countSteps(L, instance, 8);
    node.enter_opacity = std::clamp(enterNumber(L, "opacity", 1), 0.0f, 1.0f);
    node.enter_scale = std::fmax(0.0f, enterNumber(L, "scale", 1));
    node.enter_dx = enterNumber(L, "dx", 0);
    node.enter_dy = enterNumber(L, "dy", 0);
    node.enter_stretch = std::fmax(0.0f, enterNumber(L, "stretch", 0));
    node.enter_from = enterFraction(L, "from", 0);
    node.enter_to = enterFraction(L, "to", 255);
    lua_rawgetfield(L, -1, "curve");
    uint8_t curve = readCurve(L, node.enter_curve_ref, instance);
    lua_pop(L, 1);
    node.enter_curve = curve == 0 ? defaultCurve : curve;
    lua_rawgetfield(L, -1, "d");
    node.enter_path = internValue(L, -1, instance);
    lua_pop(L, 1);
}

uint32_t internValue(lua_State *L, int index, omni_instance *instance) {
    ShellPackage &package = instance->vm->package;
    const char *s = nullptr;
    size_t length = 0;
    char buffer[32];
    switch (lua_type(L, index)) {
    case LUA_TSTRING:
        s = lua_tolstring(L, index, &length);
        break;
    case LUA_TNUMBER:
        length = static_cast<size_t>(std::snprintf(buffer, sizeof buffer, "%.14g", lua_tonumber(L, index)));
        s = buffer;
        break;
    default:
        return 0;
    }
    return internString(L, s, length, instance);
}

uint32_t internString(lua_State *L, const char *s, size_t length, omni_instance *instance) {
    ShellPackage &package = instance->vm->package;
    countSteps(L, instance, length >> 6);
    bool added = false;
    uint32_t id = package.strings.intern(s, length, added);
    if (added) {
        omni_wire_string record{id, static_cast<uint32_t>(length)};
        auto *bytes = reinterpret_cast<const uint8_t *>(&record);
        package.pendingStrings.insert(package.pendingStrings.end(), bytes, bytes + sizeof record);
        package.pendingStrings.insert(package.pendingStrings.end(), s, s + length);
        package.pendingStrings.resize((package.pendingStrings.size() + 3) & ~size_t(3), 0);
        package.pendingCount++;
    }
    return id;
}

uint64_t keyValue(lua_State *L, int index, omni_instance *instance) {
    switch (lua_type(L, index)) {
    case LUA_TSTRING: {
        size_t length = 0;
        const char *s = lua_tolstring(L, index, &length);
        countSteps(L, instance, length >> 6);
        uint64_t hash = fnv1a(s, length) & ~(3ull << 62);
        return hash == 0 ? 1 : hash;
    }
    case LUA_TNUMBER: {
        double value = lua_tonumber(L, index);
        if (!std::isfinite(value)) {
            return 0;
        }
        value = std::fmax(-4.0e18, std::fmin(4.0e18, value));
        return (static_cast<uint64_t>(static_cast<int64_t>(value)) & ~(3ull << 62)) | (1ull << 62);
    }
    default:
        return 0;
    }
}

uint32_t actionValue(lua_State *L, omni_instance *instance) {
    if (lua_tocfunction(L, -1) == popoutAction) {
        return OMNI_ACTION_POPOUT;
    }
    if (!lua_isfunction(L, -1)) {
        return internValue(L, -1, instance);
    }
    if (!lua_istable(L, actionsIndex)) {
        lua_createtable(L, 4, 0);
        lua_replace(L, actionsIndex);
    }
    if (instance->componentContextIndex != 0) {
        int function = lua_gettop(L);
        lua_createtable(L, 2, 0);
        lua_pushvalue(L, function);
        lua_rawseti(L, -2, 1);
        lua_pushvalue(L, instance->componentContextIndex);
        lua_rawseti(L, -2, 2);
    } else {
        lua_pushvalue(L, -1);
    }
    lua_rawseti(L, actionsIndex, static_cast<int>(++instance->actionCount));
    return OMNI_ACTION_HANDLER | instance->actionCount;
}

uint32_t inputAction(lua_State *L, omni_instance *instance, const char *name) {
    if (lua_isnil(L, -1)) return 0;
    if (!lua_isfunction(L, -1) || lua_tocfunction(L, -1) == popoutAction) {
        luaL_error(L, "%s must be a callback function", name);
    }
    return actionValue(L, instance);
}

int hexDigit(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

bool hexColor(const char *s, size_t length, uint32_t &packed) {
    if ((length != 7 && length != 9) || s[0] != '#') {
        return false;
    }
    uint32_t value = 0;
    for (size_t i = 1; i < length; i++) {
        int digit = hexDigit(s[i]);
        if (digit < 0) {
            return false;
        }
        value = (value << 4) | static_cast<uint32_t>(digit);
    }
    packed = length == 7 ? (value << 8) | 0xFF : value;
    return true;
}

void colorValue(lua_State *L, uint32_t &packed, uint16_t &role) {
    packed = 0;
    role = 0;
    if (lua_type(L, -1) != LUA_TSTRING) {
        packed = unsignedValue(L, -1, 4294967295.0);
        return;
    }
    size_t length = 0;
    const char *s = lua_tolstring(L, -1, &length);
    if (hexColor(s, length, packed)) {
        return;
    }
    const char *slash = static_cast<const char *>(std::memchr(s, '/', length));
    size_t nameLength = slash ? static_cast<size_t>(slash - s) : length;
    int index = nameIndex(roleNames, roleCount, s, nameLength);
    double alpha = 1;
    if (slash != nullptr) {
        char buffer[32];
        size_t digits = length - nameLength - 1;
        if (digits == 0 || digits >= sizeof buffer) {
            index = -1;
        } else {
            std::memcpy(buffer, slash + 1, digits);
            buffer[digits] = '\0';
            char *end = nullptr;
            alpha = std::strtod(buffer, &end);
            if (end != buffer + digits || !(alpha >= 0 && alpha <= 1)) {
                index = -1;
            }
        }
    }
    if (index < 0) {
        luaL_error(L, "unknown color \"%s\"", s);
    }
    role = static_cast<uint16_t>((index + 1) | (static_cast<int>(std::lround(alpha * 255)) << 8));
}

float inputNumber(lua_State *L, int index, const char *name, double minimum, double maximum) {
    double value = lua_tonumber(L, index);
    if (lua_type(L, index) != LUA_TNUMBER || !std::isfinite(value) || value < minimum || value > maximum) {
        luaL_error(L, "%s must be a finite number between %.6g and %.6g", name, minimum, maximum);
    }
    return static_cast<float>(value);
}

float inputField(lua_State *L, const char *name, float fallback, double minimum, double maximum) {
    lua_rawgetfield(L, -1, name);
    float value = lua_isnil(L, -1) ? fallback : inputNumber(L, -1, name, minimum, maximum);
    lua_pop(L, 1);
    return value;
}

uint8_t inputEnum(lua_State *L, const char *name, const Name *names, size_t count) {
    size_t length = 0;
    const char *value = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : nullptr;
    int found = value == nullptr ? -1 : nameIndex(names, count, value, length);
    if (found < 0) { luaL_error(L, "invalid %s value", name); }
    return static_cast<uint8_t>(found);
}

uint32_t readPresence(lua_State *L, omni_instance *instance) {
    if (!lua_istable(L, -1)) { luaL_error(L, "appear and exit must be tables"); }
    luaL_checkstack(L, 4, "lifecycle motion");
    std::string recipe = "life";
    recipe.reserve(128);
    for (const char *field : {"opacity", "scale", "dx", "dy"}) {
        bool opacity = std::strcmp(field, "opacity") == 0;
        bool scale = std::strcmp(field, "scale") == 0;
        float value = inputField(L, field, opacity || scale ? 1 : 0,
            opacity || scale ? 0 : -maximumExtent, opacity ? 1 : maximumExtent);
        recipe += ':';
        appendNumber(L, recipe, value);
    }
    lua_rawgetfield(L, -1, "animate");
    if (lua_isnil(L, -1)) {
        recipe += ":inherit";
    } else {
        omni_wire_node animation{};
        readAnimate(L, animation, instance);
        recipe += ':';
        appendNumber(L, recipe, static_cast<unsigned>(animation.motion));
        recipe += ':';
        appendNumber(L, recipe, static_cast<unsigned>(animation.motion_curve));
        recipe += ':';
        if (animation.motion_curve_ref != 0) {
            const InternTable &strings = instance->vm->package.strings;
            uint32_t ref = animation.motion_curve_ref;
            recipe.append(strings.arena.data() + strings.offsets[ref], strings.lengths[ref]);
        }
    }
    lua_pop(L, 1);
    if (recipe.size() > 1536) { luaL_error(L, "lifecycle recipe exceeds its size limit"); }
    return internString(L, recipe.data(), recipe.size(), instance);
}

void readTrack(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    luaL_checkstack(L, 3, "gesture track");
    lua_rawgetfield(L, -1, "track");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return; }
    if (!lua_istable(L, -1)) { luaL_error(L, "gesture.track must be a table"); }
    if (node.gesture_commit_distance <= 0) { luaL_error(L, "gesture.track requires a positive commit.distance"); }
    const char *channels[] = {"dx", "dy", "scale", "opacity"};
    float values[12] = {0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0};
    unsigned mask = 0;
    for (unsigned channel = 0; channel < 4; channel++) {
        lua_rawgetfield(L, -1, channels[channel]);
        if (!lua_isnil(L, -1)) {
            if (!lua_istable(L, -1) || lua_objlen(L, -1) != 2) {
                luaL_error(L, "gesture.track.%s must contain from and to values", channels[channel]);
            }
            for (int index = 0; index < 2; index++) {
                lua_rawgeti(L, -1, index + 1);
                values[channel * 3 + index] = inputNumber(L, -1, channels[channel],
                    channel < 2 ? -maximumExtent : 0, channel == 3 ? 1 : maximumExtent);
                lua_pop(L, 1);
            }
            values[channel * 3 + 2] = inputField(L, "rubber", 0, 0, 1);
            mask |= 1u << channel;
        }
        lua_pop(L, 1);
    }
    if (mask == 0) { luaL_error(L, "gesture.track requires at least one channel"); }
    std::string recipe = "track:";
    recipe.reserve(384);
    appendNumber(L, recipe, mask);
    for (float value : values) {
        recipe += ':';
        appendNumber(L, recipe, value);
    }
    if (recipe.size() > 384) { luaL_error(L, "tracking recipe exceeds its size limit"); }
    node.gesture_track = internString(L, recipe.data(), recipe.size(), instance);
    lua_pop(L, 1);
}

void readGesture(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    if (!lua_istable(L, -1)) { luaL_error(L, "gesture must be a table"); }
    const Name axes[] = {{"none", 4}, {"x", 1}, {"y", 1}, {"free", 4}, {"auto", 4}};
    const Name sources[] = {{"pointer", 7}, {"scroll", 6}, {"both", 4}};
    const Name directions[] = {{"any", 3}, {"left", 4}, {"right", 5}, {"up", 2}, {"down", 4}};
    lua_rawgetfield(L, -1, "axis");
    node.gesture_axis = lua_isnil(L, -1) ? 4 : inputEnum(L, "gesture.axis", axes, 5);
    lua_pop(L, 1);
    lua_rawgetfield(L, -1, "source");
    node.gesture_source = lua_isnil(L, -1) ? 0 : inputEnum(L, "gesture.source", sources, 3);
    lua_pop(L, 1);
    node.gesture_threshold = inputField(L, "threshold", 4, 0, maximumExtent);
    node.gesture_lock_distance = inputField(L, "lockDistance", 1, 0, maximumExtent);
    node.gesture_dominance = inputField(L, "dominance", 1.25f, 1, maximumExtent);
    lua_rawgetfield(L, -1, "commit");
    if (!lua_isnil(L, -1)) {
        if (!lua_istable(L, -1)) { luaL_error(L, "gesture.commit must be a table"); }
        node.gesture_commit_distance = inputField(L, "distance", 0, 0, maximumExtent);
        node.gesture_commit_velocity = inputField(L, "velocity", 0, 0, maximumExtent);
        lua_rawgetfield(L, -1, "direction");
        node.gesture_direction = lua_isnil(L, -1) ? 0 : inputEnum(L, "gesture.commit.direction", directions, 5);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    readTrack(L, node, instance);
}

void readKeys(lua_State *L, omni_wire_node &node, omni_instance *instance) {
    if (!lua_istable(L, -1)) { luaL_error(L, "keys must be a list of names"); }
    int table = lua_gettop(L);
    int length = lua_objlen(L, table);
    if (length > 64) { luaL_error(L, "keys may declare at most 64 names"); }
    std::vector<std::string> names;
    names.reserve(static_cast<size_t>(length));
    int iterator = 0;
    while ((iterator = lua_rawiter(L, table, iterator)) >= 0) {
        countSteps(L, instance, 1);
        double key = lua_tonumber(L, -2);
        if (lua_type(L, -2) != LUA_TNUMBER || key < 1 || key > length || key != std::trunc(key)) {
            luaL_error(L, "keys must be a dense list of names");
        }
        size_t size = 0;
        const char *value = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &size) : nullptr;
        if (value == nullptr || size == 0 || size > 32) { luaL_error(L, "key names must contain 1 to 32 bytes"); }
        std::string name(value, size);
        for (char &character : name) {
            unsigned char byte = static_cast<unsigned char>(character);
            if (byte < 32 || byte == 127) { luaL_error(L, "key names cannot contain control characters"); }
            if (character >= 'A' && character <= 'Z') { character = static_cast<char>(character + ('a' - 'A')); }
        }
        names.push_back(std::move(name));
        lua_pop(L, 2);
    }
    if (names.size() != static_cast<size_t>(length)) { luaL_error(L, "keys must be a dense list of names"); }
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    std::string joined;
    for (const std::string &name : names) {
        if (!joined.empty()) { joined += '\n'; }
        joined += name;
    }
    node.keys = joined.empty() ? 0 : internString(L, joined.data(), joined.size(), instance);
}

void readField(lua_State *L, int atom, omni_wire_node &node, omni_instance *instance) {
    switch (atom) {
    case AtomKind: node.kind = static_cast<uint8_t>(unsignedValue(L, -1, 255)); break;
    case AtomKey: node.key = keyValue(L, -1, instance); break;
    case AtomAxis: node.axis = enumValue(L, -1, axisNames, 3); break;
    case AtomWidth: node.width = floatValue(L, -1); break;
    case AtomHeight: node.height = floatValue(L, -1); break;
    case AtomGrow: node.grow = std::fmax(0.0f, floatValue(L, -1)); break;
    case AtomGap: node.gap = floatValue(L, -1); break;
    case AtomPadding: node.padding = floatValue(L, -1); break;
    case AtomCenter: node.center_cross = lua_toboolean(L, -1) ? 1 : 0; break;
    case AtomFill: colorValue(L, node.fill, node.fill_role); break;
    case AtomBorder: colorValue(L, node.stroke, node.stroke_role); break;
    case AtomBorderWidth: node.stroke_width = floatValue(L, -1); break;
    case AtomRadius: node.corner_radius = floatValue(L, -1); break;
    case AtomOpacity: node.opacity = floatValue(L, -1); break;
    case AtomText: node.text = internValue(L, -1, instance); break;
    case AtomReserve: node.reserve = internValue(L, -1, instance); break;
    case AtomStyle:
        node.style = static_cast<uint16_t>((node.style & ~OMNI_STYLE_BASE_MASK) | enumValue(L, -1, styleNames, styleCount));
        break;
    case AtomWeight:
        node.style = static_cast<uint16_t>(
            (node.style & ~OMNI_STYLE_WEIGHT_MASK) | ((enumValue(L, -1, weightNames, 9) + 1) << OMNI_STYLE_WEIGHT_SHIFT)
        );
        break;
    case AtomFont:
        node.style = static_cast<uint16_t>(
            (node.style & ~OMNI_STYLE_FONT_MASK) | (enumValue(L, -1, fontNames, fontCount) << OMNI_STYLE_FONT_SHIFT)
        );
        break;
    case AtomFilled:
        node.style = static_cast<uint16_t>(
            lua_toboolean(L, -1) ? node.style | OMNI_STYLE_FILLED : node.style & ~OMNI_STYLE_FILLED
        );
        break;
    case AtomRotate: {
        node.rotate = floatValue(L, -1);
        double quarter = std::fmod(std::fabs(node.rotate), 180.0);
        node.style = static_cast<uint16_t>(
            quarter == 90.0 ? node.style | OMNI_STYLE_QUARTER : node.style & ~OMNI_STYLE_QUARTER
        );
        break;
    }
    case AtomLoop: readLoop(L, node, instance); break;
    case AtomTrail:
        node.options = static_cast<uint8_t>(
            lua_toboolean(L, -1) ? node.options | OMNI_NODE_OPTION_TRAIL : node.options & ~OMNI_NODE_OPTION_TRAIL
        );
        break;
    case AtomSize: {
        double size = lua_tonumber(L, -1);
        node.text_size = size > 0 ? static_cast<uint16_t>(std::lround(std::min(size, 655.35) * 100)) : 0;
        break;
    }
    case AtomMaxWidth: node.max_width = std::fmax(0.0f, floatValue(L, -1)); break;
    case AtomWindow:
        node.icon_ref = internValue(L, -1, instance);
        node.flags = static_cast<uint16_t>((node.flags & ~OMNI_NODE_ICON_MASK) | OMNI_NODE_ICON_WINDOW);
        break;
    case AtomPid:
        node.icon_ref = internValue(L, -1, instance);
        node.flags = static_cast<uint16_t>((node.flags & ~OMNI_NODE_ICON_MASK) | OMNI_NODE_ICON_PID);
        break;
    case AtomPlaceholder: node.placeholder = internValue(L, -1, instance); break;
    case AtomHoverScale: node.hover_scale = std::fmax(0.0f, floatValue(L, -1)); break;
    case AtomHoverOpacity: node.hover_opacity = std::fmin(1.0f, std::fmax(0.0f, floatValue(L, -1))); break;
    case AtomHelp: node.help = internValue(L, -1, instance); break;
    case AtomImage: {
        std::string recipe;
        if (resourceImage(L, -1, recipe)) {
            node.resource_image_ref = internString(L, recipe.data(), recipe.size(), instance);
        } else {
            node.text = internValue(L, -1, instance);
        }
        break;
    }
    case AtomTexture:
        if (lua_type(L, -1) != LUA_TSTRING) { luaL_error(L, "texture must be an image path"); }
        node.texture_ref = internValue(L, -1, instance);
        break;
    case AtomBlurRadius: node.blur_radius = inputNumber(L, -1, "blurRadius", 0, 64); break;
    case AtomSaturation: node.saturation = inputNumber(L, -1, "saturation", 0, 3); break;
    case AtomThumbnail: node.thumbnail = inputNumber(L, -1, "thumbnail", 1, 2048); break;
    case AtomDragItems:
        if (!lua_isnil(L, -1)) {
            pushResourceDrag(L, lua_gettop(L));
            node.resource_drag_ref = actionValue(L, instance);
            lua_pop(L, 1);
        }
        break;
    case AtomOnDragOut: node.resource_drag_action = inputAction(L, instance, "onDragOut"); break;
    case AtomOnDrop: node.resource_drop_action = inputAction(L, instance, "onDrop"); break;
    case AtomOnDropHover: node.resource_hover_action = inputAction(L, instance, "onDropHover"); break;
    case AtomAccepts: {
        if (!lua_istable(L, -1)) { luaL_error(L, "accepts must be an array"); }
        int table = lua_gettop(L);
        int count = lua_objlen(L, table);
        if (count > 4) { luaL_error(L, "accepts supports at most four resource types"); }
        int entries = 0;
        lua_pushnil(L);
        while (lua_next(L, table) != 0) {
            entries++;
            bool validKey = lua_type(L, -2) == LUA_TNUMBER && lua_tonumber(L, -2) >= 1
                && lua_tonumber(L, -2) <= count && std::floor(lua_tonumber(L, -2)) == lua_tonumber(L, -2);
            if (!validKey || lua_type(L, -1) != LUA_TSTRING) { luaL_error(L, "accepts must be a dense array of resource types"); }
            size_t length = 0;
            const char *value = lua_tolstring(L, -1, &length);
            uint32_t flag = length == 4 && std::memcmp(value, "file", 4) == 0 ? OMNI_RESOURCE_ACCEPT_FILE
                : length == 3 && std::memcmp(value, "url", 3) == 0 ? OMNI_RESOURCE_ACCEPT_URL
                : length == 4 && std::memcmp(value, "text", 4) == 0 ? OMNI_RESOURCE_ACCEPT_TEXT
                : length == 5 && std::memcmp(value, "image", 5) == 0 ? OMNI_RESOURCE_ACCEPT_IMAGE : 0;
            if (flag == 0) { luaL_error(L, "accepts contains an unknown resource type"); }
            node.resource_accepts |= flag;
            lua_pop(L, 1);
        }
        if (entries != count) { luaL_error(L, "accepts must be a dense array"); }
        break;
    }
    case AtomOnChange: node.action = actionValue(L, instance); break;
    case AtomMaterial:
        node.flags = static_cast<uint16_t>(
            (node.flags & ~OMNI_NODE_MATERIAL_MASK) | (enumValue(L, -1, materialNames, materialCount) << OMNI_NODE_MATERIAL_SHIFT)
        );
        break;
    case AtomScroll:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_SCROLL;
        }
        break;
    case AtomColor: colorValue(L, node.color, node.color_role); break;
    case AtomName:
    case AtomApp: node.text = internValue(L, -1, instance); break;
    case AtomValue: {
        double value = lua_tonumber(L, -1);
        node.series = std::isfinite(value) ? static_cast<uint32_t>(std::fmax(0, std::fmin(1, value)) * 1000) : 0;
        break;
    }
    case AtomOnClick: node.action = actionValue(L, instance); break;
    case AtomOnHover: node.hover_action = inputAction(L, instance, "onHover"); break;
    case AtomOnPress: node.press_action = inputAction(L, instance, "onPress"); break;
    case AtomOnGesture: node.gesture_action = inputAction(L, instance, "onGesture"); break;
    case AtomOnKey: node.key_action = inputAction(L, instance, "onKey"); break;
    case AtomOnOutsidePress: node.outside_press_action = inputAction(L, instance, "onOutsidePress"); break;
    case AtomPressScale:
        node.press_scale = inputNumber(L, -1, "pressScale", 0, maximumExtent);
        node.input_flags |= OMNI_INPUT_PRESS_SCALE;
        break;
    case AtomPressOpacity: node.press_opacity = inputNumber(L, -1, "pressOpacity", 0, 1); break;
    case AtomPressFill:
        colorValue(L, node.press_fill, node.press_fill_role);
        node.input_flags |= OMNI_INPUT_PRESS_FILL;
        break;
    case AtomPressAnimate: {
        omni_wire_node animation{};
        readAnimate(L, animation, instance);
        node.press_motion = animation.motion;
        node.press_motion_curve = animation.motion_curve;
        node.press_motion_curve_ref = animation.motion_curve_ref;
        break;
    }
    case AtomOnCommit: node.input_commit_action = inputAction(L, instance, "onCommit"); break;
    case AtomOnCancel: node.input_cancel_action = inputAction(L, instance, "onCancel"); break;
    case AtomOnFocus: node.input_focus_action = inputAction(L, instance, "onFocus"); break;
    case AtomMaxLength: {
        inputNumber(L, -1, "maxLength", 0, 65536);
        double value = lua_tonumber(L, -1);
        if (std::floor(value) != value) { luaL_error(L, "maxLength must be an integer"); }
        node.input_max_length = static_cast<uint32_t>(value);
        break;
    }
    case AtomMultiline:
        if (!lua_isboolean(L, -1)) { luaL_error(L, "multiline must be a boolean"); }
        if (lua_toboolean(L, -1)) { node.input_flags |= OMNI_INPUT_MULTILINE; }
        break;
    case AtomFocus:
        if (!lua_isboolean(L, -1)) { luaL_error(L, "focus must be a boolean"); }
        node.input_flags |= OMNI_INPUT_FOCUS_PRESENT;
        if (lua_toboolean(L, -1)) { node.input_flags |= OMNI_INPUT_FOCUS_VALUE; }
        break;
    case AtomAppear: node.appear = readPresence(L, instance); break;
    case AtomExit: node.exit = readPresence(L, instance); break;
    case AtomHoverDelay: node.hover_delay = inputNumber(L, -1, "hoverDelay", 0, 60); break;
    case AtomHoverGrace: node.hover_grace = inputNumber(L, -1, "hoverGrace", 0, 60); break;
    case AtomGesture: readGesture(L, node, instance); break;
    case AtomGestureEvents: {
        const Name names[] = {{"boundary", 8}, {"all", 3}};
        if (inputEnum(L, "gestureEvents", names, 2) == 1) { node.input_flags |= OMNI_INPUT_GESTURE_ALL; }
        break;
    }
    case AtomFocusable:
        if (lua_toboolean(L, -1)) { node.input_flags |= OMNI_INPUT_FOCUSABLE; }
        break;
    case AtomFocusRing:
        if (!lua_isboolean(L, -1)) { luaL_error(L, "focusRing must be a boolean"); }
        if (!lua_toboolean(L, -1)) { node.options |= OMNI_NODE_OPTION_NO_FOCUS_RING; }
        break;
    case AtomKeys: readKeys(L, node, instance); break;
    case AtomScrollMomentum: {
        const Name names[] = {{"consume", 7}, {"deliver", 7}};
        if (inputEnum(L, "scrollMomentum", names, 2) == 1) { node.input_flags |= OMNI_INPUT_MOMENTUM_DELIVER; }
        break;
    }
    case AtomOnRightClick: node.secondary_action = actionValue(L, instance); break;
    case AtomOnScroll: node.scroll_action = actionValue(L, instance); break;
    case AtomHover: colorValue(L, node.hover, node.hover_role); break;
    case AtomAnimate: readAnimate(L, node, instance); break;
    case AtomHoverAnimate: node.hover_motion = motionValue(L, -1); break;
    case AtomHoverMaterial: node.hover_material = enumValue(L, -1, materialNames, materialCount); break;
    case AtomLines: node.lines = static_cast<uint8_t>(unsignedValue(L, -1, 255.0)); break;
    case AtomBridge:
        if (lua_toboolean(L, -1)) {
            node.options |= OMNI_NODE_OPTION_BRIDGE;
        }
        break;
    case AtomOpen: node.open_duration = durationValue(L, -1); break;
    case AtomClose: node.close_duration = durationValue(L, -1); break;
    case AtomEnter: readEnter(L, node, instance); break;
    case AtomD: node.text = internValue(L, -1, instance); break;
    case AtomViewBox:
        if (!lua_istable(L, -1)) {
            luaL_error(L, "viewBox must be a list of 4 numbers: x, y, width, height");
        }
        for (int i = 0; i < 4; i++) {
            lua_rawgeti(L, -1, i + 1);
            node.view_box[i] = floatValue(L, -1);
            lua_pop(L, 1);
        }
        break;
    case AtomEvenOdd:
        if (lua_toboolean(L, -1)) {
            node.options |= OMNI_NODE_OPTION_EVEN_ODD;
        }
        break;
    case AtomAttach:
        if (lua_toboolean(L, -1)) {
            node.options |= OMNI_NODE_OPTION_ATTACH;
        }
        break;
    case AtomMask:
        if (lua_toboolean(L, -1)) {
            node.options |= OMNI_NODE_OPTION_MASK;
        }
        break;
    case AtomPopout:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_OPENS_POPOUT;
        }
        break;
    case AtomSource: node.text = internValue(L, -1, instance); break;
    case AtomValues:
        if (!lua_istable(L, -1)) {
            luaL_error(L, "values must be a list of up to 4 numbers");
        }
        for (int i = 0; i < 4; i++) {
            lua_rawgeti(L, -1, i + 1);
            node.params[i] = floatValue(L, -1);
            lua_pop(L, 1);
        }
        break;
    case AtomFps: node.rate = unsignedValue(L, -1, 120); break;
    case AtomPlaying:
        node.options = static_cast<uint8_t>(
            lua_toboolean(L, -1) ? node.options & ~OMNI_NODE_OPTION_LOOP_PAUSED : node.options | OMNI_NODE_OPTION_LOOP_PAUSED
        );
        break;
    case AtomSpeed: node.speed = std::max(floatValue(L, -1), 0.0f); break;
    case AtomAudio:
        if (lua_toboolean(L, -1)) {
            node.options |= OMNI_NODE_OPTION_AUDIO;
        }
        break;
    case AtomTarget: node.target = internValue(L, -1, instance); break;
    case AtomDx: node.dx = floatValue(L, -1); break;
    case AtomScale: node.scale = floatValue(L, -1); break;
    case AtomShadow: colorValue(L, node.shadow, node.shadow_role); break;
    case AtomShadowRadius: node.shadow_radius = floatValue(L, -1); break;
    case AtomDy: node.dy = floatValue(L, -1); break;
    case AtomMenu:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_MENU;
        }
        break;
    case AtomPreview:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_PREVIEW;
        }
        break;
    case AtomDrag:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_DRAG;
        }
        break;
    case AtomDrop:
        if (lua_toboolean(L, -1)) {
            node.flags |= OMNI_NODE_DROP;
        }
        break;
    case AtomAlign: {
        uint16_t align = alignValues[enumValue(L, -1, alignNames, 9)];
        node.flags = static_cast<uint16_t>((node.flags & ~OMNI_NODE_ALIGN_MASK) | (align << OMNI_NODE_ALIGN_SHIFT));
        break;
    }
    default: break;
    }
}

void encodeNodeContents(lua_State *L, int index, omni_instance *instance, int depth);
bool sameInput(lua_State *L, int left, int right, int depth);

void reportComponentFailure(lua_State *L, ShellPackage &package, int context, int message) {
    char text[513];
    copyValueMessage(L, message, text, sizeof text);
    lua_getref(L, package.componentFailureRef);
    lua_rawgetfield(L, context, "instance");
    lua_pushstring(L, text);
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
        lua_error(L);
    }
}

void encodeNode(lua_State *L, int index, omni_instance *instance, int depth) {
    ShellPackage &package = instance->vm->package;
    if (!package.hasComponentTrees) {
        encodeNodeContents(L, index, instance, depth);
        return;
    }
    luaL_checkstack(L, 8, "component encode");
    lua_getref(L, package.componentTreesRef);
    lua_pushvalue(L, index);
    lua_rawget(L, -2);
    lua_remove(L, -2);
    if (instance->retaining != nullptr && lua_istable(L, -1)) {
        lua_rawgeti(L, -1, 1);
        bool mount = lua_isnumber(L, -1);
        uint64_t id = mount ? static_cast<uint64_t>(lua_tonumber(L, -1)) : 0;
        lua_pop(L, 1);
        if (mount) {
            RetainedSurface &surface = *instance->retaining;
            auto found = surface.units.find(id);
            if (found == surface.units.end()) { luaL_error(L, "the retained component view is no longer available"); }
            lua_rawgeti(L, -1, 3);
            int context = lua_gettop(L);
            bool staged = false;
            for (const MountInput &input : surface.pendingInputs) {
                if (input.unit != id) { continue; }
                lua_rawgetfield(L, context, "view");
                lua_getref(L, input.contextRef);
                lua_rawgetfield(L, -1, "view");
                bool equal = sameInput(L, lua_gettop(L) - 2, lua_gettop(L), 0);
                lua_pop(L, 3);
                if (!equal) { luaL_error(L, "repeated component mounts require equal size and props offers; configure distinct ids"); }
                staged = true;
                break;
            }
            if (!staged) {
                surface.pendingInputs.push_back({id});
                MountInput &input = surface.pendingInputs.back();
                input.contextRef = lua_ref(L, context);
                lua_rawgeti(L, context - 1, 2);
                input.functionRef = lua_ref(L, -1);
                lua_pop(L, 1);
            }
            int offer = lua_ref(L, context);
            lua_pop(L, 2);
            ViewOutput &output = *instance->encoding;
            if (output.nodes.size() >= maximumNodes) { luaL_error(L, "tree larger than %d nodes", static_cast<int>(maximumNodes)); }
            output.mounts.push_back({output.nodes.size(), id, offer});
            omni_wire_node marker{};
            lua_rawgetfield(L, index, "appear");
            if (!lua_isnil(L, -1)) { marker.appear = readPresence(L, instance); }
            lua_pop(L, 1);
            lua_rawgetfield(L, index, "exit");
            if (!lua_isnil(L, -1)) { marker.exit = readPresence(L, instance); }
            lua_pop(L, 1);
            marker.subtree_end = static_cast<int32_t>(output.nodes.size() + 1);
            output.nodes.push_back(marker);
            return;
        }
    }
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        encodeNodeContents(L, index, instance, depth);
        return;
    }
    ComponentEncodeScope scope(instance, lua_gettop(L));
    encodeNodeContents(L, index, instance, depth);
    lua_pop(L, 1);
}

void encodeNodeContents(lua_State *L, int index, omni_instance *instance, int depth) {
    if (depth > maximumDepth) {
        luaL_error(L, "tree deeper than %d", maximumDepth);
    }
    std::vector<omni_wire_node> &nodes = instance->encoding->nodes;
    if (nodes.size() >= maximumNodes) {
        luaL_error(L, "tree larger than %d nodes", static_cast<int>(maximumNodes));
    }
    luaL_checkstack(L, 4, "encode");
    omni_wire_node node{};
    node.width = -1;
    node.height = -1;
    node.opacity = 1;
    node.scale = 1;
    node.hover_opacity = -1;
    node.press_opacity = -1;
    node.open_duration = -1;
    node.close_duration = -1;
    node.enter_opacity = 1;
    node.enter_scale = 1;
    node.enter_to = 255;
    node.center_cross = 1;
    node.input_max_length = 65536;
    node.thumbnail = 128;
    node.blur_radius = -1;
    node.saturation = 1.8f;
    int iterator = 0;
    while ((iterator = lua_rawiter(L, index, iterator)) >= 0) {
        countSteps(L, instance, 1);
        if (lua_type(L, -2) == LUA_TSTRING) {
            int atom = -1;
            lua_tostringatom(L, -2, &atom);
            readField(L, atom, node, instance);
        }
        lua_pop(L, 2);
    }
    if (node.texture_ref != 0 && node.kind != 7) { luaL_error(L, "texture is only supported on ui.shader"); }
    if ((node.appear != 0 || node.exit != 0) && (node.options & OMNI_NODE_OPTION_MASK) != 0) {
        luaL_error(L, "appear and exit cannot be placed on a mask; animate its enclosing visible container");
    }
    if (node.gesture_track != 0 && (node.options & OMNI_NODE_OPTION_MASK) != 0) {
        luaL_error(L, "gesture.track cannot be placed on a mask; track its enclosing visible container");
    }
    if ((node.flags & OMNI_NODE_OPENS_POPOUT) != 0 && node.action == 0) {
        node.action = OMNI_ACTION_POPOUT;
    }
    if (node.kind == 10) {
        if (node.key == 0) { luaL_error(L, "ui.input requires a stable key"); }
        if ((node.options & OMNI_NODE_OPTION_MASK) != 0) { luaL_error(L, "ui.input cannot be a mask"); }
        if (lua_objlen(L, index) != 0) { luaL_error(L, "ui.input does not accept children"); }
        lua_rawgetfield(L, index, "onChange");
        if (!lua_isnil(L, -1) && !lua_isfunction(L, -1)) { luaL_error(L, "onChange must be a function"); }
        lua_pop(L, 1);
        node.input_flags |= OMNI_INPUT_FOCUSABLE;
    }
    if ((node.resource_drop_action != 0 || node.resource_hover_action != 0) && node.resource_accepts == 0) {
        luaL_error(L, "onDrop and onDropHover require accepts");
    }
    if (node.resource_accepts != 0 && (node.options & OMNI_NODE_OPTION_MASK) != 0) {
        luaL_error(L, "resource drops cannot target a mask; use its enclosing visible container");
    }
    if (node.resource_drag_action != 0 && node.resource_drag_ref == 0) {
        luaL_error(L, "onDragOut requires dragItems");
    }
    if (node.resource_drag_ref != 0) {
        if ((node.options & OMNI_NODE_OPTION_MASK) != 0) { luaL_error(L, "dragItems cannot be placed on a mask"); }
        if ((node.flags & (OMNI_NODE_DRAG | OMNI_NODE_DROP)) != 0 || node.target != 0) {
            luaL_error(L, "dragItems cannot share a node with WM drag, drop or target");
        }
        if (node.kind == 10 || node.kind == 8 || node.gesture_axis != 0) {
            luaL_error(L, "dragItems cannot share a node with input, slider or gesture");
        }
    }
    size_t self = nodes.size();
    nodes.push_back(node);
    int count = lua_objlen(L, index);
    for (int i = 1; i <= count; i++) {
        countSteps(L, instance, 1);
        if (lua_rawgeti(L, index, i) == LUA_TTABLE) {
            encodeNode(L, lua_gettop(L), instance, depth + 1);
        }
        lua_pop(L, 1);
    }
    nodes[self].subtree_end = static_cast<int32_t>(nodes.size());
}

struct ValueReader {
    const uint8_t *cursor;
    const uint8_t *end;

    size_t remaining() const { return static_cast<size_t>(end - cursor); }

    bool read(void *out, size_t size) {
        if (remaining() < size) {
            return false;
        }
        std::memcpy(out, cursor, size);
        cursor += size;
        return true;
    }

    bool count(uint32_t &value) {
        return read(&value, sizeof value) && value <= remaining();
    }

    bool string(lua_State *L) {
        uint32_t length = 0;
        if (!count(length)) {
            return false;
        }
        lua_pushlstring(L, reinterpret_cast<const char *>(cursor), length);
        cursor += length;
        return true;
    }
};

bool pushValue(lua_State *L, ValueReader &reader, int depth, bool preserveNull = false, int depthLimit = -1) {
    uint8_t tag = 0;
    int limit = depthLimit < 0 ? (preserveNull ? 64 : maximumValueDepth) : depthLimit;
    if (depth > limit || !reader.read(&tag, 1) || !lua_checkstack(L, 6)) {
        return false;
    }
    switch (tag) {
    case OMNI_VALUE_NIL:
        if (preserveNull) { pushJSONNull(L); } else { lua_pushnil(L); }
        return true;
    case OMNI_VALUE_FALSE:
    case OMNI_VALUE_TRUE:
        lua_pushboolean(L, tag == OMNI_VALUE_TRUE);
        return true;
    case OMNI_VALUE_NUMBER: {
        double value = 0;
        if (!reader.read(&value, sizeof value) || (preserveNull && !std::isfinite(value))) {
            return false;
        }
        lua_pushnumber(L, value);
        return true;
    }
    case OMNI_VALUE_STRING:
        return reader.string(L);
    case OMNI_VALUE_ARRAY: {
        uint32_t count = 0;
        if (!reader.count(count)) {
            return false;
        }
        lua_createtable(L, static_cast<int>(count), 0);
        if (preserveNull) { markJSONArray(L, -1); }
        for (uint32_t i = 1; i <= count; i++) {
            if (!pushValue(L, reader, depth + 1, preserveNull, limit)) {
                return false;
            }
            lua_rawseti(L, -2, static_cast<int>(i));
        }
        lua_setreadonly(L, -1, true);
        return true;
    }
    case OMNI_VALUE_MAP: {
        uint32_t count = 0;
        if (!reader.count(count)) {
            return false;
        }
        lua_createtable(L, 0, static_cast<int>(count));
        for (uint32_t i = 0; i < count; i++) {
            if (!reader.string(L) || !pushValue(L, reader, depth + 1, preserveNull, limit)) {
                return false;
            }
            lua_rawset(L, -3);
        }
        lua_setreadonly(L, -1, true);
        return true;
    }
    default:
        return false;
    }
}

omni_instance *resolveInstance(ShellPackage &package, uint32_t id) {
    size_t slot = id & 0xFFFF;
    if (slot >= package.instances.size() || package.generations[slot] != (id >> 16)) {
        return nullptr;
    }
    return package.instances[slot];
}

omni_instance *scriptInstance(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    if (vm->package.services == nullptr || !scriptOwnerIsLive(L)) { return nullptr; }
    return resolveInstance(vm->package, scriptDisplay(L));
}

int dataIndex(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    omni_instance *instance = resolveInstance(vm->package, static_cast<uint32_t>(lua_tonumber(L, lua_upvalueindex(2))));
    if (instance == nullptr || scriptInstance(L) != instance) {
        luaL_error(L, "ctx.data is only readable by its own instance");
    }
    lua_pushvalue(L, 2);
    lua_rawget(L, lua_upvalueindex(3));
    if (lua_isnumber(L, -1)) {
        uint64_t bit = 1ull << lua_tointeger(L, -1);
        instance->deps |= bit;
        if (instance->encoding != nullptr) {
            instance->encoding->broadDeps |= bit;
        }
    }
    lua_pop(L, 1);
    lua_pushvalue(L, 2);
    lua_rawget(L, lua_upvalueindex(1));
    return 1;
}

int readOnlyData(lua_State *L) {
    luaL_error(L, "ctx.data is read-only");
}

int selectData(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    omni_instance *instance = resolveInstance(vm->package, static_cast<uint32_t>(lua_tonumber(L, lua_upvalueindex(1))));
    if (instance == nullptr || scriptInstance(L) != instance) {
        luaL_error(L, "ctx.select is only readable by its own instance");
    }
    int count = lua_gettop(L);
    if (count < 1 || count > maximumValueDepth + 1 || lua_type(L, 1) != LUA_TSTRING) {
        luaL_error(L, "ctx.select requires a data key and at most %d path keys", maximumValueDepth);
    }
    for (int index = 2; index <= count; index++) {
        int type = lua_type(L, index);
        double number = type == LUA_TNUMBER ? lua_tonumber(L, index) : 0;
        if (type != LUA_TSTRING && (type != LUA_TNUMBER || !std::isfinite(number) || std::trunc(number) != number)) {
            luaL_error(L, "ctx.select path keys must be strings or integers");
        }
    }
    luaL_checkstack(L, 4, "select");
    lua_getref(L, vm->package.dataKeysRef);
    lua_pushvalue(L, 1);
    lua_rawget(L, -2);
    if (!lua_isnumber(L, -1)) {
        luaL_error(L, "ctx.select requires a known data key");
    }
    uint64_t bit = 1ull << lua_tointeger(L, -1);
    lua_pop(L, 2);
    instance->deps |= bit;
    lua_getref(L, instance->dataRef);
    for (int index = 1; index <= count; index++) {
        if (!lua_istable(L, -1)) {
            lua_pop(L, 1);
            lua_pushnil(L);
            break;
        }
        lua_pushvalue(L, index);
        lua_rawget(L, -2);
        lua_remove(L, -2);
    }
    if (ViewOutput *view = instance->encoding) {
        if (lua_istable(L, -1) || view->selections.size() >= maximumSelections) {
            view->broadDeps |= bit;
        } else if ((view->broadDeps & bit) == 0) {
            view->selections.emplace_back();
            DataSelection &selection = view->selections.back();
            selection.root = bit;
            for (int index = 1; index <= count; index++) {
                selection.path[selection.count] = lua_ref(L, index);
                selection.count++;
            }
            selection.value = lua_ref(L, -1);
        }
    }
    return 1;
}

void buildContext(lua_State *P, omni_instance *instance) {
    lua_newtable(P);
    lua_getref(P, instance->vm->package.componentListRef);
    lua_setfield(P, -2, "components");
    instance->dataRef = lua_ref(P, -1);
    lua_newtable(P);
    lua_newtable(P);
    lua_pushvalue(P, -3);
    lua_pushnumber(P, instance->id);
    lua_getref(P, instance->vm->package.dataKeysRef);
    lua_pushcclosurek(P, dataIndex, "data", 3, nullptr);
    lua_setfield(P, -2, "__index");
    lua_pushcfunction(P, readOnlyData, "data");
    lua_setfield(P, -2, "__newindex");
    lua_pushboolean(P, false);
    lua_setfield(P, -2, "__metatable");
    lua_setreadonly(P, -1, true);
    lua_setmetatable(P, -2);
    lua_setreadonly(P, -1, true);
    lua_newtable(P);
    lua_pushvalue(P, -2);
    lua_setfield(P, -2, "data");
    lua_pushnumber(P, instance->id);
    lua_pushcclosure(P, selectData, "select", 1);
    lua_setfield(P, -2, "select");
    lua_newtable(P);
    instance->stateRef = lua_ref(P, -1);
    lua_setfield(P, -2, "state");
    lua_getref(P, instance->vm->package.formatRef);
    lua_setfield(P, -2, "format");
    instance->ctxRef = lua_ref(P, -1);
    lua_settop(P, 0);
}

int componentContext(lua_State *L) {
    auto *instance = scriptInstance(L);
    if (instance == nullptr || instance->encoding == nullptr) {
        luaL_error(L, "components can only be evaluated during a render");
    }
    instance->deps |= instance->vm->package.componentsBit;
    instance->encoding->broadDeps |= instance->vm->package.componentsBit;
    lua_getref(L, instance->ctxRef);
    return 1;
}

int componentCall(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TTABLE);
    int arguments = lua_gettop(L) - 1;
    int status;
    {
        ComponentOwnerScope scope(L, vm->package, 2);
        omni_owner_token owner = scriptOwner(L);
        status = lua_pcall(L, arguments, 1, 0);
        invalidateOwner(vm, owner);
    }
    if (status == LUA_ERRMEM || vm->latched) {
        lua_error(L);
    }
    lua_pushboolean(L, status == LUA_OK);
    lua_insert(L, -2);
    return 2;
}

struct ComponentValueBudget {
    size_t bytes = 0;
    std::array<const void *, maximumDepth + 1> parents{};
};

void copyComponentValue(lua_State *L, int index, int depth, ComponentValueBudget &budget) {
    if (depth > maximumDepth) {
        luaL_error(L, "component props exceed depth 64");
    }
    luaL_checkstack(L, 6, "component props");
    int type = lua_type(L, index);
    size_t size = type == LUA_TTABLE ? 5 : type == LUA_TNUMBER ? 9 : 1;
    if (type == LUA_TSTRING) {
        size_t length = 0;
        lua_tolstring(L, index, &length);
        size = 5 + length;
    }
    budget.bytes += size;
    if (budget.bytes > 64 * 1024) {
        luaL_error(L, "component props exceed 64 KiB");
    }
    if (type == LUA_TNIL || type == LUA_TBOOLEAN || type == LUA_TSTRING) {
        lua_pushvalue(L, index);
        return;
    }
    if (type == LUA_TNUMBER) {
        if (!std::isfinite(lua_tonumber(L, index))) {
            luaL_error(L, "component props require finite numbers");
        }
        lua_pushvalue(L, index);
        return;
    }
    if (type != LUA_TTABLE) {
        luaL_error(L, "component props require value data");
    }
    const void *identity = lua_topointer(L, index);
    for (int level = 0; level < depth; level++) {
        if (budget.parents[level] == identity) {
            luaL_error(L, "component props must be acyclic");
        }
    }
    budget.parents[depth] = identity;
    int arrayLength = lua_objlen(L, index);
    int arrayEntries = 0;
    int mapEntries = 0;
    lua_newtable(L);
    int target = lua_gettop(L);
    int iterator = 0;
    while ((iterator = lua_rawiter(L, index, iterator)) >= 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            mapEntries++;
            size_t length = 0;
            lua_tolstring(L, -2, &length);
            budget.bytes += length + 4;
        } else if (lua_type(L, -2) == LUA_TNUMBER) {
            double key = lua_tonumber(L, -2);
            if (key < 1 || key > arrayLength || key != std::floor(key)) {
                luaL_error(L, "component props require dense arrays or string-keyed records");
            }
            arrayEntries++;
        } else {
            luaL_error(L, "component props require dense arrays or string-keyed records");
        }
        if (mapEntries != 0 && arrayEntries != 0) {
            luaL_error(L, "component props cannot mix array and record keys");
        }
        lua_pushvalue(L, -2);
        copyComponentValue(L, lua_gettop(L) - 1, depth + 1, budget);
        lua_rawset(L, target);
        lua_pop(L, 2);
    }
    if (arrayEntries != 0 && arrayEntries != arrayLength) {
        luaL_error(L, "component props require dense arrays");
    }
    lua_setreadonly(L, target, true);
}

int componentProps(lua_State *L) {
    ComponentValueBudget budget;
    if (lua_gettop(L) == 0) {
        lua_pushnil(L);
    }
    copyComponentValue(L, 1, 0, budget);
    return 1;
}

bool sameInput(lua_State *L, int left, int right, int depth) {
    if (lua_rawequal(L, left, right)) { return true; }
    if (depth > maximumDepth + 2 || lua_type(L, left) != LUA_TTABLE || lua_type(L, right) != LUA_TTABLE) { return false; }
    luaL_checkstack(L, 5, "component input comparison");
    left = lua_absindex(L, left);
    right = lua_absindex(L, right);
    int leftCount = 0;
    int cursor = 0;
    while ((cursor = lua_rawiter(L, left, cursor)) >= 0) {
        leftCount++;
        lua_pushvalue(L, -2);
        lua_rawget(L, right);
        bool equal = sameInput(L, lua_gettop(L) - 1, lua_gettop(L), depth + 1);
        lua_pop(L, 3);
        if (!equal) { return false; }
    }
    int rightCount = 0;
    cursor = 0;
    while ((cursor = lua_rawiter(L, right, cursor)) >= 0) {
        rightCount++;
        lua_pop(L, 2);
    }
    return leftCount == rightCount;
}

bool sameOwner(omni_owner_token left, omni_owner_token right) {
    return left.generation == right.generation && left.owner == right.owner && left.epoch == right.epoch;
}

int componentRenderer(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_unref(L, vm->package.componentRenderRef);
    vm->package.componentRenderRef = lua_ref(L, 1);
    return 0;
}

int componentMount(lua_State *L) {
    auto *instance = scriptInstance(L);
    if (instance == nullptr || instance->retaining == nullptr || instance->encoding == nullptr) {
        luaL_error(L, "a component mount requires an active composition");
    }
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_rawgetfield(L, 2, "view");
    lua_rawgetfield(L, -1, "name");
    size_t length = 0;
    const char *name = luaL_checklstring(L, -1, &length);
    std::string viewName(name, length);
    lua_pop(L, 2);
    omni_owner_token owner;
    {
        ComponentOwnerScope scope(L, instance->vm->package, 2);
        owner = scriptOwner(L);
    }
    RetainedSurface &surface = *instance->retaining;
    RenderUnit *unit = nullptr;
    for (auto &entry : surface.units) {
        if (sameOwner(entry.second->owner, owner) && entry.second->name == viewName) {
            unit = entry.second.get();
            break;
        }
    }
    if (unit == nullptr) {
        if (surface.units.size() >= maximumNodes || surface.nextUnit >= (1ull << 53)) {
            luaL_error(L, "too many retained component views");
        }
        auto created = std::make_unique<RenderUnit>();
        created->id = surface.nextUnit++;
        created->owner = owner;
        created->name = std::move(viewName);
        unit = created.get();
        surface.units.emplace(unit->id, std::move(created));
    }
    lua_newtable(L);
    lua_getref(L, instance->vm->package.componentTreesRef);
    lua_pushvalue(L, -2);
    lua_createtable(L, 3, 0);
    lua_pushnumber(L, static_cast<double>(unit->id));
    lua_rawseti(L, -2, 1);
    lua_pushvalue(L, 1);
    lua_rawseti(L, -2, 2);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, 3);
    lua_setreadonly(L, -1, true);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    instance->vm->package.hasComponentTrees = true;
    return 1;
}

int componentActivities(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_unref(L, vm->package.componentActivitiesRef);
    vm->package.componentActivitiesRef = lua_ref(L, 1);
    return 0;
}

bool activityDependsOn(omni_instance *instance, uint32_t owner, uint32_t target, std::array<bool, 65> &seen) {
    if (owner == target) { return true; }
    if (owner >= seen.size() || seen[owner]) { return false; }
    seen[owner] = true;
    auto found = instance->activities.find(owner);
    if (found == instance->activities.end()) { return false; }
    for (uint32_t dependency : found->second->cache.activities) {
        if (activityDependsOn(instance, dependency, target, seen)) { return true; }
    }
    return false;
}

int componentActivity(lua_State *L) {
    auto *instance = scriptInstance(L);
    if (instance == nullptr || instance->encoding == nullptr) { luaL_error(L, "activity can only be read by a retained unit"); }
    luaL_checktype(L, 1, LUA_TTABLE);
    omni_owner_token owner;
    {
        ComponentOwnerScope scope(L, instance->vm->package, 1);
        owner = scriptOwner(L);
    }
    auto found = instance->activities.find(owner.owner);
    if (found == instance->activities.end() || !sameOwner(found->second->owner, owner)) {
        lua_pushnil(L);
        return 1;
    }
    if (instance->activityEvaluating != 0) {
        std::array<bool, 65> seen{};
        if (activityDependsOn(instance, owner.owner, instance->activityEvaluating, seen)) {
            luaL_error(L, "component activity dependencies cannot contain a cycle");
        }
    }
    auto &reads = instance->encoding->activities;
    if (std::find(reads.begin(), reads.end(), owner.owner) == reads.end()) { reads.push_back(owner.owner); }
    RenderUnit &unit = *found->second;
    if (unit.valueRef == LUA_NOREF) { lua_pushnil(L); } else { lua_getref(L, unit.valueRef); }
    return 1;
}

void invalidateMetadata(omni_vm *vm) {
    auto dirty = [&](RenderUnit &unit) {
        if ((unit.cache.deps & vm->package.componentsBit) != 0) { unit.dirty = true; }
    };
    for (omni_instance *instance : vm->package.instances) {
        if (instance == nullptr) { continue; }
        for (RetainedSurface &surface : instance->retained) {
            dirty(surface.root);
            for (auto &entry : surface.units) { dirty(*entry.second); }
        }
        for (auto &entry : instance->activities) { dirty(*entry.second); }
    }
}

int componentMessage(lua_State *L) {
    char text[513];
    copyValueMessage(L, 1, text, sizeof text);
    lua_pushstring(L, text);
    return 1;
}

int componentSet(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TSTRING);
    lua_settop(L, 3);
    lua_pushvalue(L, 2);
    lua_rawget(L, 1);
    bool changed = !lua_rawequal(L, 3, 4);
    lua_pop(L, 1);
    lua_setreadonly(L, 1, false);
    lua_rawset(L, 1);
    lua_setreadonly(L, 1, true);
    if (changed) {
        auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
        lua_getref(L, vm->package.componentOwnersRef);
        lua_pushvalue(L, 1);
        lua_rawget(L, -2);
        bool registered = lua_isnumber(L, -1);
        lua_pop(L, 2);
        if (registered) {
            ComponentOwnerScope scope(L, vm->package, 1);
            invalidateOwner(vm, scriptOwner(L));
        } else { invalidateMetadata(vm); }
    }
    return 0;
}

int componentAlive(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    componentServiceOwner(L, 1, lua_toboolean(L, 2), lua_toboolean(L, 3));
    return 0;
}

int componentTag(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_getref(L, vm->package.componentTreesRef);
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_rawset(L, -3);
    vm->package.hasComponentTrees = true;
    return 0;
}

int componentReloader(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_unref(L, vm->package.componentRetireRef);
    vm->package.componentRetireRef = lua_ref(L, 1);
    return 0;
}

int componentReceiver(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_unref(L, vm->package.componentReceiverRef);
    vm->package.componentReceiverRef = lua_ref(L, 1);
    return 0;
}

int componentConfigure(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    vm->package.componentConfigRef = lua_ref(L, 1);
    vm->package.componentFailureRef = lua_ref(L, 2);
    return 0;
}

int componentPublish(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    luaL_checktype(L, 1, LUA_TTABLE);
    ShellPackage &package = vm->package;
    int next = lua_ref(L, 1);
    lua_unref(L, package.componentListRef);
    package.componentListRef = next;
    package.componentRevision++;
    invalidateMetadata(vm);
    for (omni_instance *instance : package.instances) {
        if (instance == nullptr) {
            continue;
        }
        lua_getref(L, instance->dataRef);
        lua_pushvalue(L, 1);
        lua_setfield(L, -2, "components");
        lua_pop(L, 1);
    }
    return 0;
}

bool needsRender(omni_instance *instance, const ViewOutput &output, uint64_t changed) noexcept {
    if ((output.deps & changed & instance->vm->package.componentsBit) != 0) {
        return true;
    }
    if (!output.ready || (output.broadDeps & changed) != 0) {
        return true;
    }
    if ((output.deps & changed) == 0) {
        return false;
    }
    lua_State *L = instance->vm->thread;
    int top = lua_gettop(L);
    try {
        if (!lua_checkstack(L, 4)) {
            return true;
        }
        for (const DataSelection &selection : output.selections) {
            if ((selection.root & changed) == 0) {
                continue;
            }
            lua_getref(L, instance->dataRef);
            for (int index = 0; index < selection.count; index++) {
                if (!lua_istable(L, -1)) {
                    lua_pop(L, 1);
                    lua_pushnil(L);
                    break;
                }
                lua_getref(L, selection.path[index]);
                lua_rawget(L, -2);
                lua_remove(L, -2);
            }
            lua_getref(L, selection.value);
            bool same = lua_rawequal(L, -1, -2) != 0;
            lua_settop(L, top);
            if (!same) {
                return true;
            }
        }
        return false;
    } catch (...) {
        lua_settop(L, top);
        return true;
    }
}

void publishOutput(omni_instance *instance, ViewOutput &view, omni_render_stats *stats, bool force) {
    ShellPackage &package = instance->vm->package;
    size_t nodeBytes = view.nodes.size() * sizeof(omni_wire_node);
    const auto *previous = reinterpret_cast<const omni_wire_header *>(view.output.data());
    bool same = !force && package.pendingCount == 0 && view.output.size() >= sizeof(omni_wire_header) + nodeBytes
        && previous->node_count == view.nodes.size() && previous->deps == instance->deps
        && std::memcmp(view.output.data() + sizeof(omni_wire_header), view.nodes.data(), nodeBytes) == 0;
    if (!same) {
        uint32_t flags = 0;
        for (const omni_wire_node &node : view.nodes) {
            if (node.options & OMNI_NODE_OPTION_AUDIO) {
                flags |= OMNI_WIRE_AUDIO;
            }
        }
        omni_wire_header header{
            OMNI_WIRE_MAGIC,
            static_cast<uint32_t>(view.nodes.size()),
            package.pendingCount,
            flags,
            instance->deps,
            package.epoch,
        };
        view.output.clear();
        auto *headerBytes = reinterpret_cast<const uint8_t *>(&header);
        view.output.insert(view.output.end(), headerBytes, headerBytes + sizeof header);
        auto *nodeBytesStart = reinterpret_cast<const uint8_t *>(view.nodes.data());
        view.output.insert(view.output.end(), nodeBytesStart, nodeBytesStart + nodeBytes);
        view.output.insert(view.output.end(), package.pendingStrings.begin(), package.pendingStrings.end());
        stats->new_strings = package.pendingCount;
        package.pendingStrings.clear();
        package.pendingCount = 0;
        stats->changed = 1;
    }
}

void clearCache(lua_State *L, ViewOutput &cache) {
    clearSelections(L, cache);
    lua_unref(L, cache.actionsRef);
    cache.actionsRef = LUA_NOREF;
    for (const UnitMount &mount : cache.mounts) { lua_unref(L, mount.contextRef); }
    cache.activities.clear();
    cache.resources.clear();
    cache.nodes.clear();
    cache.mounts.clear();
    cache.output.clear();
}

void clearUnit(lua_State *L, RenderUnit &unit, RetainedSurface *surface = nullptr) {
    for (ActionPublication &publication : unit.actions) {
        if (surface != nullptr && publication.first != 0) { surface->actions.erase(publication.first); }
        lua_unref(L, publication.ref);
        publication = ActionPublication{};
    }
    lua_unref(L, unit.valueRef);
    unit.valueRef = LUA_NOREF;
    clearCache(L, unit.cache);
    lua_unref(L, unit.functionRef);
    lua_unref(L, unit.contextRef);
    unit.functionRef = unit.contextRef = LUA_NOREF;
    unit.actionDirty = unit.actionChanged = false;
    unit.failure = OMNI_OK;
}

void clearMountInputs(lua_State *L, RetainedSurface &surface) {
    for (MountInput &input : surface.pendingInputs) {
        lua_unref(L, input.functionRef);
        lua_unref(L, input.contextRef);
    }
    surface.pendingInputs.clear();
}

void clearRetained(lua_State *L, RetainedSurface &surface) {
    clearMountInputs(L, surface);
    clearUnit(L, surface.root, &surface);
    clearCache(L, surface.scratch);
    for (auto &entry : surface.units) { clearUnit(L, *entry.second, &surface); }
    surface.units.clear();
    surface.actions.clear();
    surface.active = false;
    surface.assemble = false;
    surface.forcePublish = false;
    surface.root.dirty = true;
}

bool measureRetained(lua_State *L, RetainedSurface &surface, const ViewOutput &cache, RenderUnit &replacing,
                     const ViewOutput &replacement, std::unordered_map<uint64_t, int> &seen,
                     std::array<uint64_t, maximumDepth + 1> &path, size_t depth, size_t &count) {
    if (depth > maximumDepth || cache.nodes.size() > maximumNodes - count) { return false; }
    count += cache.nodes.size();
    for (const UnitMount &mount : cache.mounts) {
        auto found = surface.units.find(mount.unit);
        if (found == surface.units.end()) { return false; }
        if (std::find(path.begin(), path.begin() + depth, mount.unit) != path.begin() + depth) { return false; }
        auto prior = seen.emplace(mount.unit, mount.contextRef);
        if (!prior.second) {
            lua_getref(L, prior.first->second);
            lua_rawgetfield(L, -1, "view");
            lua_getref(L, mount.contextRef);
            lua_rawgetfield(L, -1, "view");
            bool equal = sameInput(L, lua_gettop(L) - 2, lua_gettop(L), 0);
            lua_pop(L, 4);
            if (!equal) { return false; }
            continue;
        }
        path[depth] = mount.unit;
        RenderUnit &unit = *found->second;
        if (!measureRetained(L, surface, &unit == &replacing ? replacement : unit.cache,
                             replacing, replacement, seen, path, depth + 1, count)) { return false; }
    }
    return true;
}

bool measureExpanded(RetainedSurface &surface, const ViewOutput &cache, size_t start, size_t end,
                     size_t depth, size_t &count, RenderUnit *replacing = nullptr, const ViewOutput *replacement = nullptr) {
    if (start == end) { return true; }
    if (depth > maximumDepth) { return false; }
    for (size_t index = start; index < end;) {
        auto mount = std::lower_bound(cache.mounts.begin(), cache.mounts.end(), index,
                                     [](const UnitMount &value, size_t offset) { return value.offset < offset; });
        if (mount != cache.mounts.end() && mount->offset == index) {
            auto found = surface.units.find(mount->unit);
            if (found == surface.units.end()) { return false; }
            if (!found->second->live) { index++; continue; }
            const ViewOutput &child = found->second.get() == replacing ? *replacement : found->second->cache;
            if (!measureExpanded(surface, child, 0, child.nodes.size(), depth, count, replacing, replacement)) { return false; }
            index++;
        } else {
            if (++count > maximumNodes) { return false; }
            size_t next = static_cast<size_t>(cache.nodes[index].subtree_end);
            if (next <= index || next > end) { return false; }
            if (!measureExpanded(surface, cache, index + 1, next, depth + 1, count, replacing, replacement)) { return false; }
            index = next;
        }
    }
    return true;
}

void mergeFailureDependencies(ViewOutput &cache, const ViewOutput &scratch, uint64_t deps) {
    cache.deps |= deps;
    cache.broadDeps |= deps;
    cache.ready = true;
    for (const ResourceRead &read : scratch.resources) {
        if (std::none_of(cache.resources.begin(), cache.resources.end(), [&](const auto &value) { return sameResource(value, read); })) {
            cache.resources.push_back(read);
        }
    }
    for (uint32_t owner : scratch.activities) {
        if (std::find(cache.activities.begin(), cache.activities.end(), owner) == cache.activities.end()) {
            cache.activities.push_back(owner);
        }
    }
}

omni_status evaluateUnit(omni_instance *instance, RetainedSurface &surface, RenderUnit &unit,
                        omni_view view, uint64_t budget, omni_render_step_stats *stats,
                        char *error, size_t capacity) {
    lua_State *L = instance->thread;
    ScriptSourceScope origin(L, {instance->id, OMNI_VIEW_NONE, 0});
    omni_vm *vm = instance->vm;
    ViewOutput &scratch = surface.scratch;
    const uint64_t firstNewUnit = surface.nextUnit;
    clearMountInputs(L, surface);
    clearCache(L, scratch);
    lua_settop(L, 0);
    bool root = unit.id == 0;
    stats->kind = root ? OMNI_RENDER_ROOT : OMNI_RENDER_COMPONENT_VIEW;
    stats->unit_id = unit.id;
    stats->unit_epoch = unit.owner.epoch;
    stats->owner = unit.owner;
    unit.attempted = surface.pass;
    if (root) {
        lua_rawgetfield(L, LUA_GLOBALSINDEX, viewEntries[view]);
        if (!lua_isfunction(L, -1)) {
            copyMessage(missingEntries[view], error, capacity);
            unit.failure = OMNI_ERR_RUNTIME;
            lua_settop(L, 0);
            return OMNI_ERR_RUNTIME;
        }
        lua_getref(L, instance->ctxRef);
    } else {
        lua_getref(L, vm->package.componentRenderRef);
        lua_getref(L, unit.functionRef);
        lua_getref(L, unit.contextRef);
    }
    struct EncodingScope {
        omni_instance *instance;
        ~EncodingScope() {
            instance->encoding = nullptr;
            instance->retaining = nullptr;
            instance->componentContextIndex = 0;
        }
    } encoding{instance};
    instance->deps = 0;
    instance->encoding = &scratch;
    instance->retaining = &surface;
    omni_status status;
    {
        ComponentOwnerScope owner(L, vm->package, root ? 0 : 3);
        CallScope scope(vm, budget);
        status = finish(vm, L, lua_pcall(L, root ? 1 : 2, 1, 0), error, capacity);
        if (status == OMNI_OK) {
            if (!root && lua_isnil(L, 1)) {
                lua_settop(L, 0);
            } else {
                uint64_t started = threadCPU();
                lua_getref(L, vm->package.encodeRef);
                lua_insert(L, 1);
                captureCount(vm, &omni_capture_stats::tree_encodes);
                status = finish(vm, L, lua_pcall(L, 1, 0, 0), error, capacity);
                stats->render.encode_cpu_ns = threadCPU() - started;
            }
        }
    }
    stats->render.cpu_ns = vm->lastCallCPU;
    stats->render.deps = instance->deps;
    status = enforceBudget(vm, status, error, capacity);
    stats->unit_status = status;
    unit.dirty = false;
    scratch.deps = instance->deps;
    std::unordered_map<uint64_t, int> reachable;
    if (status == OMNI_OK) {
        size_t retainedNodes = 0;
        std::array<uint64_t, maximumDepth + 1> path{};
        size_t expanded = 0;
        const ViewOutput &rootCache = root ? scratch : surface.root.cache;
        if (!measureRetained(L, surface, rootCache, unit, scratch, reachable, path, 0, retainedNodes)
            || !measureExpanded(surface, rootCache, 0, rootCache.nodes.size(), 0, expanded, &unit, &scratch)) {
            copyMessage("retained component composition exceeds its bounds, contains a cycle, or repeats an id/view with conflicting offers", error, capacity);
            status = OMNI_ERR_RUNTIME;
            stats->unit_status = status;
        }
    }
    if (status == OMNI_OK) {
        if (root && unit.failure != OMNI_OK) { surface.forcePublish = true; }
        unit.failure = OMNI_OK;
        for (MountInput &input : surface.pendingInputs) {
            if (reachable.find(input.unit) == reachable.end()) { continue; }
            RenderUnit &mounted = *surface.units.at(input.unit);
            bool equal = false;
            if (mounted.contextRef != LUA_NOREF) {
                lua_getref(L, mounted.contextRef);
                lua_rawgetfield(L, -1, "view");
                lua_getref(L, input.contextRef);
                lua_rawgetfield(L, -1, "view");
                equal = sameInput(L, lua_gettop(L) - 2, lua_gettop(L), 0);
                lua_pop(L, 4);
            }
            if (equal) { continue; }
            lua_unref(L, mounted.functionRef);
            lua_unref(L, mounted.contextRef);
            mounted.functionRef = std::exchange(input.functionRef, LUA_NOREF);
            mounted.contextRef = std::exchange(input.contextRef, LUA_NOREF);
            mounted.dirty = true;
        }
        clearMountInputs(L, surface);
        scratch.ready = true;
        bool equal = unit.cache.ready && unit.cache.nodes.size() == scratch.nodes.size()
            && std::memcmp(unit.cache.nodes.data(), scratch.nodes.data(), scratch.nodes.size() * sizeof(omni_wire_node)) == 0;
        unit.actionDirty = true;
        unit.actionChanged = unit.actionChanged || !equal;
        clearCache(L, unit.cache);
        std::swap(unit.cache, scratch);
        for (auto entry = surface.units.begin(); entry != surface.units.end();) {
            if (reachable.find(entry->first) == reachable.end()) {
                clearUnit(L, *entry->second, &surface);
                entry = surface.units.erase(entry);
            } else {
                ++entry;
            }
        }
        surface.assemble = true;
    } else {
        unit.failure = status;
        clearMountInputs(L, surface);
        for (auto entry = surface.units.begin(); entry != surface.units.end();) {
            if (entry->first >= firstNewUnit) {
                clearUnit(L, *entry->second, &surface);
                entry = surface.units.erase(entry);
            } else {
                ++entry;
            }
        }
        mergeFailureDependencies(unit.cache, scratch, instance->deps);
        clearCache(L, scratch);
        if (!root && status != OMNI_ERR_MEMORY && status != OMNI_ERR_INTERNAL) {
            lua_getref(L, unit.contextRef);
            lua_pushstring(L, error != nullptr && capacity > 0 ? error : "component unit failed");
            reportComponentFailure(L, vm->package, 1, 2);
            status = OMNI_OK;
        }
    }
    lua_settop(L, 0);
    return status;
}

RenderUnit *dirtyMountedUnit(RetainedSurface &surface, const ViewOutput &cache, size_t depth) {
    if (depth > maximumDepth) { return nullptr; }
    for (const UnitMount &mount : cache.mounts) {
        auto found = surface.units.find(mount.unit);
        if (found == surface.units.end()) { continue; }
        RenderUnit &unit = *found->second;
        if (!unit.live) { continue; }
        unit.visited = surface.pass;
        if (unit.dirty && unit.attempted != surface.pass) { return &unit; }
        if (RenderUnit *child = dirtyMountedUnit(surface, unit.cache, depth + 1)) { return child; }
    }
    return nullptr;
}

void invalidateActivityReaders(omni_instance *instance, uint32_t owner) {
    auto dirty = [owner](RenderUnit &unit) {
        if (std::find(unit.cache.activities.begin(), unit.cache.activities.end(), owner) != unit.cache.activities.end()) {
            unit.dirty = true;
        }
    };
    for (RetainedSurface &surface : instance->retained) {
        dirty(surface.root);
        for (auto &entry : surface.units) { dirty(*entry.second); }
    }
    for (auto &entry : instance->activities) { dirty(*entry.second); }
}

omni_status discoverActivities(omni_instance *instance, uint64_t budget, omni_render_step_stats *stats,
                               char *error, size_t capacity) {
    omni_vm *vm = instance->vm;
    lua_State *L = instance->thread;
    lua_settop(L, 0);
    lua_getref(L, vm->package.componentActivitiesRef);
    lua_getref(L, instance->ctxRef);
    stats->kind = OMNI_RENDER_ACTIVITY;
    omni_status status;
    {
        CallScope scope(vm, budget);
        status = finish(vm, L, lua_pcall(L, 1, 1, 0), error, capacity);
    }
    stats->render.cpu_ns = vm->lastCallCPU;
    status = enforceBudget(vm, status, error, capacity);
    stats->unit_status = status;
    if (status != OMNI_OK) { lua_settop(L, 0); return status; }
    std::array<bool, 65> present{};
    int count = lua_objlen(L, 1);
    for (int index = 1; index <= count; index++) {
        lua_rawgeti(L, 1, index);
        lua_rawgeti(L, -1, 2);
        int context = lua_gettop(L);
        omni_owner_token owner;
        {
            ComponentOwnerScope scope(L, vm->package, context);
            owner = scriptOwner(L);
        }
        if (owner.owner == 0 || owner.owner >= present.size()) {
            lua_settop(L, 0);
            return OMNI_ERR_INTERNAL;
        }
        present[owner.owner] = true;
        auto found = instance->activities.find(owner.owner);
        if (found != instance->activities.end() && !sameOwner(found->second->owner, owner)) {
            clearUnit(L, *found->second);
            instance->activities.erase(found);
            found = instance->activities.end();
        }
        if (found == instance->activities.end()) {
            auto created = std::make_unique<RenderUnit>();
            created->id = owner.owner;
            created->owner = owner;
            created->contextRef = lua_ref(L, context);
            lua_rawgeti(L, context - 1, 1);
            created->functionRef = lua_ref(L, -1);
            lua_pop(L, 1);
            instance->activities.emplace(owner.owner, std::move(created));
        }
        lua_pop(L, 2);
    }
    for (auto entry = instance->activities.begin(); entry != instance->activities.end();) {
        if (!present[entry->first]) {
            invalidateActivityReaders(instance, entry->first);
            clearUnit(L, *entry->second);
            entry = instance->activities.erase(entry);
        } else { ++entry; }
    }
    instance->activityRevision = vm->package.componentRevision;
    lua_settop(L, 0);
    return OMNI_OK;
}

omni_status evaluateActivity(omni_instance *instance, RenderUnit &unit, uint64_t budget,
                             omni_render_step_stats *stats, char *error, size_t capacity) {
    omni_vm *vm = instance->vm;
    lua_State *L = instance->thread;
    ScriptSourceScope origin(L, {instance->id, OMNI_VIEW_NONE, 0});
    ViewOutput scratch;
    struct ActivityScope {
        omni_instance *instance;
        ViewOutput &scratch;
        ~ActivityScope() {
            instance->encoding = nullptr;
            instance->activityEvaluating = 0;
            clearCache(instance->thread, scratch);
        }
    } activity{instance, scratch};
    lua_settop(L, 0);
    lua_getref(L, unit.functionRef);
    lua_getref(L, unit.contextRef);
    instance->deps = 0;
    instance->encoding = &scratch;
    instance->activityEvaluating = unit.owner.owner;
    stats->kind = OMNI_RENDER_ACTIVITY;
    stats->unit_id = unit.id;
    stats->owner = unit.owner;
    stats->unit_epoch = unit.owner.epoch;
    unit.dirty = false;
    omni_status status;
    {
        ComponentOwnerScope owner(L, vm->package, 2);
        CallScope scope(vm, budget);
        status = finish(vm, L, lua_pcall(L, 1, 1, 0), error, capacity);
        if (status == OMNI_OK) {
            lua_pushcfunction(L, componentProps, "activity value");
            lua_insert(L, 1);
            status = finish(vm, L, lua_pcall(L, 1, 1, 0), error, capacity);
        }
    }
    stats->render.cpu_ns = vm->lastCallCPU;
    stats->render.deps = instance->deps;
    status = enforceBudget(vm, status, error, capacity);
    stats->unit_status = status;
    if (status == OMNI_OK) {
        bool equal = false;
        if (unit.cache.ready) {
            lua_getref(L, unit.valueRef);
            equal = sameInput(L, 1, lua_gettop(L), 0);
            lua_pop(L, 1);
        }
        int value = lua_ref(L, 1);
        lua_unref(L, unit.valueRef);
        unit.valueRef = value;
        scratch.deps = instance->deps;
        scratch.ready = true;
        clearCache(L, unit.cache);
        std::swap(unit.cache, scratch);
        if (!equal) { invalidateActivityReaders(instance, unit.owner.owner); }
    } else {
        unit.attempted = instance->activityPass;
        mergeFailureDependencies(unit.cache, scratch, instance->deps);
        if (status != OMNI_ERR_MEMORY && status != OMNI_ERR_INTERNAL) {
            lua_settop(L, 0);
            lua_getref(L, unit.contextRef);
            lua_pushstring(L, error != nullptr && capacity > 0 ? error : "component activity failed");
            reportComponentFailure(L, vm->package, 1, 2);
            unit.dirty = false;
            status = OMNI_OK;
        }
    }
    lua_settop(L, 0);
    return status;
}

uint64_t activityDependencies(const omni_instance *instance, uint32_t owner, std::array<bool, 65> &seen) {
    if (owner >= seen.size() || seen[owner]) { return 0; }
    seen[owner] = true;
    auto found = instance->activities.find(owner);
    if (found == instance->activities.end()) { return 0; }
    const ViewOutput &cache = found->second->cache;
    uint64_t deps = cache.deps;
    for (uint32_t child : cache.activities) { deps |= activityDependencies(instance, child, seen); }
    return deps;
}

template <typename Visitor>
void visitActiveCaches(const RetainedSurface &surface, const ViewOutput &cache, Visitor &visit, size_t depth = 0) {
    if (depth > maximumDepth) { return; }
    visit(cache);
    for (const UnitMount &mount : cache.mounts) {
        auto found = surface.units.find(mount.unit);
        if (found != surface.units.end() && found->second->live) {
            visitActiveCaches(surface, found->second->cache, visit, depth + 1);
        }
    }
}

uint64_t backgroundDependencies(const omni_instance *instance) {
    std::array<bool, 65> seen{};
    uint64_t result = 0;
    auto add = [&](const ViewOutput &cache) {
        for (uint32_t owner : cache.activities) { result |= activityDependencies(instance, owner, seen); }
    };
    for (const RetainedSurface &surface : instance->retained) {
        visitActiveCaches(surface, surface.root.cache, add);
    }
    return result;
}

void finishUpdate(omni_instance *instance, RetainedSurface &surface, omni_render_step_stats *stats) {
    surface.active = false;
    stats->done = true;
    stats->render.deps = 0;
    auto add = [&](const ViewOutput &cache) { stats->render.deps |= cache.deps; };
    visitActiveCaches(surface, surface.root.cache, add);
    stats->background_deps = backgroundDependencies(instance);
}

void publishUnitActions(lua_State *L, RetainedSurface &surface, RenderUnit &unit, ShellPackage &package) {
    if (!unit.actionDirty) { return; }
    uint32_t count = 0;
    if (unit.cache.actionsRef != LUA_NOREF) {
        lua_getref(L, unit.cache.actionsRef);
        count = static_cast<uint32_t>(lua_objlen(L, -1));
        lua_pop(L, 1);
    }
    ActionPublication &current = unit.actions.front();
    if (unit.actionChanged || current.count != count) {
        ActionPublication &oldest = unit.actions.back();
        surface.actions.erase(oldest.first);
        lua_unref(L, oldest.ref);
        std::move_backward(unit.actions.begin(), unit.actions.end() - 1, unit.actions.end());
        current = ActionPublication{};
        if (count != 0) {
            current.first = package.nextAction;
            current.count = count;
            package.nextAction += count;
            surface.actions.emplace(current.first, &unit);
        }
    } else {
        lua_unref(L, current.ref);
    }
    current.ref = unit.cache.actionsRef;
    unit.cache.actionsRef = LUA_NOREF;
    unit.actionDirty = false;
    unit.actionChanged = false;
}

bool assembleNodes(RetainedSurface &surface, RenderUnit &owner, const ViewOutput &cache, size_t start, size_t end,
                   size_t depth, ViewOutput &output, uint64_t &deps) {
    if (start == end) { return true; }
    if (depth > maximumDepth) { return false; }
    deps |= cache.deps;
    for (size_t index = start; index < end;) {
        auto mount = std::lower_bound(cache.mounts.begin(), cache.mounts.end(), index,
                                     [](const UnitMount &value, size_t offset) { return value.offset < offset; });
        if (mount != cache.mounts.end() && mount->offset == index) {
            auto found = surface.units.find(mount->unit);
            if (found == surface.units.end()) { return false; }
            RenderUnit &unit = *found->second;
            if (!unit.live) { index++; continue; }
            unit.visited = surface.pass;
            size_t first = output.nodes.size();
            if (!assembleNodes(surface, unit, unit.cache, 0, unit.cache.nodes.size(), depth, output, deps)) { return false; }
            if (first < output.nodes.size() && (output.nodes[first].options & OMNI_NODE_OPTION_MASK) == 0) {
                if (output.nodes[first].appear == 0) { output.nodes[first].appear = cache.nodes[index].appear; }
                if (output.nodes[first].exit == 0) { output.nodes[first].exit = cache.nodes[index].exit; }
            }
            index++;
            continue;
        }
        if (output.nodes.size() >= maximumNodes) { return false; }
        omni_wire_node node = cache.nodes[index];
        size_t next = static_cast<size_t>(node.subtree_end);
        if (next <= index || next > end) { return false; }
        for (uint32_t *action : {&node.action, &node.secondary_action, &node.scroll_action, &node.hover_action,
                                &node.press_action, &node.gesture_action, &node.key_action, &node.outside_press_action,
                                &node.input_commit_action, &node.input_cancel_action, &node.input_focus_action,
                                &node.resource_drop_action, &node.resource_hover_action, &node.resource_drag_ref, &node.resource_drag_action}) {
            if ((*action & OMNI_ACTION_HANDLER) == 0) { continue; }
            uint32_t local = *action & ~OMNI_ACTION_HANDLER;
            if (local == 0 || local > owner.actions.front().count) { return false; }
            *action = OMNI_ACTION_HANDLER | (owner.actions.front().first + local - 1);
        }
        size_t target = output.nodes.size();
        output.nodes.push_back(node);
        if (!assembleNodes(surface, owner, cache, index + 1, next, depth + 1, output, deps)) { return false; }
        output.nodes[target].subtree_end = static_cast<int32_t>(output.nodes.size());
        index = next;
    }
    return true;
}

omni_status assembleSurface(omni_instance *instance, RetainedSurface &surface, omni_view view,
                            omni_render_step_stats *stats, char *error, size_t capacity) {
    lua_State *L = instance->thread;
    lua_settop(L, 0);
    uint64_t required = 0;
    auto reserve = [&](RenderUnit &unit) {
        if (unit.actionDirty && unit.cache.actionsRef != LUA_NOREF) {
            lua_getref(L, unit.cache.actionsRef);
            uint32_t count = static_cast<uint32_t>(lua_objlen(L, -1));
            lua_pop(L, 1);
            if (unit.actionChanged || unit.actions.front().count != count) { required += count; }
        }
    };
    reserve(surface.root);
    for (auto &entry : surface.units) { reserve(*entry.second); }
    if (uint64_t(instance->vm->package.nextAction) + required >= OMNI_ACTION_HANDLER) {
        copyMessage("component action handle capacity exhausted", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    size_t expanded = 0;
    if (!measureExpanded(surface, surface.root.cache, 0, surface.root.cache.nodes.size(), 0, expanded)) {
        copyMessage("retained component composition exceeds the expanded surface tree bounds", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    publishUnitActions(L, surface, surface.root, instance->vm->package);
    for (auto &entry : surface.units) { publishUnitActions(L, surface, *entry.second, instance->vm->package); }
    ViewOutput &output = instance->views[view];
    output.nodes.clear();
    uint64_t deps = 0;
    if (!assembleNodes(surface, surface.root, surface.root.cache, 0, surface.root.cache.nodes.size(), 0, output, deps)) {
        copyMessage("retained component composition exceeds the surface tree bounds or contains a cycle", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    instance->deps = deps;
    output.deps = deps;
    output.ready = true;
    stats->kind = OMNI_RENDER_ASSEMBLE;
    stats->render.deps = deps;
    publishOutput(instance, output, &stats->render, surface.forcePublish);
    surface.forcePublish = false;
    lua_settop(L, 0);
    surface.assemble = false;
    return OMNI_OK;
}



}

namespace omni_detail {

void recordResourceRead(lua_State *L, omni_owner_token owner, omni_resource_id id) {
    omni_instance *instance = scriptInstance(L);
    if (instance == nullptr || instance->encoding == nullptr) { return; }
    ResourceRead read{owner, id};
    auto &reads = instance->encoding->resources;
    if (std::none_of(reads.begin(), reads.end(), [&](const auto &value) { return sameResource(value, read); })) {
        reads.push_back(read);
    }
}

void invalidateResourceReaders(omni_vm *vm, omni_owner_token owner, omni_resource_id id) {
    ResourceRead read{owner, id};
    auto invalidate = [&](RenderUnit &unit) {
        if (unit.live && std::any_of(unit.cache.resources.begin(), unit.cache.resources.end(),
                                    [&](const auto &value) { return sameResource(value, read); })) {
            unit.dirty = true;
        }
    };
    for (omni_instance *instance : vm->package.instances) {
        if (instance == nullptr) { continue; }
        for (RetainedSurface &surface : instance->retained) {
            invalidate(surface.root);
            for (auto &entry : surface.units) { invalidate(*entry.second); }
        }
        for (auto &entry : instance->activities) { invalidate(*entry.second); }
    }
}

namespace {

static_assert(sizeof(omni_desktop_anchor) == 24);
static_assert(sizeof(omni_anchor_step) == 16);

struct AnchorSearch {
    const ViewOutput &published;
    omni_owner_token owner;
    uint64_t key;
    uint64_t unit;
    bool qualified;
    size_t offset = 0;
    size_t matches = 0;
    uint64_t foundUnit = 0;
    std::vector<omni_anchor_step> path;
    std::vector<omni_anchor_step> found;
};

bool findAnchorNodes(const RetainedSurface &surface, const RenderUnit &unit, const ViewOutput &cache,
                     size_t start, size_t end, size_t depth, uint32_t &child, AnchorSearch &search) {
    if (start == end) { return true; }
    if (depth > maximumDepth) { return false; }
    for (size_t index = start; index < end;) {
        auto mount = std::lower_bound(cache.mounts.begin(), cache.mounts.end(), index,
                                     [](const UnitMount &value, size_t offset) { return value.offset < offset; });
        if (mount != cache.mounts.end() && mount->offset == index) {
            auto found = surface.units.find(mount->unit);
            if (found == surface.units.end()) { return false; }
            if (found->second->live && !findAnchorNodes(surface, *found->second, found->second->cache,
                0, found->second->cache.nodes.size(), depth, child, search)) { return false; }
            index++;
            continue;
        }
        const omni_wire_node &node = cache.nodes[index];
        size_t next = static_cast<size_t>(node.subtree_end);
        if (next <= index || next > end || search.offset >= search.published.nodes.size()) { return false; }
        const omni_wire_node &published = search.published.nodes[search.offset++];
        if (node.key != published.key || node.kind != published.kind) { return false; }
        search.path.push_back({node.key, child++, node.kind});
        if (node.key == search.key && sameOwner(unit.owner, search.owner) && (!search.qualified || unit.id == search.unit)) {
            search.matches++;
            search.foundUnit = unit.id;
            search.found = search.path;
        }
        uint32_t nestedChild = 0;
        if (!findAnchorNodes(surface, unit, cache, index + 1, next, depth + 1, nestedChild, search)) { return false; }
        search.path.pop_back();
        if (static_cast<size_t>(published.subtree_end) != search.offset) { return false; }
        index = next;
    }
    return true;
}

bool locateAnchor(omni_instance *instance, omni_view view, omni_owner_token owner, uint64_t key,
                  bool qualified, uint64_t unit, std::vector<omni_anchor_step> &path, uint64_t &foundUnit,
                  std::string &error) {
    if (instance == nullptr || static_cast<unsigned>(view) >= viewCount) { error = "anchor_unavailable"; return false; }
    RetainedSurface &surface = instance->retained[view];
    const ViewOutput &published = instance->views[view];
    if (surface.active || surface.assemble || !published.ready || !surface.root.live) {
        error = "anchor_unavailable";
        return false;
    }
    AnchorSearch search{published, owner, key, unit, qualified, 0, 0, 0, {}, {}};
    search.path.reserve(maximumDepth + 1);
    uint32_t child = 0;
    if (!findAnchorNodes(surface, surface.root, surface.root.cache, 0, surface.root.cache.nodes.size(), 0, child, search)
        || search.offset != published.nodes.size() || search.matches == 0) {
        error = "anchor_unavailable";
        return false;
    }
    if (search.matches != 1) { error = "anchor_ambiguous"; return false; }
    path = std::move(search.found);
    foundUnit = search.foundUnit;
    return true;
}

}

bool desktopAnchor(omni_vm *vm, omni_owner_token owner, ScriptSource source, const char *key, size_t length,
                   omni_desktop_anchor &anchor, std::string &error) {
    if (source.surface == 0 || source.display == OMNI_NO_DISPLAY || static_cast<unsigned>(source.view) >= viewCount) {
        error = "source_surface_unavailable";
        return false;
    }
    omni_instance *instance = nullptr;
    for (omni_instance *candidate : vm->package.instances) {
        if (candidate != nullptr && candidate->id == source.display) { instance = candidate; break; }
    }
    uint64_t hash = fnv1a(key, length) & ~(3ull << 62);
    if (hash == 0) { hash = 1; }
    std::vector<omni_anchor_step> path;
    uint64_t unit = 0;
    if (!locateAnchor(instance, source.view, owner, hash, false, 0, path, unit, error)) { return false; }
    anchor = {vm->package.epoch, unit, hash};
    return true;
}

bool pushPublishedAction(omni_vm *vm, uint32_t display, omni_view view, uint32_t action,
                         lua_State *L, omni_owner_token &owner) {
    int top = lua_gettop(L);
    if (static_cast<unsigned>(view) >= viewCount || (action & OMNI_ACTION_HANDLER) == 0) { return false; }
    omni_instance *instance = nullptr;
    for (omni_instance *candidate : vm->package.instances) {
        if (candidate != nullptr && candidate->id == display) { instance = candidate; break; }
    }
    if (instance == nullptr) { return false; }
    RetainedSurface &surface = instance->retained[view];
    uint32_t handle = action & ~OMNI_ACTION_HANDLER;
    auto range = surface.actions.upper_bound(handle);
    if (range == surface.actions.begin()) { return false; }
    --range;
    int actionsRef = LUA_NOREF;
    uint32_t local = 0;
    for (const ActionPublication &publication : range->second->actions) {
        if (publication.first == range->first && handle - publication.first < publication.count) {
            actionsRef = publication.ref;
            local = handle - publication.first + 1;
            break;
        }
    }
    if (actionsRef == LUA_NOREF) { return false; }
    lua_getref(L, actionsRef);
    lua_rawgeti(L, -1, static_cast<int>(local));
    lua_remove(L, -2);
    bool component = lua_istable(L, -1);
    if (component) {
        lua_rawgeti(L, -1, 2);
        lua_getref(L, vm->package.componentOwnersRef);
        lua_rawgetfield(L, -2, "instance");
        lua_rawget(L, -2);
        bool alive = lua_toboolean(L, -1);
        lua_pop(L, 2);
        if (!alive) { lua_settop(L, top); return false; }
        lua_rawgeti(L, top + 1, 1);
        lua_replace(L, top + 1);
    } else {
        lua_getref(L, instance->ctxRef);
    }
    if (!lua_isfunction(L, top + 1)) { lua_settop(L, top); return false; }
    omni_owner_token previous = switchScriptOwner(L, component ? top + 2 : 0);
    owner = scriptOwner(L);
    restoreScriptOwner(L, previous);
    return true;
}

bool publishedDrag(omni_vm *vm, uint32_t display, omni_view view, uint32_t declaration, uint32_t action) {
    if (static_cast<unsigned>(view) >= viewCount || declaration == 0) { return false; }
    for (omni_instance *instance : vm->package.instances) {
        if (instance == nullptr || instance->id != display) { continue; }
        const ViewOutput &output = instance->views[view];
        if (!output.ready) { return false; }
        return std::any_of(output.nodes.begin(), output.nodes.end(), [&](const omni_wire_node &node) {
            return node.resource_drag_ref == declaration && node.resource_drag_action == action;
        });
    }
    return false;
}

void invalidateOwner(omni_vm *vm, omni_owner_token owner) {
    for (omni_instance *instance : vm->package.instances) {
        if (instance == nullptr) { continue; }
        for (RetainedSurface &surface : instance->retained) {
            if (owner.owner == 0) { surface.root.dirty = true; }
            for (auto &entry : surface.units) {
                if (sameOwner(entry.second->owner, owner)) { entry.second->dirty = true; }
            }
        }
        for (auto &entry : instance->activities) {
            if (sameOwner(entry.second->owner, owner)) { entry.second->dirty = true; }
        }
    }
}

void retireRenderOwner(omni_vm *vm, omni_owner_token owner) {
    for (omni_instance *instance : vm->package.instances) {
        if (instance == nullptr) { continue; }
        for (RetainedSurface &surface : instance->retained) {
            for (auto &entry : surface.units) {
                RenderUnit &unit = *entry.second;
                if (!sameOwner(unit.owner, owner)) { continue; }
                for (ActionPublication &publication : unit.actions) {
                    surface.actions.erase(publication.first);
                    lua_unref(vm->thread, publication.ref);
                    publication = ActionPublication{};
                }
                unit.live = false;
                unit.dirty = false;
                unit.actionDirty = false;
            }
        }
        auto activity = instance->activities.find(owner.owner);
        if (activity != instance->activities.end() && sameOwner(activity->second->owner, owner)) {
            invalidateActivityReaders(instance, owner.owner);
            clearUnit(vm->thread, *activity->second);
            instance->activities.erase(activity);
        }
    }
    invalidateMetadata(vm);
}

int requireComponent(lua_State *L);

void installComponentHost(lua_State *L, ShellPackage &package) {
    for (int *ref : {&package.componentTreesRef, &package.componentOwnersRef}) {
        lua_newtable(L);
        lua_newtable(L);
        lua_pushliteral(L, "k");
        lua_setfield(L, -2, "__mode");
        lua_setmetatable(L, -2);
        *ref = lua_ref(L, -1);
        lua_pop(L, 1);
    }
    lua_newtable(L);
    lua_setreadonly(L, -1, true);
    package.componentListRef = lua_ref(L, -1);
    lua_pop(L, 1);
    lua_newtable(L);
    const std::pair<const char *, lua_CFunction> functions[] = {
        {"context", componentContext}, {"call", componentCall}, {"props", componentProps},
        {"mount", componentMount}, {"renderer", componentRenderer},
        {"activities", componentActivities}, {"activity", componentActivity},
        {"set", componentSet}, {"alive", componentAlive}, {"tag", componentTag}, {"message", componentMessage},
        {"configure", componentConfigure}, {"reloader", componentReloader}, {"receiver", componentReceiver}, {"publish", componentPublish}, {"requireComponent", requireComponent},
    };
    for (const auto &[name, function] : functions) {
        lua_pushcfunction(L, function, name);
        lua_setfield(L, -2, name);
    }
    lua_setreadonly(L, -1, true);
    lua_setglobal(L, "_omniComponentHost");
}

void InternTable::rehash(size_t capacity) {
    std::vector<uint32_t> ids(capacity, 0);
    std::vector<uint64_t> hashes(capacity, 0);
    size_t mask = capacity - 1;
    for (size_t i = 0; i < slotIds.size(); i++) {
        if (slotIds[i] == 0) {
            continue;
        }
        size_t probe = slotHashes[i] & mask;
        while (ids[probe] != 0) {
            probe = (probe + 1) & mask;
        }
        ids[probe] = slotIds[i];
        hashes[probe] = slotHashes[i];
    }
    slotIds.swap(ids);
    slotHashes.swap(hashes);
}

uint32_t InternTable::intern(const char *s, size_t length, bool &added) {
    if (slotIds.empty()) {
        rehash(1024);
    }
    uint64_t hash = fnv1a(s, length);
    size_t mask = slotIds.size() - 1;
    size_t probe = hash & mask;
    while (uint32_t id = slotIds[probe]) {
        if (slotHashes[probe] == hash && lengths[id] == length && std::memcmp(arena.data() + offsets[id], s, length) == 0) {
            added = false;
            return id;
        }
        probe = (probe + 1) & mask;
    }
    uint32_t id = ++count;
    offsets.push_back(static_cast<uint32_t>(arena.size()));
    lengths.push_back(static_cast<uint32_t>(length));
    arena.insert(arena.end(), s, s + length);
    slotIds[probe] = id;
    slotHashes[probe] = hash;
    if (static_cast<size_t>(count) * 2 > slotIds.size()) {
        rehash(slotIds.size() * 2);
    }
    added = true;
    return id;
}

bool pushEncodedValue(lua_State *L, const uint8_t *bytes, size_t length, bool preserveNull, int depthLimit) {
    int top = lua_gettop(L);
    if (bytes == nullptr || length == 0) { return false; }
    ValueReader reader{bytes, bytes + length};
    if (pushValue(L, reader, 0, preserveNull, depthLimit) && reader.remaining() == 0) { return true; }
    lua_settop(L, top);
    return false;
}

bool scriptDisplayIsLive(omni_vm *vm, uint32_t display) {
    return resolveInstance(vm->package, display) != nullptr;
}

int16_t shellAtom(lua_State *, const char *s, size_t length) {
    return static_cast<int16_t>(nameIndex(atomNames, AtomCount, s, length));
}

int encodeEntry(lua_State *L) {
    auto *instance = scriptInstance(L);
    if (instance == nullptr || instance->encoding == nullptr) {
        luaL_error(L, "encode called outside a render");
    }
    ViewOutput &view = *instance->encoding;
    view.nodes.clear();
    view.mounts.clear();
    instance->encodeSteps = 0;
    instance->actionCount = 0;
    if (!lua_istable(L, 1)) {
        luaL_error(L, "render must return a ui element");
    }
    lua_settop(L, 1);
    lua_pushnil(L);
    encodeNode(L, 1, instance, 0);
    int actions = lua_istable(L, actionsIndex) ? lua_ref(L, actionsIndex) : LUA_NOREF;
    lua_unref(L, view.actionsRef);
    view.actionsRef = actions;
    return 0;
}

int popoutAction(lua_State *) {
    return 0;
}

constexpr size_t maximumRequests = 16;
constexpr size_t maximumLogs = 32;
constexpr size_t maximumMessageLength = 512;

void storeMessage(lua_State *L, omni_instance *instance, omni_message_kind kind, const char *text, size_t length) {
    bool stored = true;
    try {
        instance->messages[kind].emplace_back(text, std::min(length, maximumMessageLength));
    } catch (...) {
        stored = false;
    }
    if (!stored) {
        luaL_error(L, "not enough memory");
    }
}

int runRequest(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    auto *instance = scriptInstance(L);
    bool asynchronous = isServiceCall(vm);
    if (!scriptOwnerIsLive(L) || (!asynchronous && (instance == nullptr || !instance->handling))) {
        luaL_error(L, "omniwm.run requires a handler or service callback");
    }
    size_t length = 0;
    const char *text = luaL_checklstring(L, 1, &length);
    if (asynchronous) {
        queueServiceMessage(L, OMNI_MESSAGE_REQUEST, text, length);
    } else {
        if (instance->messages[OMNI_MESSAGE_REQUEST].size() >= maximumRequests) {
            luaL_error(L, "a click handler can run at most %d commands", static_cast<int>(maximumRequests));
        }
        storeMessage(L, instance, OMNI_MESSAGE_REQUEST, text, length);
    }
    return 0;
}

int logMessage(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    auto *instance = scriptInstance(L);
    int count = lua_gettop(L);
    bool asynchronous = instance == nullptr || isServiceCall(vm);
    if (count == 0 || (!asynchronous && instance->messages[OMNI_MESSAGE_LOG].size() >= maximumLogs)) {
        return 0;
    }
    luaL_checkstack(L, count * 2, "log");
    for (int i = 1; i <= count; i++) {
        luaL_tolstring(L, i, nullptr);
        if (i < count) { lua_pushliteral(L, " "); }
    }
    lua_concat(L, count * 2 - 1);
    size_t length = 0;
    const char *text = lua_tolstring(L, -1, &length);
    if (asynchronous) {
        queueServiceMessage(L, OMNI_MESSAGE_LOG, text, length);
    } else {
        storeMessage(L, instance, OMNI_MESSAGE_LOG, text, length);
    }
    return 0;
}

std::string normalizedPath(const std::string &path) {
    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= path.size()) {
        size_t end = path.find('/', start);
        if (end == std::string::npos) {
            end = path.size();
        }
        std::string part = path.substr(start, end - start);
        if (part == "..") {
            if (parts.empty()) {
                return {};
            }
            parts.pop_back();
        } else if (!part.empty() && part != ".") {
            parts.push_back(part);
        }
        start = end + 1;
    }
    std::string result;
    for (const std::string &part : parts) {
        result += result.empty() ? part : "/" + part;
    }
    return result;
}

std::string modulePath(const std::string &requester, const std::string &spec) {
    std::string stem = requester.size() > 5 && requester.compare(requester.size() - 5, 5, ".luau") == 0
        ? requester.substr(0, requester.size() - 5)
        : requester;
    size_t entryLength = stem == "init" ? 4 : stem == "component" ? 9
        : stem.size() > 5 && stem.compare(stem.size() - 5, 5, "/init") == 0 ? 5
        : stem.size() > 10 && stem.compare(stem.size() - 10, 10, "/component") == 0 ? 10 : 0;
    std::string self = entryLength != 0 ? stem.substr(0, stem.size() - entryLength) : stem;
    size_t slash = self.rfind('/');
    std::string directory = slash == std::string::npos ? "" : self.substr(0, slash);
    if (spec.rfind("@self/", 0) == 0) {
        return normalizedPath(self + "/" + spec.substr(6));
    }
    if (spec.rfind("./", 0) == 0 || spec.rfind("../", 0) == 0) {
        return normalizedPath(directory + "/" + spec);
    }
    if (spec.rfind("@component/", 0) == 0) {
        std::string name = spec.substr(11);
        size_t widgets = requester.rfind("/widgets/");
        if (widgets == std::string::npos && requester.rfind("widgets/", 0) != 0) {
            return {};
        }
        if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos || name.find('\0') != std::string::npos) {
            return {};
        }
        return (widgets == std::string::npos ? "" : requester.substr(0, widgets + 1)) + "widgets/" + name + "/component";
    }
    return {};
}

int loadingModule = 0;

int requirePath(lua_State *L, const std::string &path, const char *spec, const std::string **resolved = nullptr) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    if (path.empty()) {
        luaL_error(L, "require \"%s\": paths must start with ./, ../, @self/ or @component/", spec);
    }
    std::string found;
    for (const char *suffix : {".luau", "/init.luau"}) {
        if (vm->package.modules.count(path + suffix) != 0) {
            found = path + suffix;
            break;
        }
    }
    if (found.empty()) {
        luaL_error(L, "require \"%s\": no module at %s", spec, path.c_str());
    }
    if (resolved != nullptr) { *resolved = &vm->package.modules.find(found)->first; }
    lua_settop(L, 1);
    lua_getref(L, vm->package.modulesRef);
    lua_getfield(L, 2, found.c_str());
    if (lua_touserdata(L, 3) == &loadingModule) {
        luaL_error(L, "require \"%s\": %s requires itself", spec, found.c_str());
    }
    if (!lua_isnil(L, 3)) {
        return 1;
    }
    lua_pop(L, 1);
    lua_pushlightuserdata(L, &loadingModule);
    lua_setfield(L, 2, found.c_str());
    const std::string &source = vm->package.modules[found];
    size_t bytecodeSize = 0;
    lua_CompileOptions options = scriptCompileOptions();
    char *bytecode = luau_compile(source.data(), source.size(), &options, &bytecodeSize);
    if (bytecode == nullptr) {
        luaL_error(L, "require \"%s\": compiler allocation failed", spec);
    }
    lua_State *module = lua_newthread(L);
    lua_State *main = lua_mainthread(L);
    lua_pushvalue(main, LUA_GLOBALSINDEX);
    lua_xmove(main, module, 1);
    lua_replace(module, LUA_GLOBALSINDEX);
    luaL_sandboxthread(module);
    std::string chunk = "@" + found;
    int loaded = luau_load(module, chunk.c_str(), bytecode, bytecodeSize, 0);
    std::free(bytecode);
    lua_xmove(module, L, 1);
    int status = loaded == 0 ? lua_pcall(L, 0, 1, 0) : LUA_ERRSYNTAX;
    if (status != LUA_OK || lua_isnil(L, -1)) {
        if (status == LUA_OK) {
            lua_pushfstring(L, "module %s returned no value", found.c_str());
        }
        lua_pushnil(L);
        lua_setfield(L, 2, found.c_str());
        lua_error(L);
    }
    lua_pushvalue(L, -1);
    lua_setfield(L, 2, found.c_str());
    return 1;
}

int requireModule(lua_State *L) {
    size_t specLength = 0;
    const char *spec = luaL_checklstring(L, 1, &specLength);
    lua_Debug caller{};
    if (!lua_getinfo(L, 1, "s", &caller) || caller.source == nullptr || caller.source[0] != '@') {
        luaL_error(L, "require is only available to widgets in the shell folder");
    }
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    const std::string requester(caller.source + 1);
    const std::string *resolved = nullptr;
    int results = requirePath(L, modulePath(requester, std::string(spec, specLength)), spec, &resolved);
    auto parent = vm->package.modules.find(requester);
    if (parent != vm->package.modules.end()) {
        auto &edges = vm->package.moduleDependencies[&parent->first];
        if (std::find(edges.begin(), edges.end(), resolved) == edges.end()) { edges.push_back(resolved); }
    }
    if (scriptOwner(L).owner == 0 && vm->package.componentRequireDepth == 0) {
        auto &roots = vm->package.rootModules;
        if (std::find(roots.begin(), roots.end(), resolved) == roots.end()) { roots.push_back(resolved); }
    }
    return results;
}

int requireComponent(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    size_t length = 0;
    const char *name = luaL_checklstring(L, 1, &length);
    struct ComponentRequireScope {
        ShellPackage &package;
        explicit ComponentRequireScope(ShellPackage &value) : package(value) { package.componentRequireDepth++; }
        ~ComponentRequireScope() { package.componentRequireDepth--; }
    } scope(vm->package);
    return requirePath(L, modulePath(vm->package.rootSource, "@component/" + std::string(name, length)), name);
}

int assetReference(lua_State *L) {
    size_t length = 0;
    const char *value = luaL_checklstring(L, 1, &length);
    std::string spec(value, length);
    lua_Debug caller{};
    if (!lua_getinfo(L, 1, "s", &caller) || caller.source == nullptr || caller.source[0] != '@' || spec.rfind("@self/", 0) != 0 || spec.find('\0') != std::string::npos) {
        luaL_error(L, "asset requires an @self/ path from a widget module");
    }
    std::string requester(caller.source + 1);
    size_t widgets = requester.rfind("/widgets/");
    size_t start = widgets == std::string::npos ? 8 : widgets + 9;
    if (widgets == std::string::npos && requester.rfind("widgets/", 0) != 0) {
        luaL_error(L, "asset requires a widget package module");
    }
    size_t end = requester.find('/', start);
    if (end == std::string::npos || end == start) {
        luaL_error(L, "asset requires a widget package module");
    }
    std::string path = modulePath(requester, spec);
    std::string prefix = requester.substr(0, end + 1);
    if (path.size() <= prefix.size() || path.compare(0, prefix.size(), prefix) != 0) {
        luaL_error(L, "asset path escapes its package");
    }
    std::string qualified = "@omni-asset:" + requester.substr(start, end - start) + "/" + path.substr(prefix.size());
    lua_pushlstring(L, qualified.data(), qualified.size());
    return 1;
}

int localizeMessage(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    size_t keyLength = 0;
    const char *key = luaL_checklstring(L, 1, &keyLength);
    if (vm->localizer == nullptr) {
        lua_settop(L, 1);
        return 1;
    }
    constexpr int maximumArguments = 8;
    omni_l10n_arg arguments[maximumArguments];
    int count = std::min(lua_gettop(L) - 1, maximumArguments);
    luaL_checkstack(L, count, "l10n");
    for (int i = 0; i < count; i++) {
        int index = i + 2;
        omni_l10n_arg &argument = arguments[i];
        argument = omni_l10n_arg{};
        if (lua_type(L, index) == LUA_TNUMBER) {
            argument.number = lua_tonumber(L, index);
        } else {
            argument.kind = 1;
            argument.text = luaL_tolstring(L, index, &argument.length);
        }
    }
    char buffer[1024];
    size_t length = vm->localizer(vm->localizerContext, key, keyLength, arguments, static_cast<size_t>(count), buffer, sizeof buffer);
    lua_pushlstring(L, buffer, std::min(length, sizeof buffer));
    return 1;
}

int formatValue(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    auto kind = static_cast<uint8_t>(lua_tointeger(L, lua_upvalueindex(1)));
    double value = luaL_checknumber(L, 1);
    double digits = 0;
    if (kind == OMNI_FORMAT_MEMORY) {
        size_t length = 0;
        const char *style = luaL_optlstring(L, 2, "memory", &length);
        if (length == 4 && std::memcmp(style, "file", 4) == 0) {
            kind = OMNI_FORMAT_FILE;
        } else if (length != 6 || std::memcmp(style, "memory", 6) != 0) {
            luaL_argerror(L, 2, "expected \"memory\" or \"file\"");
        }
    } else {
        digits = std::fmin(std::fmax(std::round(luaL_optnumber(L, 2, 0)), 0.0), 6.0);
    }
    if (vm->formatter == nullptr) {
        luaL_tolstring(L, 1, nullptr);
        return 1;
    }
    char buffer[128];
    size_t length = vm->formatter(vm->formatterContext, kind, value, static_cast<int32_t>(digits), nullptr, 0, nullptr, 0, buffer, sizeof buffer);
    lua_pushlstring(L, buffer, std::min(length, sizeof buffer));
    return 1;
}

int formatDate(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    auto kind = static_cast<uint8_t>(lua_tointeger(L, lua_upvalueindex(1)));
    double seconds = luaL_checknumber(L, 1);
    size_t patternLength = 0;
    const char *pattern = kind == OMNI_FORMAT_DATE ? luaL_checklstring(L, 2, &patternLength) : nullptr;
    size_t zoneLength = 0;
    const char *zone = luaL_optlstring(L, kind == OMNI_FORMAT_DATE ? 3 : 2, nullptr, &zoneLength);
    char buffer[128];
    size_t length = vm->formatter == nullptr ? 0
        : vm->formatter(vm->formatterContext, kind, seconds, 0, pattern, patternLength, zone, zoneLength, buffer, sizeof buffer);
    if (length == 0) {
        lua_pushnil(L);
    } else if (kind == OMNI_FORMAT_OFFSET) {
        lua_pushnumber(L, std::strtod(std::string(buffer, std::min(length, sizeof buffer)).c_str(), nullptr));
    } else {
        lua_pushlstring(L, buffer, std::min(length, sizeof buffer));
    }
    return 1;
}

void installFormat(lua_State *L, ShellPackage &package) {
    lua_createtable(L, 0, 5);
    const std::pair<const char *, unsigned> functions[] = {
        {"number", OMNI_FORMAT_NUMBER}, {"percent", OMNI_FORMAT_PERCENT}, {"bytes", OMNI_FORMAT_MEMORY},
        {"date", OMNI_FORMAT_DATE}, {"offset", OMNI_FORMAT_OFFSET},
    };
    for (const auto &[name, kind] : functions) {
        lua_pushinteger(L, static_cast<int>(kind));
        lua_pushcclosure(L, kind >= OMNI_FORMAT_DATE ? formatDate : formatValue, name, 1);
        lua_setfield(L, -2, name);
    }
    lua_setreadonly(L, -1, true);
    package.formatRef = lua_ref(L, -1);
    lua_pop(L, 1);
}

int timeRead(lua_State *L) {
    if (auto *instance = scriptInstance(L)) {
        instance->deps |= instance->vm->package.secondsBit;
        if (instance->encoding != nullptr) {
            instance->encoding->broadDeps |= instance->vm->package.secondsBit;
        }
    }
    int arguments = lua_gettop(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, arguments, LUA_MULTRET);
    return lua_gettop(L);
}

void markTimeReads(lua_State *L) {
    lua_rawgetfield(L, LUA_GLOBALSINDEX, "os");
    for (const char *name : {"time", "date", "clock"}) {
        lua_rawgetfield(L, -1, name);
        lua_pushcclosure(L, timeRead, name, 1);
        lua_rawsetfield(L, -2, name);
    }
    lua_pop(L, 1);
}

}

omni_instance *omni_instance_create(omni_vm *vm) noexcept {
    lua_State *P = vm->thread;
    try {
        auto instance = std::make_unique<omni_instance>();
        instance->vm = vm;
        instance->views[OMNI_VIEW_BAR].nodes.reserve(256);
        instance->views[OMNI_VIEW_BAR].output.reserve(16 * 1024);
        ShellPackage &package = vm->package;
        size_t slot = 0;
        while (slot < package.instances.size() && (package.instances[slot] != nullptr || package.generations[slot] == UINT16_MAX)) {
            slot++;
        }
        if (slot >= 0xFFFF) {
            return nullptr;
        }
        if (slot == package.instances.size()) {
            package.instances.push_back(nullptr);
            package.generations.push_back(0);
        }
        instance->id = (static_cast<uint32_t>(package.generations[slot]) << 16) | static_cast<uint32_t>(slot);
        instance->thread = lua_newthread(P);
        instance->threadRef = lua_ref(P, -1);
        lua_pop(P, 1);
        setScriptDisplay(instance->thread, instance->id);
        buildContext(P, instance.get());
        for (RetainedSurface &surface : instance->retained) { surface.root.owner = scriptOwner(instance->thread); }
        package.instances[slot] = instance.get();
        return instance.release();
    } catch (...) {
        lua_settop(P, 0);
        return nullptr;
    }
}

uint32_t omni_instance_display_id(const omni_instance *instance) noexcept {
    return instance == nullptr ? OMNI_NO_DISPLAY : instance->id;
}

namespace {

struct ReloadStage {
    std::vector<std::string> prefixes;
    std::unordered_map<std::string, std::string> replacements;
    std::vector<std::string> removals;
    std::unordered_set<const std::string *> affected;
};

bool withinReload(const std::string &path, const ReloadStage &stage) {
    for (const std::string &prefix : stage.prefixes) {
        if (path.compare(0, prefix.size(), prefix) == 0) { return true; }
    }
    return false;
}

bool rootRequiresReload(const ShellPackage &package, const ReloadStage &stage) {
    std::vector<const std::string *> pending = package.rootModules;
    std::unordered_set<const std::string *> seen;
    while (!pending.empty()) {
        const std::string *path = pending.back();
        pending.pop_back();
        if (!seen.insert(path).second) { continue; }
        if (withinReload(*path, stage)) { return true; }
        auto edges = package.moduleDependencies.find(path);
        if (edges != package.moduleDependencies.end()) {
            pending.insert(pending.end(), edges->second.begin(), edges->second.end());
        }
    }
    return false;
}

omni_status stageReload(omni_vm *vm, lua_State *L, const uint8_t *names, size_t namesLength,
                        const omni_module_change *changes, size_t changeCount, ReloadStage &stage,
                        char *error, size_t capacity) {
    if (names == nullptr || namesLength == 0 || namesLength > 128 * 1024 || changeCount > 1024
        || (changes == nullptr && changeCount != 0)) {
        copyMessage("invalid component reload envelope", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    ValueReader reader{names, names + namesLength};
    if (names[0] != OMNI_VALUE_ARRAY || !pushValue(L, reader, 0) || reader.remaining() != 0 || !lua_istable(L, -1) || lua_objlen(L, -1) > 512) {
        copyMessage("component reload requires a bounded widget-name array", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    int count = lua_objlen(L, -1);
    std::unordered_set<std::string> uniqueNames;
    for (int index = 1; index <= count; index++) {
        lua_rawgeti(L, 1, index);
        size_t length = 0;
        const char *bytes = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : nullptr;
        if (bytes == nullptr || length == 0 || length > 128) {
            copyMessage("invalid component reload widget name", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        std::string name(bytes, length);
        lua_pop(L, 1);
        if (name == "." || name == ".." || name.find('/') != std::string::npos || name.find('\0') != std::string::npos
            || !uniqueNames.insert(name).second) {
            copyMessage("invalid or duplicate component reload widget name", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        std::string path = modulePath(vm->package.rootSource, "@component/" + name);
        if (path.empty()) {
            copyMessage("component reload requires a package root", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        stage.prefixes.push_back(path.substr(0, path.rfind('/') + 1));
    }
    std::unordered_set<std::string> paths;
    size_t finalCount = vm->package.modules.size();
    stage.replacements.reserve(changeCount);
    for (size_t index = 0; index < changeCount; index++) {
        const omni_module_change &change = changes[index];
        if (change.path == nullptr || change.path_length == 0 || change.path_length > 4096
            || (change.source == nullptr && change.source_length != 0) || (change.remove && change.source_length != 0)) {
            copyMessage("invalid component module replacement", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        std::string path(change.path, change.path_length);
        if (path.find('\0') != std::string::npos || normalizedPath(path) != path || path == vm->package.rootSource
            || path.size() < 5 || path.compare(path.size() - 5, 5, ".luau") != 0
            || !withinReload(path, stage) || !paths.insert(path).second) {
            copyMessage("component reload cannot change root/shared modules or repeat a path", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        bool exists = vm->package.modules.find(path) != vm->package.modules.end();
        if (change.remove) {
            if (exists) { finalCount--; }
            stage.removals.push_back(std::move(path));
        } else {
            if (!exists) { finalCount++; }
            stage.replacements.emplace(std::move(path), std::string(change.source == nullptr ? "" : change.source, change.source_length));
        }
    }
    if (finalCount > vm->package.moduleLimit) {
        copyMessage("component reload exceeds the configured module limit", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    if (rootRequiresReload(vm->package, stage)) {
        copyMessage("the root retains an affected component export and requires a full reload", error, capacity);
        return OMNI_ERR_RELOAD_REQUIRED;
    }
    for (const auto &module : vm->package.modules) {
        if (withinReload(module.first, stage)) { stage.affected.insert(&module.first); }
    }
    vm->package.modules.reserve(finalCount);
    return OMNI_OK;
}

struct ReloadRefs {
    lua_State *L;
    int owners = LUA_NOREF;
    std::vector<int> keys;
    ~ReloadRefs() {
        lua_unref(L, owners);
        for (int key : keys) { lua_unref(L, key); }
    }
};

omni_status retireReloadOwners(omni_vm *vm, lua_State *L, int ownersRef, uint64_t budget,
                               char *error, size_t capacity) {
    omni_status result = OMNI_OK;
    lua_getref(L, ownersRef);
    int count = lua_objlen(L, -1);
    lua_settop(L, 0);
    for (int index = 1; index <= count; index++) {
        lua_getref(L, ownersRef);
        lua_rawgeti(L, 1, index);
        lua_rawgeti(L, 2, 1);
        int instanceRef = lua_ref(L, 3);
        struct InstanceRef {
            lua_State *L;
            int ref;
            ~InstanceRef() { lua_unref(L, ref); }
        } instance{L, instanceRef};
        lua_rawgeti(L, 2, 2);
        omni_status status = OMNI_OK;
        char detail[512]{};
        if (lua_isfunction(L, 4)) {
            lua_pushvalue(L, 4);
            lua_pushvalue(L, 3);
            {
                ComponentOwnerScope owner(L, vm->package, 3);
                CallScope scope(vm, budget);
                status = finish(vm, L, lua_pcall(L, 1, 0, 0), detail, sizeof detail);
            }
            status = enforceBudget(vm, status, detail, sizeof detail);
        } else if (!lua_isnil(L, 4)) {
            copyMessage("component deinit must be a function", detail, sizeof detail);
            status = OMNI_ERR_RUNTIME;
        }
        lua_settop(L, 0);
        lua_getref(L, instanceRef);
        componentServiceOwner(L, 1, false);
        lua_settop(L, 0);
        if (status == OMNI_ERR_MEMORY || status == OMNI_ERR_INTERNAL) {
            copyMessage(detail, error, capacity);
            return status;
        }
        if (status != OMNI_OK && result == OMNI_OK) {
            copyMessage(detail, error, capacity);
            result = OMNI_ERR_COMPONENT;
        }
    }
    return result;
}

void commitReload(omni_vm *vm, lua_State *L, ReloadStage &stage, const ReloadRefs &refs) {
    ShellPackage &package = vm->package;
    lua_getref(L, package.modulesRef);
    for (int key : refs.keys) {
        lua_getref(L, key);
        lua_pushnil(L);
        lua_rawset(L, -3);
    }
    lua_pop(L, 1);
    for (auto edges = package.moduleDependencies.begin(); edges != package.moduleDependencies.end();) {
        if (stage.affected.count(edges->first) != 0) {
            edges = package.moduleDependencies.erase(edges);
        } else {
            auto &list = edges->second;
            list.erase(std::remove_if(list.begin(), list.end(), [&](const std::string *path) {
                return stage.affected.count(path) != 0;
            }), list.end());
            ++edges;
        }
    }
    for (const std::string &path : stage.removals) { package.modules.erase(path); }
    for (auto entry = stage.replacements.begin(); entry != stage.replacements.end();) {
        auto current = package.modules.find(entry->first);
        if (current != package.modules.end()) {
            current->second.swap(entry->second);
            ++entry;
        } else {
            auto next = entry++;
            package.modules.insert(stage.replacements.extract(next));
        }
    }
}

}

omni_status omni_vm_reload_components(omni_vm *vm, const uint8_t *widget_names, size_t names_length,
    const omni_module_change *changes, size_t change_count, uint64_t budget_ns, char *error, size_t error_capacity) noexcept {
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        ReloadStage stage;
        omni_status status = stageReload(vm, L, widget_names, names_length, changes, change_count, stage, error, error_capacity);
        if (status != OMNI_OK) { lua_settop(L, 0); return status; }
        ReloadRefs refs{L, LUA_NOREF, {}};
        refs.keys.reserve(stage.affected.size());
        for (const std::string *path : stage.affected) {
            lua_pushlstring(L, path->data(), path->size());
            refs.keys.push_back(lua_ref(L, -1));
            lua_pop(L, 1);
        }
        lua_getref(L, vm->package.componentRetireRef);
        lua_insert(L, 1);
        {
            CallScope scope(vm, budget_ns);
            status = finish(vm, L, lua_pcall(L, 1, 1, 0), error, error_capacity);
        }
        status = enforceBudget(vm, status, error, error_capacity);
        if (status != OMNI_OK) { lua_settop(L, 0); return status; }
        refs.owners = lua_ref(L, -1);
        lua_settop(L, 0);
        status = retireReloadOwners(vm, L, refs.owners, budget_ns, error, error_capacity);
        if (status != OMNI_OK && status != OMNI_ERR_COMPONENT) { lua_settop(L, 0); return status; }
        commitReload(vm, L, stage, refs);
        lua_settop(L, 0);
        return status;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("component reload could not allocate its staged replacement", error, error_capacity);
        return OMNI_ERR_MEMORY;
    }
}

omni_status omni_vm_configure_components(omni_vm *vm, const uint8_t *value, size_t length, uint64_t budget_ns, char *error, size_t error_capacity) noexcept {
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    if (value == nullptr || length == 0 || length > 4 * 1024 * 1024) {
        copyMessage("component configuration must contain at most 4 MiB of encoded values", error, error_capacity);
        return OMNI_ERR_RUNTIME;
    }
    struct SeedScope {
        omni_vm *vm;
        ~SeedScope() { clearStoreSeeds(vm); }
    } seeds{vm};
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        lua_getref(L, vm->package.componentConfigRef);
        ValueReader reader{value, value + length};
        if (!pushValue(L, reader, 0) || reader.remaining() != 0) {
            lua_settop(L, 0);
            copyMessage("component configuration could not be decoded", error, error_capacity);
            return OMNI_ERR_RUNTIME;
        }
        omni_status status;
        {
            CallScope scope(vm, budget_ns);
            status = finish(vm, L, lua_pcall(L, 1, 0, 0), error, error_capacity);
        }
        lua_settop(L, 0);
        return enforceBudget(vm, status, error, error_capacity);
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception configuring components", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

void omni_instance_destroy(omni_instance *instance) noexcept {
    if (instance == nullptr) {
        return;
    }
    try {
        ShellPackage &package = instance->vm->package;
        size_t slot = instance->id & 0xFFFF;
        if (slot < package.instances.size() && package.instances[slot] == instance) {
            package.instances[slot] = nullptr;
            package.generations[slot]++;
        }
        lua_State *M = instance->vm->main;
        for (int ref : {instance->threadRef, instance->ctxRef, instance->dataRef, instance->stateRef}) {
            lua_unref(M, ref);
        }
        for (RetainedSurface &surface : instance->retained) { clearRetained(M, surface); }
        for (auto &entry : instance->activities) { clearUnit(M, *entry.second); }
        for (ViewOutput &view : instance->views) {
            clearSelections(M, view);
            lua_unref(M, view.actionsRef);
        }
    } catch (...) {
    }
    delete instance;
}

void invalidateActivityData(omni_instance *instance, lua_State *L, const char *key) {
    lua_getref(L, instance->vm->package.dataKeysRef);
    lua_rawgetfield(L, -1, key);
    if (lua_isnumber(L, -1)) { instance->pendingActivityData |= 1ull << lua_tointeger(L, -1); }
    lua_pop(L, 2);
}

omni_status omni_instance_set_number(omni_instance *instance, const char *key, double value) noexcept {
    if (instance->vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    lua_State *P = instance->vm->thread;
    try {
        lua_getref(P, instance->dataRef);
        lua_pushnumber(P, value);
        lua_setfield(P, -2, key);
        invalidateActivityData(instance, P, key);
        lua_settop(P, 0);
        return OMNI_OK;
    } catch (...) {
        lua_settop(P, 0);
        return OMNI_ERR_MEMORY;
    }
}

omni_status omni_instance_set_string(omni_instance *instance, const char *key, const char *value, size_t length) noexcept {
    if (instance->vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    lua_State *P = instance->vm->thread;
    try {
        lua_getref(P, instance->dataRef);
        lua_pushlstring(P, value, length);
        lua_setfield(P, -2, key);
        invalidateActivityData(instance, P, key);
        lua_settop(P, 0);
        return OMNI_OK;
    } catch (...) {
        lua_settop(P, 0);
        return OMNI_ERR_MEMORY;
    }
}

omni_status omni_instance_set_value(omni_instance *instance, const char *key, const uint8_t *value, size_t length) noexcept {
    if (instance->vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    lua_State *P = instance->vm->thread;
    try {
        lua_getref(P, instance->dataRef);
        ValueReader reader{value, value + length};
        if (!pushValue(P, reader, 0) || reader.remaining() != 0) {
            lua_settop(P, 0);
            return OMNI_ERR_INTERNAL;
        }
        lua_setfield(P, -2, key);
        invalidateActivityData(instance, P, key);
        lua_settop(P, 0);
        return OMNI_OK;
    } catch (...) {
        lua_settop(P, 0);
        return OMNI_ERR_MEMORY;
    }
}

uint32_t omni_vm_string_count(const omni_vm *vm) noexcept {
    return vm->package.strings.count;
}

size_t omni_vm_string_bytes(const omni_vm *vm) noexcept {
    return vm->package.strings.arena.size();
}

void omni_vm_reset_strings(omni_vm *vm) noexcept {
    if (vm->inCall) {
        return;
    }
    ShellPackage &package = vm->package;
    package.strings = InternTable{};
    package.pendingStrings.clear();
    package.pendingCount = 0;
    package.epoch++;
    for (omni_instance *instance : package.instances) {
        if (instance == nullptr) {
            continue;
        }
        for (RetainedSurface &surface : instance->retained) { clearRetained(vm->main, surface); }
        for (auto &entry : instance->activities) { clearUnit(vm->main, *entry.second); }
        instance->activities.clear();
        instance->activityRevision = 0;
        for (ViewOutput &view : instance->views) {
            view.output.clear();
            clearSelections(vm->main, view);
        }
    }
}

bool omni_instance_needs_render(omni_instance *instance, omni_view view, uint64_t changed) noexcept {
    if (instance == nullptr || instance->vm->inCall || static_cast<unsigned>(view) >= viewCount) { return true; }
    RetainedSurface &surface = instance->retained[view];
    if (surface.root.dirty || surface.root.failure != OMNI_OK || surface.assemble || instance->activityRevision != instance->vm->package.componentRevision
        || needsRender(instance, surface.root.cache, changed)) { return true; }
    for (const auto &entry : surface.units) {
        const RenderUnit &unit = *entry.second;
        if (unit.live && (unit.dirty || needsRender(instance, unit.cache, changed))) { return true; }
    }
    for (const auto &entry : instance->activities) {
        if (entry.second->dirty || needsRender(instance, entry.second->cache, instance->pendingActivityData)) { return true; }
    }
    return false;
}

omni_status omni_instance_render(omni_instance *instance, omni_view view, uint64_t budget_ns, omni_render_stats *stats, char *error, size_t error_capacity) noexcept {
    if (stats == nullptr) { return OMNI_ERR_INTERNAL; }
    *stats = omni_render_stats{};
    omni_status status = omni_instance_begin_update(instance, view, UINT64_MAX, true);
    if (status != OMNI_OK) { return status; }
    do {
        omni_render_step_stats step{};
        status = omni_instance_step_update(instance, view, budget_ns, &step, error, error_capacity);
        stats->cpu_ns += step.render.cpu_ns;
        stats->encode_cpu_ns += step.render.encode_cpu_ns;
        stats->new_strings += step.render.new_strings;
        stats->changed |= step.render.changed;
        if (step.done) { stats->deps = step.render.deps; return status; }
    } while (status == OMNI_OK);
    return status;
}

omni_status omni_instance_reserve_drag(omni_instance *instance, omni_view view, uint32_t declaration, uint32_t action,
                                      uint64_t source, omni_owner_token *owner, uint64_t *id, omni_resource_id *resources,
                                      size_t capacity, size_t *count, char *error, size_t errorCapacity) noexcept {
    if (instance == nullptr) { return OMNI_ERR_INTERNAL; }
    return reserveDrag(instance->vm, instance->id, view, declaration, action, source, owner, id, resources,
                       capacity, count, error, errorCapacity);
}

omni_status omni_instance_reserve_drop(omni_instance *instance, omni_view view, uint32_t action, uint64_t source,
                                     omni_owner_token *owner, uint64_t *id, char *error, size_t capacity) noexcept {
    if (instance == nullptr) { return OMNI_ERR_INTERNAL; }
    return reserveDrop(instance->vm, instance->id, view, action, source, owner, id, error, capacity);
}

bool omni_instance_action_owner(omni_instance *instance, omni_view view, uint32_t action, omni_owner_token *owner) noexcept {
    if (owner != nullptr) { *owner = {}; }
    if (instance == nullptr || owner == nullptr || instance->vm->inCall) { return false; }
    lua_State *L = instance->vm->thread;
    int top = lua_gettop(L);
    try {
        bool valid = pushPublishedAction(instance->vm, instance->id, view, action, L, *owner);
        lua_settop(L, top);
        return valid;
    } catch (...) {
        lua_settop(L, top);
        *owner = {};
        return false;
    }
}

omni_status omni_instance_resolve_anchor(omni_instance *instance, omni_view view, omni_owner_token owner,
    omni_desktop_anchor anchor, omni_anchor_step *steps, size_t capacity, size_t *count, char *error, size_t error_capacity) noexcept {
    if (count != nullptr) { *count = 0; }
    if (instance == nullptr || count == nullptr || (capacity != 0 && steps == nullptr)) { return OMNI_ERR_INTERNAL; }
    if (instance->vm->inCall) { return OMNI_ERR_REENTRANT; }
    try {
        std::vector<omni_anchor_step> path;
        uint64_t unit = 0;
        std::string message;
        if (anchor.epoch != instance->vm->package.epoch
            || !locateAnchor(instance, view, owner, anchor.key, true, anchor.unit, path, unit, message)) {
            copyMessage(message.empty() ? "anchor_unavailable" : message.c_str(), error, error_capacity);
            return OMNI_ERR_STALE_ACTION;
        }
        if (path.size() > capacity) { copyMessage("anchor path capacity exceeded", error, error_capacity); return OMNI_ERR_RUNTIME; }
        std::copy(path.begin(), path.end(), steps);
        *count = path.size();
        return OMNI_OK;
    } catch (...) {
        copyMessage("could not resolve desktop anchor", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_instance_invoke(omni_instance *instance, omni_view view, uint32_t action, uint64_t source, const uint8_t *event, size_t event_length, uint64_t budget_ns, char *error, size_t error_capacity) noexcept {
    omni_vm *vm = instance->vm;
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    if (static_cast<unsigned>(view) >= viewCount) {
        return OMNI_ERR_INTERNAL;
    }
    lua_State *L = instance->thread;
    ScriptSourceScope origin(L, {instance->id, view, source});
    try {
        lua_settop(L, 0);
        omni_owner_token captured{};
        if (!pushPublishedAction(vm, instance->id, view, action, L, captured)) {
            copyMessage("the click handler is no longer available", error, error_capacity);
            return OMNI_ERR_STALE_ACTION;
        }
        bool component = captured.owner != 0;
        int arguments = 1;
        if (event_length > 0) {
            ValueReader reader{event, event + event_length};
            if (!pushValue(L, reader, 0) || reader.remaining() != 0) {
                lua_settop(L, 0);
                copyMessage("the click event could not be decoded", error, error_capacity);
                return OMNI_ERR_INTERNAL;
            }
            arguments = 2;
        }
        omni_status status;
        {
            ComponentOwnerScope owner(L, vm->package, component ? 2 : 0);
            CallScope scope(vm, budget_ns);
            instance->handling = true;
            omni_owner_token token = scriptOwner(L);
            captureCount(vm, &omni_capture_stats::input_handlers);
            status = finish(vm, L, lua_pcall(L, arguments, 0, 0), error, error_capacity);
            instance->handling = false;
            invalidateOwner(vm, token);
            if (component && status == OMNI_ERR_RUNTIME && !vm->latched) {
                lua_getref(L, vm->package.componentOwnerRef);
                lua_pushstring(L, error != nullptr && error_capacity > 0 ? error : "component handler failed");
                reportComponentFailure(L, vm->package, lua_gettop(L) - 1, lua_gettop(L));
                status = OMNI_ERR_COMPONENT;
            }
        }
        lua_settop(L, 0);
        return enforceBudget(vm, status, error, error_capacity);
    } catch (...) {
        instance->handling = false;
        lua_settop(L, 0);
        copyMessage("unexpected exception", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_instance_trigger(omni_instance *instance, const uint8_t *event, size_t event_length, uint64_t budget_ns, char *error, size_t error_capacity) noexcept {
    omni_vm *vm = instance->vm;
    if (vm->inCall) {
        return OMNI_ERR_REENTRANT;
    }
    lua_State *L = instance->thread;
    ScriptSourceScope origin(L, {instance->id, OMNI_VIEW_NONE, 0});
    try {
        lua_settop(L, 0);
        lua_rawgetfield(L, LUA_GLOBALSINDEX, "trigger");
        if (!lua_isfunction(L, 1)) {
            lua_settop(L, 0);
            copyMessage("the widget has no trigger function", error, error_capacity);
            return OMNI_ERR_RUNTIME;
        }
        lua_getref(L, instance->ctxRef);
        ValueReader reader{event, event + event_length};
        if (!pushValue(L, reader, 0) || reader.remaining() != 0) {
            lua_settop(L, 0);
            copyMessage("the trigger event could not be decoded", error, error_capacity);
            return OMNI_ERR_INTERNAL;
        }
        omni_status status;
        {
            CallScope scope(vm, budget_ns);
            instance->handling = true;
            captureCount(vm, &omni_capture_stats::trigger_handlers);
            status = finish(vm, L, lua_pcall(L, 2, 0, 0), error, error_capacity);
            instance->handling = false;
            invalidateOwner(vm, scriptOwner(L));
        }
        lua_settop(L, 0);
        return enforceBudget(vm, status, error, error_capacity);
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

const uint8_t *omni_instance_output(const omni_instance *instance, omni_view view, size_t *size) noexcept {
    if (static_cast<unsigned>(view) >= viewCount) {
        *size = 0;
        return nullptr;
    }
    *size = instance->views[view].output.size();
    return instance->views[view].output.data();
}

size_t omni_instance_message_count(const omni_instance *instance, omni_message_kind kind) noexcept {
    return static_cast<unsigned>(kind) < 2 ? instance->messages[kind].size() : 0;
}

const char *omni_instance_message(const omni_instance *instance, omni_message_kind kind, size_t index, size_t *length) noexcept {
    if (static_cast<unsigned>(kind) >= 2 || index >= instance->messages[kind].size()) {
        *length = 0;
        return nullptr;
    }
    const std::string &message = instance->messages[kind][index];
    *length = message.size();
    return message.data();
}

void omni_instance_clear_messages(omni_instance *instance) noexcept {
    for (auto &list : instance->messages) {
        list.clear();
    }
}

void omni_instance_discard_output(omni_instance *instance, omni_view view) noexcept {
    if (static_cast<unsigned>(view) < viewCount) {
        instance->views[view].output.clear();
        clearSelections(instance->vm->main, instance->views[view]);
        instance->retained[view].assemble = true;
    }
}

omni_status omni_instance_begin_update(omni_instance *instance, omni_view view, uint64_t changed, bool visible) noexcept {
    if (instance == nullptr || static_cast<unsigned>(view) >= viewCount) { return OMNI_ERR_INTERNAL; }
    if (instance->vm->inCall) { return OMNI_ERR_REENTRANT; }
    try {
        RetainedSurface &surface = instance->retained[view];
        surface.active = true;
        surface.visible = visible;
        surface.pass++;
        instance->activityPass++;
        surface.root.dirty = surface.root.dirty || changed == UINT64_MAX || needsRender(instance, surface.root.cache, changed);
        uint64_t activityData = std::exchange(instance->pendingActivityData, 0);
        for (auto &entry : instance->activities) {
            entry.second->dirty = entry.second->dirty || needsRender(instance, entry.second->cache, activityData);
        }
        for (auto &entry : surface.units) {
            RenderUnit &unit = *entry.second;
            unit.dirty = unit.dirty || needsRender(instance, unit.cache, changed);
        }
        return OMNI_OK;
    } catch (...) {
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_instance_step_update(omni_instance *instance, omni_view view, uint64_t budget_ns,
                                     omni_render_step_stats *stats, char *error, size_t error_capacity) noexcept {
    if (instance == nullptr || stats == nullptr || static_cast<unsigned>(view) >= viewCount) { return OMNI_ERR_INTERNAL; }
    if (instance->vm->inCall) { return OMNI_ERR_REENTRANT; }
    *stats = omni_render_step_stats{};
    RetainedSurface &surface = instance->retained[view];
    if (!surface.active) { finishUpdate(instance, surface, stats); return OMNI_OK; }
    try {
        if (instance->activityRevision != instance->vm->package.componentRevision) {
            omni_status status = discoverActivities(instance, budget_ns, stats, error, error_capacity);
            if (status != OMNI_OK) { finishUpdate(instance, surface, stats); }
            return status;
        }
        for (auto &entry : instance->activities) {
            if (!entry.second->dirty || entry.second->attempted == instance->activityPass) { continue; }
            omni_status status = evaluateActivity(instance, *entry.second, budget_ns, stats, error, error_capacity);
            if (status != OMNI_OK) { finishUpdate(instance, surface, stats); }
            return status;
        }
        if (!surface.visible) { finishUpdate(instance, surface, stats); return OMNI_OK; }
        if (surface.root.dirty && surface.root.attempted != surface.pass) {
            omni_status status = evaluateUnit(instance, surface, surface.root, view, budget_ns, stats, error, error_capacity);
            if (status != OMNI_OK) { finishUpdate(instance, surface, stats); }
            return status;
        }
        if (RenderUnit *unit = dirtyMountedUnit(surface, surface.root.cache, 0)) {
            omni_status status = evaluateUnit(instance, surface, *unit, view, budget_ns, stats, error, error_capacity);
            if (status != OMNI_OK) { finishUpdate(instance, surface, stats); }
            return status;
        }
        omni_status status = surface.assemble ? assembleSurface(instance, surface, view, stats, error, error_capacity) : OMNI_OK;
        finishUpdate(instance, surface, stats);
        return status;
    } catch (...) {
        clearMountInputs(instance->thread, surface);
        instance->encoding = nullptr;
        instance->retaining = nullptr;
        lua_settop(instance->thread, 0);
        finishUpdate(instance, surface, stats);
        copyMessage("unexpected exception updating retained units", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

void omni_instance_cancel_update(omni_instance *instance, omni_view view) noexcept {
    if (instance != nullptr && !instance->vm->inCall && static_cast<unsigned>(view) < viewCount) {
        instance->retained[view].active = false;
    }
}

uint64_t omni_instance_background_dependencies(const omni_instance *instance) noexcept {
    return instance == nullptr ? 0 : backgroundDependencies(instance);
}
