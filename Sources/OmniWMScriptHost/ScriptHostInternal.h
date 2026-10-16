// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#pragma once

#include "OmniWMLuau.h"
#include "OmniWMScriptHost.h"

#include <atomic>
#include <cstdint>
#include <dispatch/dispatch.h>
#include <string>
#include <unordered_map>
#include <vector>

struct omni_instance;

namespace omni_detail {

struct InternTable {
    std::vector<char> arena;
    std::vector<uint32_t> offsets{0};
    std::vector<uint32_t> lengths{0};
    std::vector<uint32_t> slotIds;
    std::vector<uint64_t> slotHashes;
    uint32_t count = 0;

    uint32_t intern(const char *s, size_t length, bool &added);
    void rehash(size_t capacity);
};

struct ServiceState;

struct ShellPackage {
    ServiceState *services = nullptr;
    InternTable strings;
    std::vector<uint8_t> pendingStrings;
    uint32_t pendingCount = 0;
    uint32_t epoch = 0;
    int encodeRef = LUA_NOREF;
    int dataKeysRef = LUA_NOREF;
    int modulesRef = LUA_NOREF;
    int formatRef = LUA_NOREF;
    int componentConfigRef = LUA_NOREF;
    int componentListRef = LUA_NOREF;
    int componentTreesRef = LUA_NOREF;
    int componentOwnerRef = LUA_NOREF;
    int componentOwnersRef = LUA_NOREF;
    int componentFailureRef = LUA_NOREF;
    int componentRenderRef = LUA_NOREF;
    int componentActivitiesRef = LUA_NOREF;
    int componentRetireRef = LUA_NOREF;
    int componentReceiverRef = LUA_NOREF;
    uint32_t componentRequireDepth = 0;
    uint64_t componentRevision = 1;
    uint32_t nextAction = 1;
    size_t moduleLimit = 64;
    std::string rootSource;
    bool hasComponentTrees = false;
    uint64_t secondsBit = 0;
    uint64_t componentsBit = 0;
    std::unordered_map<std::string, std::string> modules;
    std::unordered_map<const std::string *, std::vector<const std::string *>> moduleDependencies;
    std::vector<const std::string *> rootModules;
    std::vector<omni_instance *> instances;
    std::vector<uint16_t> generations;
};

}

struct omni_vm {
    lua_State *main = nullptr;
    lua_State *thread = nullptr;
    size_t limit = 0;
    size_t used = 0;
    uint32_t loads = 0;
    uint64_t budget = 0;
    uint64_t callStartCPU = 0;
    uint64_t lastCallCPU = 0;
    bool inCall = false;
    bool latched = false;
    std::atomic<bool> pending{false};
    dispatch_source_t timer = nullptr;
    omni_localizer localizer = nullptr;
    void *localizerContext = nullptr;
    omni_formatter formatter = nullptr;
    void *formatterContext = nullptr;
    omni_detail::ShellPackage package;
    omni_capture_stats capture{};
};

namespace omni_detail {

static_assert(sizeof(omni_capture_stats) <= 256);

inline void captureCount(omni_vm *vm, uint64_t omni_capture_stats::*field, uint64_t amount = 1) noexcept {
    if (vm->capture.capture_id != 0) {
        uint64_t &value = vm->capture.*field;
        value = amount > UINT64_MAX - value ? UINT64_MAX : value + amount;
    }
}

inline void captureCount(lua_State *L, uint64_t omni_capture_stats::*field, uint64_t amount = 1) noexcept {
    captureCount(static_cast<omni_vm *>(lua_callbacks(L)->userdata), field, amount);
}

struct CallScope {
    omni_vm *vm;

    CallScope(omni_vm *vm, uint64_t budget);
    ~CallScope();
};

omni_status finish(omni_vm *vm, lua_State *L, int status, char *error, size_t capacity);
omni_status enforceBudget(omni_vm *vm, omni_status status, char *error, size_t capacity);
void copyMessage(const char *message, char *error, size_t capacity);
void copyValueMessage(lua_State *L, int index, char *error, size_t capacity);
uint64_t threadCPU() noexcept;
lua_CompileOptions scriptCompileOptions();
int16_t shellAtom(lua_State *L, const char *s, size_t length);
int encodeEntry(lua_State *L);
int popoutAction(lua_State *L);
int runRequest(lua_State *L);
int logMessage(lua_State *L);
int localizeMessage(lua_State *L);
void installFormat(lua_State *L, ShellPackage &package);
int requireModule(lua_State *L);
void markTimeReads(lua_State *L);
void installComponentHost(lua_State *L, ShellPackage &package);
int assetReference(lua_State *L);
bool encodeValue(lua_State *L, int index, std::vector<uint8_t> &output, size_t limit, std::string &error);
bool encodeJSONValue(lua_State *L, int index, std::vector<uint8_t> &output, size_t limit, std::string &error);
bool decodeJSONValue(lua_State *L, const char *bytes, size_t length, bool readonly, std::string &error);
bool isJSONNull(lua_State *L, int index);
void pushJSONNull(lua_State *L);
void markJSONArray(lua_State *L, int index);
void installJSON(lua_State *L);
bool pushEncodedValue(lua_State *L, const uint8_t *bytes, size_t length, bool preserveNull, int depthLimit = -1);
struct ScriptSource {
    uint32_t display = OMNI_NO_DISPLAY;
    omni_view view = OMNI_VIEW_NONE;
    uint64_t surface = 0;
};

struct ScriptSourceScope {
    lua_State *L;
    ScriptSource previous;

    ScriptSourceScope(lua_State *L, ScriptSource source);
    ~ScriptSourceScope();
};

omni_owner_token scriptOwner(lua_State *L);
uint32_t scriptDisplay(lua_State *L);
bool scriptOwnerIsLive(lua_State *L);
bool scriptDisplayIsLive(omni_vm *vm, uint32_t display);
void setScriptDisplay(lua_State *L, uint32_t display);
omni_owner_token switchScriptOwner(lua_State *L, int context);
void restoreScriptOwner(lua_State *L, omni_owner_token owner);
bool isServiceCall(omni_vm *vm);
void queueServiceMessage(lua_State *L, omni_message_kind kind, const char *text, size_t length);
void componentServiceOwner(lua_State *L, int object, bool alive, bool provider = false);
void clearStoreSeeds(omni_vm *vm);
void invalidateOwner(omni_vm *vm, omni_owner_token owner);
void recordResourceRead(lua_State *L, omni_owner_token owner, omni_resource_id id);
void invalidateResourceReaders(omni_vm *vm, omni_owner_token owner, omni_resource_id id);
bool resourceImage(lua_State *L, int index, std::string &recipe);
void pushResourceDrag(lua_State *L, int index);
bool publishedDrag(omni_vm *vm, uint32_t display, omni_view view, uint32_t declaration, uint32_t action);
omni_status reserveDrag(omni_vm *vm, uint32_t display, omni_view view, uint32_t declaration, uint32_t action, uint64_t source, omni_owner_token *owner, uint64_t *id, omni_resource_id *resources, size_t resourceCapacity, size_t *count, char *error, size_t errorCapacity);
bool desktopAnchor(omni_vm *vm, omni_owner_token owner, ScriptSource source, const char *key, size_t length, omni_desktop_anchor &anchor, std::string &error);
bool pushPublishedAction(omni_vm *vm, uint32_t display, omni_view view, uint32_t action, lua_State *L, omni_owner_token &owner);
omni_status reserveDrop(omni_vm *vm, uint32_t display, omni_view view, uint32_t action, uint64_t source, omni_owner_token *owner, uint64_t *id, char *error, size_t capacity);
void retireRenderOwner(omni_vm *vm, omni_owner_token owner);
void installServices(lua_State *L, ShellPackage &package);
void destroyServices(omni_vm *vm) noexcept;

}
