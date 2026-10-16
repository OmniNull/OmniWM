// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <map>
#include <string_view>
#include <uuid/uuid.h>
#include <new>
#include <utility>

namespace omni_detail {

namespace {

constexpr size_t maximumOwners = 65;
constexpr size_t maximumReservations = 256;
constexpr size_t maximumOwnerReservations = 32;
constexpr size_t maximumCancellations = maximumReservations + maximumOwners;
constexpr size_t maximumStoreBytes = 256 * 1024;
constexpr size_t maximumConfigurationBytes = 64 * 1024;
constexpr size_t maximumHTTPBodyBytes = 4 * 1024 * 1024;
constexpr size_t maximumHTTPHeaderBytes = 64 * 1024;
constexpr size_t maximumHTTPRequestBytes = maximumHTTPBodyBytes + 128 * 1024;
constexpr size_t maximumHTTPCompletionBytes = maximumHTTPBodyBytes + maximumHTTPHeaderBytes + 2 * 1024;
constexpr size_t maximumHTTPReservations = 6;
constexpr size_t maximumProviderLineBytes = 65536;
constexpr size_t maximumProviderStateBytes = 1 << 20;
constexpr const char *handleMetatable = "omniwm.service";

struct ThreadIdentity {
    omni_owner_token owner{};
    ScriptSource source;
};

struct ServiceHandle {
    omni_owner_token owner;
    uint64_t id;
};

struct StoreSeed {
    std::vector<uint8_t> bytes;
    std::string error;
};

using ResourceKey = std::array<uint8_t, 16>;
constexpr size_t maximumResources = 512;
constexpr size_t maximumResourceBatch = 32;
constexpr size_t maximumResourceTokens = 4096;
constexpr const char *resourceMetatable = "omniwm.resource";

ResourceKey resourceKey(omni_resource_id id) {
    ResourceKey key;
    std::copy(id.bytes, id.bytes + 16, key.begin());
    return key;
}

struct ResourceTokenRecord {
    std::string name;
    std::string kind;
    std::string uti;
    bool pending = false;
};

struct ResourceSeed {
    std::map<ResourceKey, ResourceTokenRecord> tokens;
    std::string error;
};

struct ResourceRecord {
    std::string name;
    std::string kind;
    std::string uti;
    std::string error;
    uint64_t revision = 0;
    uint64_t size = 0;
    omni_resource_state state = OMNI_RESOURCE_PENDING;
    bool hasSize = false;
    int proxyRef = LUA_NOREF;
    uint8_t persistence = 0;
    omni_resource_id persistenceToken{};
    std::string persistenceError;
};

struct ResourceProxy {
    omni_owner_token owner;
    omni_resource_id id;
};

struct OwnerState {
    bool live = false;
    uint32_t epoch = 0;
    uint32_t reservations = 0;
    std::string name;
    int instanceRef = LUA_NOREF;
    int storeRef = LUA_NOREF;
    int statusRef = LUA_NOREF;
    std::vector<uint8_t> storeBytes;
    std::string storeError;
    uint64_t revision = 0;
    uint64_t committedRevision = 0;
    uint64_t storeRequest = 0;
    bool providerAuthorized = false;
    uint64_t providerIncarnation = 0;
    omni_provider_status providerStatus = OMNI_PROVIDER_STOPPED;
    int providerRef = LUA_NOREF;
    std::map<ResourceKey, ResourceRecord> resources;
    std::map<ResourceKey, ResourceTokenRecord> resourceTokens;
    std::string resourceError;
};

struct ServiceRequest {
    bool live = false;
    bool dispatched = false;
    omni_service_kind kind = OMNI_SERVICE_TIMER;
    omni_owner_token owner{};
    uint64_t id = 0;
    uint64_t revision = 0;
    double seconds = 0;
    int callbackRef = LUA_NOREF;
    int contextRef = LUA_NOREF;
    uint32_t action = 0;
    bool cancelled = false;
    bool delivered = false;
    bool resourceResult = false;
    bool resourcePersistence = false;
    omni_resource_id resourceID{};
    omni_resource_id resourceToken{};
    ScriptSource source;
    std::vector<uint8_t> bytes;
};

struct Cancellation {
    omni_service_kind kind;
    omni_owner_token owner;
    uint64_t id;
    uint64_t revision;
    std::string name;
    std::vector<uint8_t> bytes;
};

struct OwnedMessage {
    std::string text;
    omni_owner_token owner;
    uint32_t display;
};

bool sameOwner(omni_owner_token left, omni_owner_token right) {
    return left.generation == right.generation && left.owner == right.owner && left.epoch == right.epoch;
}

template <typename Input>
Input &consumeDeliveryInput(lua_State *L) {
    void *input = lua_tolightuserdata(L, lua_upvalueindex(1));
    if (input == nullptr) { luaL_error(L, "native delivery has already been consumed"); }
    lua_pushnil(L);
    lua_replace(L, lua_upvalueindex(1));
    return *static_cast<Input *>(input);
}

int returnedError(lua_State *L, const char *message) {
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

}

struct ServiceState {
    uint64_t generation = 1;
    uint64_t nextID = 1;
    size_t reserved = 0;
    size_t httpReserved = 0;
    bool delivering = false;
    bool configurationEnabled = false;
    int threadsRef = LUA_NOREF;
    int resumeRef = LUA_NOREF;
    std::array<OwnerState, maximumOwners> owners;
    std::array<ServiceRequest, maximumReservations> requests;
    std::deque<uint16_t> pending;
    std::deque<Cancellation> cancellations;
    Cancellation outbound{};
    std::unordered_map<std::string, StoreSeed> seeds;
    std::unordered_map<std::string, ResourceSeed> resourceSeeds;
    std::vector<OwnedMessage> messages[2];
};

namespace {

ServiceState &services(lua_State *L) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    return *vm->package.services;
}

ThreadIdentity *identity(lua_State *L) {
    return static_cast<ThreadIdentity *>(lua_getthreaddata(L));
}

omni_owner_token token(ServiceState &state, size_t slot) {
    return {state.generation, static_cast<uint32_t>(slot), state.owners[slot].epoch};
}

bool ownerIsLive(ServiceState &state, omni_owner_token owner) {
    return owner.generation == state.generation && owner.owner < state.owners.size()
        && state.owners[owner.owner].live && state.owners[owner.owner].epoch == owner.epoch;
}

std::string resourceString(omni_resource_id id) {
    char text[37];
    uuid_unparse_lower(id.bytes, text);
    return text;
}

ResourceRecord *resourceFor(ServiceState &state, omni_owner_token owner, omni_resource_id id) {
    if (!ownerIsLive(state, owner)) { return nullptr; }
    auto &resources = state.owners[owner.owner].resources;
    auto found = resources.find(resourceKey(id));
    return found == resources.end() ? nullptr : &found->second;
}

void clearResources(lua_State *L, OwnerState &owner) {
    for (auto &entry : owner.resources) { lua_unref(L, entry.second.proxyRef); }
    owner.resources.clear();
    owner.resourceTokens.clear();
    owner.resourceError.clear();
}

int resourceIndex(lua_State *L) {
    auto &proxy = *static_cast<ResourceProxy *>(luaL_checkudata(L, 1, resourceMetatable));
    if (!sameOwner(proxy.owner, scriptOwner(L))) { luaL_error(L, "resource belongs to another owner"); }
    ResourceRecord *record = resourceFor(services(L), proxy.owner, proxy.id);
    if (record == nullptr) { luaL_error(L, "resource is no longer available"); }
    size_t length = 0;
    const char *field = luaL_checklstring(L, 2, &length);
    std::string_view key(field, length);
    recordResourceRead(L, proxy.owner, proxy.id);
    if (key == "id") { std::string value = resourceString(proxy.id); lua_pushlstring(L, value.data(), value.size()); }
    else if (key == "name") { lua_pushlstring(L, record->name.data(), record->name.size()); }
    else if (key == "kind") { lua_pushlstring(L, record->kind.data(), record->kind.size()); }
    else if (key == "uti") { lua_pushlstring(L, record->uti.data(), record->uti.size()); }
    else if (key == "persistence" && record->persistence != 0) {
        lua_createtable(L, 0, 3);
        std::string value = resourceString(record->persistenceToken);
        lua_pushlstring(L, value.data(), value.size());
        lua_setfield(L, -2, "token");
        lua_pushstring(L, record->persistence == 1 ? "pending" : record->persistence == 2 ? "durable" : "failed");
        lua_setfield(L, -2, "state");
        if (!record->persistenceError.empty()) {
            lua_pushlstring(L, record->persistenceError.data(), record->persistenceError.size());
            lua_setfield(L, -2, "error");
        }
        lua_setreadonly(L, -1, true);
    }
    else if (key == "size" && record->hasSize) { lua_pushnumber(L, static_cast<double>(record->size)); }
    else if (key == "state") {
        lua_pushstring(L, record->state == OMNI_RESOURCE_READY ? "ready" : record->state == OMNI_RESOURCE_FAILED ? "failed" : "pending");
    } else if (key == "error" && !record->error.empty()) { lua_pushlstring(L, record->error.data(), record->error.size()); }
    else { lua_pushnil(L); }
    return 1;
}

void pushResource(lua_State *L, omni_owner_token owner, omni_resource_id id) {
    ResourceRecord *record = resourceFor(services(L), owner, id);
    if (record == nullptr) { luaL_error(L, "resource is no longer available"); }
    if (record->proxyRef != LUA_NOREF) { lua_getref(L, record->proxyRef); return; }
    new (lua_newuserdata(L, sizeof(ResourceProxy))) ResourceProxy{owner, id};
    luaL_getmetatable(L, resourceMetatable);
    lua_setmetatable(L, -2);
    record->proxyRef = lua_ref(L, -1);
}

bool boundedResourceString(const char *text, size_t length, size_t maximum, bool empty = true) {
    return length <= maximum && (empty || length != 0)
        && (length == 0 || (text != nullptr && std::memchr(text, 0, length) == nullptr));
}

struct DropDelivery {
    ServiceRequest *request;
    const omni_resource_id *resources;
    size_t count;
    double x;
    double y;
    bool invoked = false;
};

int dropDeliveryEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<DropDelivery>(L);
    lua_getref(L, input.request->callbackRef);
    lua_getref(L, input.request->contextRef);
    lua_createtable(L, 0, 3);
    int event = lua_gettop(L);
    lua_createtable(L, static_cast<int>(input.count), 0);
    for (size_t index = 0; index < input.count; index++) {
        pushResource(L, input.request->owner, input.resources[index]);
        lua_rawseti(L, -2, static_cast<int>(index + 1));
    }
    lua_setreadonly(L, -1, true);
    lua_setfield(L, event, "items");
    lua_pushnumber(L, input.x);
    lua_setfield(L, event, "x");
    lua_pushnumber(L, input.y);
    lua_setfield(L, event, "y");
    lua_setreadonly(L, event, true);
    input.invoked = true;
    captureCount(L, &omni_capture_stats::drop_handlers);
    lua_call(L, 2, 0);
    return 0;
}

OwnerState &currentOwner(lua_State *L) {
    ServiceState &state = services(L);
    ThreadIdentity *thread = identity(L);
    if (thread == nullptr || !ownerIsLive(state, thread->owner)) {
        luaL_error(L, "the script owner is no longer available");
    }
    return state.owners[thread->owner.owner];
}

void threadCreated(lua_State *parent, lua_State *child) {
    if (parent == nullptr) {
        lua_setthreaddata(child, nullptr);
        return;
    }
    ServiceState &state = services(parent);
    ThreadIdentity value = identity(parent) == nullptr ? ThreadIdentity{token(state, 0), {}} : *identity(parent);
    lua_getref(parent, state.threadsRef);
    lua_pushthread(child);
    lua_xmove(child, parent, 1);
    auto *stored = new (lua_newuserdata(parent, sizeof(ThreadIdentity))) ThreadIdentity(value);
    lua_setthreaddata(child, stored);
    lua_rawset(parent, -3);
    lua_pop(parent, 1);
}

bool threadIsLive(lua_State *L, lua_State *thread) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    ThreadIdentity *value = identity(thread);
    return value != nullptr && ownerIsLive(services(L), value->owner)
        && (value->source.display == OMNI_NO_DISPLAY || scriptDisplayIsLive(vm, value->source.display));
}

int resumeThread(lua_State *L) {
    lua_State *thread = lua_tothread(L, 1);
    if (thread == nullptr) {
        luaL_error(L, "coroutine.resume requires a thread");
    }
    if (!threadIsLive(L, thread)) {
        lua_pushboolean(L, false);
        lua_pushliteral(L, "the coroutine owner or display is no longer available");
        return 2;
    }
    int arguments = lua_gettop(L);
    lua_getref(L, services(L).resumeRef);
    lua_insert(L, 1);
    lua_call(L, arguments, LUA_MULTRET);
    return lua_gettop(L);
}

int wrappedThread(lua_State *L) {
    lua_State *thread = lua_tothread(L, lua_upvalueindex(1));
    if (!threadIsLive(L, thread)) {
        luaL_error(L, "the coroutine owner or display is no longer available");
    }
    int arguments = lua_gettop(L);
    lua_getref(L, services(L).resumeRef);
    lua_insert(L, 1);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 2);
    lua_call(L, arguments + 1, LUA_MULTRET);
    if (!lua_toboolean(L, 1)) {
        lua_remove(L, 1);
        lua_error(L);
    }
    lua_remove(L, 1);
    return lua_gettop(L);
}

int wrapThread(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_State *thread = lua_newthread(L);
    lua_pushvalue(L, 1);
    lua_xmove(L, thread, 1);
    lua_pushcclosure(L, wrappedThread, "wrap", 1);
    return 1;
}

void updateStoreStatus(lua_State *L, OwnerState &owner, const char *state, const char *error = nullptr) {
    owner.storeError = error == nullptr ? "" : error;
    lua_createtable(L, 0, 4);
    lua_pushstring(L, state);
    lua_setfield(L, -2, "state");
    lua_pushnumber(L, static_cast<double>(owner.revision));
    lua_setfield(L, -2, "revision");
    lua_pushnumber(L, static_cast<double>(owner.committedRevision));
    lua_setfield(L, -2, "committedRevision");
    if (error != nullptr && error[0] != '\0') {
        lua_pushlstring(L, error, std::min(std::strlen(error), size_t(512)));
        lua_setfield(L, -2, "error");
    }
    lua_setreadonly(L, -1, true);
    int ref = lua_ref(L, -1);
    lua_unref(L, owner.statusRef);
    owner.statusRef = ref;
    lua_pop(L, 1);
}

void initializeStore(lua_State *L, OwnerState &owner, const StoreSeed *seed) {
    owner.storeBytes = seed == nullptr || seed->bytes.empty()
        ? std::vector<uint8_t>{OMNI_VALUE_MAP, 0, 0, 0, 0} : seed->bytes;
    if (!pushEncodedValue(L, owner.storeBytes.data(), owner.storeBytes.size(), true)) {
        luaL_error(L, "stored snapshot could not be decoded");
    }
    int ref = lua_ref(L, -1);
    lua_unref(L, owner.storeRef);
    owner.storeRef = ref;
    lua_pop(L, 1);
    updateStoreStatus(L, owner, seed != nullptr && !seed->error.empty() ? "failed" : "ready",
        seed == nullptr ? nullptr : seed->error.c_str());
}

bool providerToken(const char *name, size_t length) {
    auto letter = [](unsigned char value) { return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z'); };
    if (name == nullptr || length == 0 || length > 64 || !letter(name[0])) { return false; }
    for (size_t index = 1; index < length; index++) {
        unsigned char value = name[index];
        if (!letter(value) && !(value >= '0' && value <= '9') && value != '_' && value != '.' && value != '-') { return false; }
    }
    return true;
}

void publishProvider(lua_State *L, OwnerState &owner, omni_provider_status status,
                     int stateIndex, const char *error, size_t errorLength, int32_t exitCode) {
    constexpr const char *names[] = {"", "starting", "running", "stopped", "exited", "failed"};
    stateIndex = lua_absindex(L, stateIndex);
    lua_createtable(L, 0, 4);
    int provider = lua_gettop(L);
    lua_pushstring(L, names[status]);
    lua_setfield(L, provider, "status");
    lua_pushvalue(L, stateIndex);
    lua_setfield(L, provider, "state");
    if (errorLength != 0) {
        lua_pushlstring(L, error, std::min(errorLength, size_t(1024)));
        lua_setfield(L, provider, "error");
    }
    if (status == OMNI_PROVIDER_EXITED) {
        lua_pushinteger(L, exitCode);
        lua_setfield(L, provider, "exitCode");
    }
    lua_setreadonly(L, provider, true);
    int next = lua_ref(L, provider);
    lua_getref(L, owner.instanceRef);
    int instance = lua_gettop(L);
    lua_pushliteral(L, "provider");
    lua_pushvalue(L, provider);
    lua_setreadonly(L, instance, false);
    lua_rawset(L, instance);
    lua_setreadonly(L, instance, true);
    lua_unref(L, owner.providerRef);
    owner.providerRef = next;
    owner.providerStatus = status;
    lua_pop(L, 2);
}

void configureProvider(lua_State *L, OwnerState &owner, bool authorized) {
    if (owner.providerRef == LUA_NOREF) {
        lua_getref(L, owner.instanceRef);
        lua_rawgetfield(L, -1, "provider");
        owner.providerRef = lua_ref(L, -1);
        lua_pop(L, 2);
    }
    if (owner.providerAuthorized == authorized) { return; }
    lua_newtable(L);
    lua_setreadonly(L, -1, true);
    publishProvider(L, owner, authorized ? OMNI_PROVIDER_STARTING : OMNI_PROVIDER_STOPPED, -1, nullptr, 0, 0);
    lua_pop(L, 1);
    owner.providerAuthorized = authorized;
}

struct ProviderUpdate {
    OwnerState *owner;
    const omni_provider_snapshot *snapshot;
};

int providerUpdateEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<ProviderUpdate>(L);
    OwnerState &owner = *input.owner;
    const omni_provider_snapshot &snapshot = *input.snapshot;
    bool replacing = snapshot.incarnation > owner.providerIncarnation;
    lua_getref(L, owner.providerRef);
    int previous = lua_gettop(L);
    lua_rawgetfield(L, previous, "state");
    int oldState = lua_gettop(L);
    lua_createtable(L, 0, 64);
    int next = lua_gettop(L);
    if (!replacing) {
        int iterator = 0;
        while ((iterator = lua_rawiter(L, oldState, iterator)) >= 0) { lua_rawset(L, next); }
    }
    std::string failure;
    for (size_t index = 0; index < snapshot.topic_count; index++) {
        const omni_provider_topic &topic = snapshot.topics[index];
        if (topic.removed) {
            lua_pushlstring(L, topic.name, topic.name_length);
            lua_pushnil(L);
            lua_rawset(L, next);
            continue;
        }
        std::string detail;
        captureCount(L, &omni_capture_stats::provider_topic_decodes);
        if (decodeJSONValue(L, topic.json, topic.json_length, true, detail)) {
            captureCount(L, &omni_capture_stats::provider_topic_decode_successes);
            lua_pushlstring(L, topic.name, topic.name_length);
            lua_insert(L, -2);
            lua_rawset(L, next);
        } else {
            failure = "invalid provider topic " + std::string(topic.name, topic.name_length) + ": " + detail;
        }
    }
    size_t count = 0;
    int iterator = 0;
    while ((iterator = lua_rawiter(L, next, iterator)) >= 0) {
        count++;
        lua_pop(L, 2);
    }
    if (count > 64) { luaL_error(L, "provider state exceeds 64 topics"); }
    lua_setreadonly(L, next, true);
    omni_provider_status status = snapshot.status == OMNI_PROVIDER_UNCHANGED
        ? (replacing ? OMNI_PROVIDER_STARTING : owner.providerStatus) : snapshot.status;
    if (failure.empty() && snapshot.error_length != 0) { failure.assign(snapshot.error, snapshot.error_length); }
    if (failure.empty() && snapshot.status == OMNI_PROVIDER_UNCHANGED && !replacing) {
        lua_rawgetfield(L, previous, "error");
        size_t length = 0;
        const char *message = lua_tolstring(L, -1, &length);
        if (message != nullptr) { failure.assign(message, length); }
        lua_pop(L, 1);
    }
    int32_t exitCode = snapshot.exit_code;
    if (status == OMNI_PROVIDER_EXITED && snapshot.status == OMNI_PROVIDER_UNCHANGED) {
        lua_rawgetfield(L, previous, "exitCode");
        exitCode = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    publishProvider(L, owner, status, next, failure.data(), failure.size(), exitCode);
    owner.providerIncarnation = snapshot.incarnation;
    return 0;
}

struct ProviderEvent {
    omni_vm *vm;
    OwnerState *owner;
    const char *name;
    size_t nameLength;
    const char *json;
    size_t jsonLength;
    bool invoked = false;
};

int providerReceiveEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<ProviderEvent>(L);
    lua_getref(L, input.vm->package.componentReceiverRef);
    lua_getref(L, input.owner->instanceRef);
    lua_call(L, 1, 1);
    if (lua_isnil(L, -1)) { return 0; }
    if (!lua_isfunction(L, -1)) { luaL_error(L, "component receive must be a function"); }
    lua_getref(L, input.owner->instanceRef);
    lua_createtable(L, 0, 3);
    int event = lua_gettop(L);
    lua_pushliteral(L, "event");
    lua_setfield(L, event, "kind");
    lua_pushlstring(L, input.name, input.nameLength);
    lua_setfield(L, event, "name");
    std::string failure;
    captureCount(L, &omni_capture_stats::provider_event_decodes);
    if (!decodeJSONValue(L, input.json, input.jsonLength, true, failure)) {
        luaL_error(L, "invalid provider event: %s", failure.c_str());
    }
    captureCount(L, &omni_capture_stats::provider_event_decode_successes);
    lua_setfield(L, event, "value");
    lua_setreadonly(L, event, true);
    input.invoked = true;
    captureCount(L, &omni_capture_stats::provider_handlers);
    lua_call(L, 2, 0);
    return 0;
}

struct ProviderResult {
    omni_owner_token owner;
    bool ok;
    const char *json;
    size_t length;
    const omni_resource_id *resources;
    size_t count;
    bool fileMode;
    bool valid;
    bool transferred = false;
};

int providerResultEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<ProviderResult>(L);
    lua_createtable(L, 0, 3);
    int result = lua_gettop(L);
    std::string failure;
    bool valid = input.valid && input.json != nullptr && input.length > 0 && input.length <= maximumProviderLineBytes;
    if (valid) {
        captureCount(L, &omni_capture_stats::provider_result_decodes);
        valid = decodeJSONValue(L, input.json, input.length, true, failure);
        if (valid) { captureCount(L, &omni_capture_stats::provider_result_decode_successes); }
    }
    if (valid && !input.ok && lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);
        valid = false;
    }
    if (valid) { lua_setfield(L, result, input.ok ? "value" : "error"); }
    else {
        lua_pushliteral(L, "invalid_response");
        lua_setfield(L, result, "error");
    }
    lua_pushboolean(L, valid && input.ok);
    lua_setfield(L, result, "ok");
    if (valid && input.ok && input.fileMode) {
        lua_createtable(L, static_cast<int>(input.count), 0);
        for (size_t index = 0; index < input.count; index++) {
            pushResource(L, input.owner, input.resources[index]);
            lua_rawseti(L, -2, static_cast<int>(index + 1));
        }
        lua_setreadonly(L, -1, true);
        lua_setfield(L, result, "files");
    }
    lua_setreadonly(L, result, true);
    input.transferred = valid && input.ok && input.fileMode;
    captureCount(L, &omni_capture_stats::provider_handlers);
    lua_call(L, 1, 0);
    return 0;
}

struct DesktopDelivery {
    omni_owner_token owner;
    const uint8_t *value;
    size_t valueLength;
    const omni_resource_id *resources;
    size_t count;
    bool valid;
    bool transferred = false;
};

int desktopDeliveryEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<DesktopDelivery>(L);
    bool valid = input.valid && input.value != nullptr && input.valueLength > 0 && input.valueLength <= 4096
        && input.value[0] == OMNI_VALUE_MAP && pushEncodedValue(L, input.value, input.valueLength, true);
    if (valid) {
        int metadata = lua_gettop(L);
        size_t fields = 0;
        int iterator = 0;
        while ((iterator = lua_rawiter(L, metadata, iterator)) >= 0) {
            size_t length = 0;
            const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &length) : nullptr;
            valid = valid && ++fields == 1 && key != nullptr && length == 2 && std::memcmp(key, "ok", 2) == 0
                && lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1);
            lua_pop(L, 2);
        }
        valid = valid && fields == 1;
    }
    lua_settop(L, 1);
    lua_createtable(L, 0, 2);
    int result = lua_gettop(L);
    lua_pushboolean(L, valid);
    lua_setfield(L, result, "ok");
    if (valid) {
        lua_createtable(L, static_cast<int>(input.count), 0);
        for (size_t index = 0; index < input.count; index++) {
            pushResource(L, input.owner, input.resources[index]);
            lua_rawseti(L, -2, static_cast<int>(index + 1));
        }
        lua_setreadonly(L, -1, true);
        lua_setfield(L, result, "items");
    } else {
        lua_pushliteral(L, "invalid_response");
        lua_setfield(L, result, "error");
    }
    lua_setreadonly(L, result, true);
    input.transferred = valid;
    captureCount(L, &omni_capture_stats::service_handlers);
    lua_call(L, 1, 0);
    return 0;
}

struct ResourcePersistenceDelivery {
    bool ok;
    std::string token;
    std::string error;
};

int resourcePersistenceDeliveryEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<ResourcePersistenceDelivery>(L);
    lua_createtable(L, 0, 3);
    lua_pushboolean(L, input.ok);
    lua_setfield(L, -2, "ok");
    lua_pushlstring(L, input.token.data(), input.token.size());
    lua_setfield(L, -2, "token");
    if (!input.error.empty()) {
        lua_pushlstring(L, input.error.data(), input.error.size());
        lua_setfield(L, -2, "error");
    }
    lua_setreadonly(L, -1, true);
    captureCount(L, &omni_capture_stats::service_handlers);
    lua_call(L, 1, 0);
    return 0;
}

struct DeliveryScope {
    lua_State *L;
    ServiceState &state;
    ShellPackage &package;
    ThreadIdentity previous;
    int previousOwner;
    bool previousDelivering;

    DeliveryScope(omni_vm *vm, omni_owner_token owner, ScriptSource source)
        : L(vm->thread), state(*vm->package.services), package(vm->package), previous(*identity(L)),
          previousOwner(package.componentOwnerRef), previousDelivering(state.delivering) {
        identity(L)->owner = owner;
        if (source.surface == 0) { source.view = OMNI_VIEW_NONE; }
        identity(L)->source = source.display != OMNI_NO_DISPLAY && scriptDisplayIsLive(vm, source.display)
            ? source : ScriptSource{};
        state.delivering = true;
        package.componentOwnerRef = state.owners[owner.owner].instanceRef;
    }

    ~DeliveryScope() {
        *identity(L) = previous;
        package.componentOwnerRef = previousOwner;
        state.delivering = previousDelivering;
    }
};

omni_status deliverOwnedCall(omni_vm *vm, omni_owner_token owner, ScriptSource source, int arguments,
                            uint64_t budget, bool provider, char *error, size_t capacity) {
    lua_State *L = vm->thread;
    DeliveryScope delivery(vm, owner, source);
    omni_status status;
    {
        CallScope scope(vm, budget);
        status = finish(vm, L, lua_pcall(L, arguments, 0, 0), error, capacity);
    }
    status = enforceBudget(vm, status, error, capacity);
    invalidateOwner(vm, owner);
    if (owner.owner != 0 && (status == OMNI_ERR_RUNTIME || (provider && status == OMNI_ERR_TIMEOUT))) {
        lua_settop(L, 0);
        lua_getref(L, vm->package.componentFailureRef);
        lua_getref(L, vm->package.services->owners[owner.owner].instanceRef);
        lua_pushstring(L, error != nullptr && capacity > 0 ? error : "component callback failed");
        CallScope scope(vm, budget);
        int outcome = lua_pcall(L, 2, 0, 0);
        status = outcome == LUA_OK ? OMNI_ERR_COMPONENT : finish(vm, L, outcome, error, capacity);
    }
    lua_settop(L, 0);
    return status;
}

ServiceRequest *requestFor(ServiceState &state, omni_owner_token owner, uint64_t id) {
    for (ServiceRequest &request : state.requests) {
        if (request.live && request.id == id && sameOwner(request.owner, owner)) {
            return &request;
        }
    }
    return nullptr;
}

bool canReserve(lua_State *L, ServiceState &state, OwnerState &owner, bool http = false) {
    uint64_t omni_capture_stats::*rejection = nullptr;
    if (state.reserved >= maximumReservations) { rejection = &omni_capture_stats::package_rejections; }
    else if (owner.reservations >= maximumOwnerReservations) { rejection = &omni_capture_stats::owner_rejections; }
    else if (state.nextID == 0) { rejection = &omni_capture_stats::id_rejections; }
    else if (state.reserved + state.cancellations.size() >= maximumReservations) { rejection = &omni_capture_stats::backlog_rejections; }
    else if (http && state.httpReserved >= maximumHTTPReservations) { rejection = &omni_capture_stats::http_rejections; }
    if (rejection == nullptr) { return true; }
    captureCount(L, rejection);
    return false;
}

ServiceRequest &reserve(lua_State *L, ServiceState &state, omni_owner_token owner, omni_service_kind kind) {
    for (size_t index = 0; index < state.requests.size(); index++) {
        ServiceRequest &request = state.requests[index];
        if (request.live) {
            continue;
        }
        state.pending.push_back(static_cast<uint16_t>(index));
        request = ServiceRequest{};
        request.live = true;
        request.owner = owner;
        request.kind = kind;
        request.id = state.nextID++;
        state.reserved++;
        if (kind == OMNI_SERVICE_HTTP) { state.httpReserved++; }
        state.owners[owner.owner].reservations++;
        auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
        if (vm->capture.capture_id != 0) {
            vm->capture.reservation_peak = std::max(vm->capture.reservation_peak, static_cast<uint64_t>(state.reserved));
            vm->capture.owner_reservation_peak = std::max(vm->capture.owner_reservation_peak, static_cast<uint64_t>(state.owners[owner.owner].reservations));
            vm->capture.http_reservation_peak = std::max(vm->capture.http_reservation_peak, static_cast<uint64_t>(state.httpReserved));
        }
        return request;
    }
    std::terminate();
}

void release(lua_State *L, ServiceState &state, ServiceRequest &request) {
    auto index = static_cast<uint16_t>(&request - state.requests.data());
    state.pending.erase(std::remove(state.pending.begin(), state.pending.end(), index), state.pending.end());
    state.reserved--;
    if (request.kind == OMNI_SERVICE_HTTP) { state.httpReserved--; }
    OwnerState &owner = state.owners[request.owner.owner];
    if (owner.live && owner.epoch == request.owner.epoch) { owner.reservations--; }
    lua_unref(L, request.callbackRef);
    lua_unref(L, request.contextRef);
    request = ServiceRequest{};
}

void cancel(lua_State *L, ServiceState &state, ServiceRequest &request) {
    if (request.cancelled) { return; }
    OwnerState &owner = state.owners[request.owner.owner];
    bool persist = request.kind == OMNI_SERVICE_RESOURCE && request.resourcePersistence;
    if (request.dispatched || request.kind == OMNI_SERVICE_STORE || persist) {
        if (state.cancellations.size() >= maximumCancellations) {
            luaL_error(L, "service cancellation queue must be drained");
        }
        state.cancellations.push_back({request.kind, request.owner, request.id, owner.revision, owner.name,
            request.kind == OMNI_SERVICE_STORE ? owner.storeBytes
                : persist && !request.dispatched ? request.bytes : std::vector<uint8_t>{}});
    }
    if (request.kind == OMNI_SERVICE_DROP || request.kind == OMNI_SERVICE_DRAG) {
        request.cancelled = true;
        lua_unref(L, request.callbackRef);
        lua_unref(L, request.contextRef);
        request.callbackRef = request.contextRef = LUA_NOREF;
        return;
    }
    if (request.kind == OMNI_SERVICE_STORE) {
        owner.storeRequest = 0;
    }
    release(L, state, request);
}

void flushRetiredStore(lua_State *L, ServiceState &state, size_t slot) {
    OwnerState &owner = state.owners[slot];
    if (!owner.live || owner.storeRequest != 0 || (owner.revision == owner.committedRevision && owner.storeError.empty())) { return; }
    if (state.cancellations.size() >= maximumCancellations) {
        luaL_error(L, "service cancellation queue must be drained");
    }
    state.cancellations.push_back({OMNI_SERVICE_STORE, token(state, slot), 0, owner.revision, owner.name, owner.storeBytes});
}

int cancelHandle(lua_State *L) {
    auto *handle = static_cast<ServiceHandle *>(luaL_checkudata(L, 1, handleMetatable));
    ServiceState &state = services(L);
    if (ServiceRequest *request = requestFor(state, handle->owner, handle->id)) {
        cancel(L, state, *request);
    }
    return 0;
}

int after(lua_State *L) {
    if (lua_type(L, 1) != LUA_TNUMBER || !lua_isfunction(L, 2)) {
        return returnedError(L, "after requires a delay and callback");
    }
    double seconds = lua_tonumber(L, 1);
    if (!std::isfinite(seconds) || seconds < 0.01 || seconds >= static_cast<double>(INT64_MAX) / 1e9) {
        return returnedError(L, "invalid timer delay");
    }
    OwnerState &owner = currentOwner(L);
    ServiceState &state = services(L);
    if (!canReserve(L, state, owner)) {
        return returnedError(L, "overloaded");
    }
    auto *handle = new (lua_newuserdata(L, sizeof(ServiceHandle))) ServiceHandle{identity(L)->owner, 0};
    luaL_getmetatable(L, handleMetatable);
    lua_setmetatable(L, -2);
    int callback = lua_ref(L, 2);
    ServiceRequest &request = reserve(L, state, handle->owner, OMNI_SERVICE_TIMER);
    request.seconds = seconds;
    request.callbackRef = callback;
    request.source = identity(L)->source;
    handle->id = request.id;
    return 1;
}

int admitStructured(lua_State *L, omni_service_kind kind, std::vector<uint8_t> bytes, int callback, bool resourceResult = false) {
    OwnerState &owner = currentOwner(L);
    ServiceState &state = services(L);
    if (!canReserve(L, state, owner, kind == OMNI_SERVICE_HTTP)) {
        return returnedError(L, "overloaded");
    }
    auto *handle = new (lua_newuserdata(L, sizeof(ServiceHandle))) ServiceHandle{identity(L)->owner, 0};
    luaL_getmetatable(L, handleMetatable);
    lua_setmetatable(L, -2);
    int callbackRef = lua_isfunction(L, callback) ? lua_ref(L, callback) : LUA_NOREF;
    ServiceRequest &request = reserve(L, state, handle->owner, kind);
    request.callbackRef = callbackRef;
    request.source = identity(L)->source;
    request.bytes = std::move(bytes);
    request.resourceResult = resourceResult;
    handle->id = request.id;
    return 1;
}

int resourceRequest(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    ServiceState &state = services(L);
    bool persist = lua_toboolean(L, lua_upvalueindex(1));
    if (lua_gettop(L) > (persist ? 2 : 1) || (persist && !lua_isnoneornil(L, 2) && !lua_isfunction(L, 2))) {
        return returnedError(L, "invalid_request");
    }
    if (!owner.resourceError.empty()) { return returnedError(L, owner.resourceError.c_str()); }
    omni_resource_id resource{};
    omni_resource_id saved{};
    ResourceRecord *source = nullptr;
    const ResourceTokenRecord *restored = nullptr;
    std::map<ResourceKey, ResourceTokenRecord> tokenPrepared;
    std::map<ResourceKey, ResourceRecord> resourcePrepared;
    if (persist) {
        if (lua_type(L, 1) != LUA_TUSERDATA || !lua_getmetatable(L, 1)) { return returnedError(L, "invalid_resource"); }
        luaL_getmetatable(L, resourceMetatable);
        bool valid = lua_rawequal(L, -1, -2);
        lua_pop(L, 2);
        if (!valid) { return returnedError(L, "invalid_resource"); }
        auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, 1));
        if (!sameOwner(proxy.owner, scriptOwner(L))) { return returnedError(L, "resource_denied"); }
        source = resourceFor(state, proxy.owner, proxy.id);
        if (source == nullptr || source->state == OMNI_RESOURCE_FAILED) { return returnedError(L, "resource_unavailable"); }
        if (owner.resourceTokens.size() >= maximumResourceTokens) { return returnedError(L, "resource_token_limit"); }
        resource = proxy.id;
    } else {
        size_t length = 0;
        const char *value = lua_type(L, 1) == LUA_TSTRING ? lua_tolstring(L, 1, &length) : nullptr;
        if (value == nullptr || length != 36 || std::memchr(value, 0, length) != nullptr) {
            return returnedError(L, "unknown_resource_token");
        }
        std::string text(value, length);
        if (uuid_parse(text.c_str(), saved.bytes) != 0) { return returnedError(L, "unknown_resource_token"); }
        auto found = owner.resourceTokens.find(resourceKey(saved));
        if (found == owner.resourceTokens.end()) { return returnedError(L, "unknown_resource_token"); }
        if (found->second.pending) { return returnedError(L, "persistence_pending"); }
        if (owner.resources.size() >= maximumResources) { return returnedError(L, "resource_limit"); }
        restored = &found->second;
    }
    if (!canReserve(L, state, owner)) { return returnedError(L, "overloaded"); }
    if (persist) {
        do { uuid_generate_random(saved.bytes); } while (owner.resourceTokens.count(resourceKey(saved)) != 0);
        tokenPrepared.emplace(resourceKey(saved), ResourceTokenRecord{source->name, source->kind, source->uti, true});
    } else {
        do { uuid_generate_random(resource.bytes); } while (owner.resources.count(resourceKey(resource)) != 0);
        ResourceRecord record;
        record.name = restored->name;
        record.kind = restored->kind;
        record.uti = restored->uti;
        resourcePrepared.emplace(resourceKey(resource), std::move(record));
    }
    lua_createtable(L, 0, 3);
    lua_pushstring(L, persist ? "persist" : "restore");
    lua_setfield(L, -2, "op");
    lua_pushlstring(L, reinterpret_cast<const char *>(resource.bytes), 16);
    lua_setfield(L, -2, "resource");
    lua_pushlstring(L, reinterpret_cast<const char *>(saved.bytes), 16);
    lua_setfield(L, -2, "token");
    std::vector<uint8_t> bytes;
    std::string failure;
    bool encoded = encodeValue(L, -1, bytes, 256, failure);
    lua_pop(L, 1);
    if (!encoded) { return returnedError(L, failure.c_str()); }
    int callback = persist && lua_isfunction(L, 2) ? lua_ref(L, 2) : LUA_NOREF;
    ServiceRequest &request = reserve(L, state, scriptOwner(L), OMNI_SERVICE_RESOURCE);
    request.callbackRef = callback;
    request.source = identity(L)->source;
    request.bytes = std::move(bytes);
    request.resourcePersistence = persist;
    request.resourceID = resource;
    request.resourceToken = saved;
    owner.resourceTokens.merge(tokenPrepared);
    owner.resources.merge(resourcePrepared);
    if (persist) {
        source->persistence = 1;
        source->persistenceToken = saved;
        source->persistenceError.clear();
        invalidateResourceReaders(static_cast<omni_vm *>(lua_callbacks(L)->userdata), scriptOwner(L), resource);
        std::string value = resourceString(saved);
        lua_pushlstring(L, value.data(), value.size());
    } else { pushResource(L, scriptOwner(L), resource); }
    return 1;
}

int desktopRequest(lua_State *L) {
    currentOwner(L);
    bool pick = lua_tointeger(L, lua_upvalueindex(1)) == 0;
    bool reveal = lua_tointeger(L, lua_upvalueindex(1)) == 2;
    if (lua_gettop(L) > 2 || (!lua_isnoneornil(L, 2) && !lua_isfunction(L, 2))) {
        return returnedError(L, "invalid_request");
    }
    lua_settop(L, 2);
    lua_createtable(L, 0, 2);
    int payload = lua_gettop(L);
    lua_pushstring(L, pick ? "pick" : reveal ? "reveal" : "open");
    lua_setfield(L, payload, "op");
    if (pick) {
        if (!lua_istable(L, 1)) { return returnedError(L, "invalid_request"); }
        int iterator = 0;
        while ((iterator = lua_rawiter(L, 1, iterator)) >= 0) {
            size_t length = 0;
            const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &length) : nullptr;
            if (key == nullptr || lua_type(L, -1) != LUA_TBOOLEAN
                || !((length == 5 && std::memcmp(key, "files", 5) == 0)
                    || (length == 8 && std::memcmp(key, "multiple", 8) == 0))) {
                return returnedError(L, "invalid_request");
            }
            lua_pop(L, 2);
        }
        lua_rawgetfield(L, 1, "files");
        bool files = lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (!files) { return returnedError(L, "invalid_request"); }
        lua_rawgetfield(L, 1, "multiple");
        bool multiple = lua_toboolean(L, -1);
        lua_pop(L, 1);
        lua_pushboolean(L, multiple);
        lua_setfield(L, payload, "multiple");
    } else if (!reveal && lua_type(L, 1) == LUA_TSTRING) {
        size_t length = 0;
        const char *text = lua_tolstring(L, 1, &length);
        if (length == 0 || length > 4096) { return returnedError(L, "invalid_url"); }
        auto letter = [](unsigned char value) { return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z'); };
        size_t colon = 0;
        while (colon < length && text[colon] != ':') { colon++; }
        if (colon == 0 || colon == length || !letter(static_cast<unsigned char>(text[0]))) { return returnedError(L, "invalid_url"); }
        for (size_t index = 0; index < length; index++) {
            unsigned char value = static_cast<unsigned char>(text[index]);
            if (value <= 32 || value == 127 || (index < colon && !letter(value)
                && !(value >= '0' && value <= '9') && value != '+' && value != '-' && value != '.')) {
                return returnedError(L, "invalid_url");
            }
        }
        if (colon == 4 && (text[0] == 'f' || text[0] == 'F') && (text[1] == 'i' || text[1] == 'I')
            && (text[2] == 'l' || text[2] == 'L') && (text[3] == 'e' || text[3] == 'E')) {
            return returnedError(L, "file_url_requires_resource");
        }
        lua_pushvalue(L, 1);
        lua_setfield(L, payload, "url");
    } else {
        if (lua_type(L, 1) != LUA_TUSERDATA || !lua_getmetatable(L, 1)) { return returnedError(L, "invalid_resource"); }
        luaL_getmetatable(L, resourceMetatable);
        bool resource = lua_rawequal(L, -1, -2);
        lua_pop(L, 2);
        if (!resource) { return returnedError(L, "invalid_resource"); }
        auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, 1));
        if (!sameOwner(proxy.owner, scriptOwner(L))) { return returnedError(L, "resource_denied"); }
        ResourceRecord *record = resourceFor(services(L), proxy.owner, proxy.id);
        if (record == nullptr) { return returnedError(L, "resource_unavailable"); }
        if (record->state != OMNI_RESOURCE_READY) { return returnedError(L, "resource_not_ready"); }
        if (record->kind != "file" && (reveal || record->kind != "url")) { return returnedError(L, "unsupported_resource"); }
        lua_pushlstring(L, reinterpret_cast<const char *>(proxy.id.bytes), sizeof(proxy.id.bytes));
        lua_setfield(L, payload, "resource");
    }
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encodeValue(L, payload, bytes, 8192, error)) { return returnedError(L, error.c_str()); }
    return admitStructured(L, OMNI_SERVICE_DESKTOP, std::move(bytes), 2, pick);
}

const char *readResourceIDs(lua_State *L, int index, bool filesOnly,
                            std::array<omni_resource_id, maximumResourceBatch> &ids, size_t &count) {
    if (!lua_istable(L, index)) { return "invalid_resources"; }
    count = lua_objlen(L, index);
    if (count == 0 || count > maximumResourceBatch) { return "invalid_resources"; }
    int iterator = 0;
    size_t entries = 0;
    while ((iterator = lua_rawiter(L, index, iterator)) >= 0) {
        double key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (++entries > count || !(key >= 1 && key <= static_cast<double>(count) && std::floor(key) == key)) {
            return "invalid_resources";
        }
        lua_pop(L, 2);
    }
    if (entries != count) { return "invalid_resources"; }
    for (size_t offset = 0; offset < count; offset++) {
        lua_rawgeti(L, index, static_cast<int>(offset + 1));
        if (lua_type(L, -1) != LUA_TUSERDATA || !lua_getmetatable(L, -1)) { return "invalid_resource"; }
        luaL_getmetatable(L, resourceMetatable);
        bool valid = lua_rawequal(L, -1, -2);
        lua_pop(L, 2);
        if (!valid) { return "invalid_resource"; }
        auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, -1));
        if (!sameOwner(proxy.owner, scriptOwner(L))) { return "resource_denied"; }
        ResourceRecord *record = resourceFor(services(L), proxy.owner, proxy.id);
        if (record == nullptr) { return "resource_unavailable"; }
        if (record->state != OMNI_RESOURCE_READY) { return "resource_not_ready"; }
        if (record->kind != "file" && record->kind != "image" && (filesOnly || (record->kind != "url" && record->kind != "text"))) {
            return "unsupported_resource";
        }
        for (size_t previous = 0; previous < offset; previous++) {
            if (std::memcmp(ids[previous].bytes, proxy.id.bytes, 16) == 0) { return "duplicate_resource"; }
        }
        ids[offset] = proxy.id;
        lua_pop(L, 1);
    }
    return nullptr;
}

const char *presentationResources(lua_State *L, int index, bool filesOnly, int payload) {
    std::array<omni_resource_id, maximumResourceBatch> ids{};
    size_t count = 0;
    if (const char *failure = readResourceIDs(L, index, filesOnly, ids, count)) { return failure; }
    lua_createtable(L, static_cast<int>(count), 0);
    for (size_t offset = 0; offset < count; offset++) {
        lua_pushlstring(L, reinterpret_cast<const char *>(ids[offset].bytes), sizeof ids[offset].bytes);
        lua_rawseti(L, -2, static_cast<int>(offset + 1));
    }
    lua_setfield(L, payload, "resources");
    return nullptr;
}

int resourceDragMarker(lua_State *) { return 0; }

struct DragDelivery {
    bool ended;
    bool copied;
    bool invoked = false;
};

int dragDeliveryEntry(lua_State *L) {
    auto &input = consumeDeliveryInput<DragDelivery>(L);
    lua_pushvalue(L, lua_upvalueindex(2));
    lua_pushvalue(L, lua_upvalueindex(3));
    lua_createtable(L, 0, 2);
    lua_pushstring(L, input.ended ? "ended" : "began");
    lua_setfield(L, -2, "phase");
    lua_pushstring(L, input.copied ? "copy" : "none");
    lua_setfield(L, -2, "operation");
    lua_setreadonly(L, -1, true);
    input.invoked = true;
    captureCount(L, &omni_capture_stats::drag_handlers);
    lua_call(L, 2, 0);
    return 0;
}

void pushDragDelivery(lua_State *L, ServiceRequest &request, DragDelivery &input) {
    lua_pushlightuserdata(L, &input);
    lua_getref(L, request.callbackRef);
    lua_getref(L, request.contextRef);
    lua_pushcclosure(L, dragDeliveryEntry, "drag", 3);
}

int presentationRequest(lua_State *L) {
    currentOwner(L);
    bool share = lua_toboolean(L, lua_upvalueindex(1));
    int optional = share ? 3 : 2;
    int last = share ? 4 : 3;
    bool shortCallback = lua_isfunction(L, optional) && lua_isnoneornil(L, last);
    int callback = shortCallback ? optional : last;
    if (lua_gettop(L) > last || (!lua_isnoneornil(L, callback) && !lua_isfunction(L, callback))) {
        return returnedError(L, "invalid_request");
    }
    lua_settop(L, last);
    lua_createtable(L, 0, 4);
    int payload = lua_gettop(L);
    lua_pushstring(L, share ? "share" : "quicklook");
    lua_setfield(L, payload, "op");
    if (const char *failure = presentationResources(L, 1, !share, payload)) { return returnedError(L, failure); }
    if (share) {
        size_t length = 0;
        const char *key = lua_type(L, 2) == LUA_TSTRING ? lua_tolstring(L, 2, &length) : nullptr;
        if (key == nullptr || length == 0 || length > 1024 || std::memchr(key, 0, length) != nullptr) {
            return returnedError(L, "invalid_anchor");
        }
        if (!shortCallback && !lua_isnil(L, 3)) {
            size_t serviceLength = 0;
            const char *service = lua_type(L, 3) == LUA_TSTRING ? lua_tolstring(L, 3, &serviceLength) : nullptr;
            if (service == nullptr || serviceLength != 7 || std::memcmp(service, "airdrop", 7) != 0) {
                return returnedError(L, "unsupported_service");
            }
            lua_pushvalue(L, 3);
            lua_setfield(L, payload, "service");
        }
        omni_desktop_anchor anchor{};
        std::string failure;
        if (!desktopAnchor(static_cast<omni_vm *>(lua_callbacks(L)->userdata), scriptOwner(L), identity(L)->source,
                           key, length, anchor, failure)) { return returnedError(L, failure.c_str()); }
        lua_pushlstring(L, reinterpret_cast<const char *>(&anchor), sizeof anchor);
        lua_setfield(L, payload, "anchor");
    } else {
        double index = shortCallback || lua_isnil(L, 2) ? 1 : lua_type(L, 2) == LUA_TNUMBER ? lua_tonumber(L, 2) : 0;
        if (!std::isfinite(index) || index < 1 || index > static_cast<double>(lua_objlen(L, 1)) || std::floor(index) != index) {
            return returnedError(L, "invalid_preview");
        }
        lua_pushnumber(L, index);
        lua_setfield(L, payload, "index");
    }
    std::vector<uint8_t> bytes;
    std::string failure;
    if (!encodeValue(L, payload, bytes, 8192, failure)) { return returnedError(L, failure.c_str()); }
    return admitStructured(L, OMNI_SERVICE_DESKTOP, std::move(bytes), callback);
}

int clipboardRequest(lua_State *L) {
    currentOwner(L);
    bool read = lua_toboolean(L, lua_upvalueindex(1));
    int callback = read ? 1 : 2;
    if (lua_gettop(L) > callback || (read ? !lua_isfunction(L, 1) : !lua_isnoneornil(L, 2) && !lua_isfunction(L, 2))) {
        return returnedError(L, "invalid_request");
    }
    lua_settop(L, callback);
    lua_createtable(L, 0, read ? 1 : 2);
    int payload = lua_gettop(L);
    lua_pushstring(L, read ? "clipboardRead" : "clipboardCopy");
    lua_setfield(L, payload, "op");
    if (!read) {
        if (lua_type(L, 1) == LUA_TSTRING) {
            size_t length = 0;
            lua_tolstring(L, 1, &length);
            if (length > (1u << 20)) { return returnedError(L, "clipboard_too_large"); }
            lua_pushvalue(L, 1);
            lua_setfield(L, payload, "text");
        } else {
            if (lua_type(L, 1) != LUA_TUSERDATA || !lua_getmetatable(L, 1)) { return returnedError(L, "invalid_resource"); }
            luaL_getmetatable(L, resourceMetatable);
            bool valid = lua_rawequal(L, -1, -2);
            lua_pop(L, 2);
            if (!valid) { return returnedError(L, "invalid_resource"); }
            auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, 1));
            if (!sameOwner(proxy.owner, scriptOwner(L))) { return returnedError(L, "resource_denied"); }
            ResourceRecord *record = resourceFor(services(L), proxy.owner, proxy.id);
            if (record == nullptr) { return returnedError(L, "resource_unavailable"); }
            if (record->state != OMNI_RESOURCE_READY) { return returnedError(L, "resource_not_ready"); }
            lua_pushlstring(L, reinterpret_cast<const char *>(proxy.id.bytes), sizeof proxy.id.bytes);
            lua_setfield(L, payload, "resource");
        }
    }
    std::vector<uint8_t> bytes;
    std::string failure;
    if (!encodeValue(L, payload, bytes, (1u << 20) + 128, failure)) { return returnedError(L, failure.c_str()); }
    return admitStructured(L, OMNI_SERVICE_DESKTOP, std::move(bytes), callback, read);
}

enum ConfigurationOperation { configurationAdd, configurationRemove, configurationMove, configurationEnable, configurationSet, configurationRoot };

bool configurationName(lua_State *L, int index) {
    if (lua_type(L, index) != LUA_TSTRING) { return false; }
    size_t length = 0;
    const char *text = lua_tolstring(L, index, &length);
    return length > 0 && length <= 128 && std::memchr(text, '\0', length) == nullptr;
}

bool configurationValue(lua_State *L, int index) {
    int type = lua_type(L, index);
    return type == LUA_TBOOLEAN || type == LUA_TSTRING || type == LUA_TTABLE
        || (type == LUA_TNUMBER && std::isfinite(lua_tonumber(L, index)));
}

int configurationWrite(lua_State *L) {
    currentOwner(L);
    ServiceState &state = services(L);
    if (!state.configurationEnabled || identity(L)->owner.owner != 0) {
        return returnedError(L, "configuration_denied");
    }
    auto operation = static_cast<ConfigurationOperation>(lua_tointeger(L, lua_upvalueindex(1)));
    int callback = operation == configurationRemove ? 2 : operation == configurationSet ? 4 : 3;
    bool omitOptions = operation == configurationAdd && lua_isfunction(L, 2) && lua_isnoneornil(L, 3);
    if (omitOptions) { callback = 2; }
    if (!configurationName(L, 1) || (!lua_isnoneornil(L, callback) && !lua_isfunction(L, callback))) {
        return returnedError(L, "invalid configuration arguments");
    }
    if ((operation == configurationAdd && !omitOptions && !lua_isnoneornil(L, 2) && !lua_istable(L, 2))
        || (operation == configurationSet && (!configurationName(L, 2) || !configurationValue(L, 3)))
        || (operation == configurationRoot && !configurationValue(L, 2))
        || (operation == configurationEnable && lua_type(L, 2) != LUA_TBOOLEAN)) {
        return returnedError(L, "invalid configuration arguments");
    }
    if (operation == configurationMove) {
        double value = lua_type(L, 2) == LUA_TNUMBER ? lua_tonumber(L, 2) : 0;
        if (!std::isfinite(value) || value < 1 || value > 64 || std::floor(value) != value) {
            return returnedError(L, "component index must be an integer between 1 and 64");
        }
    }
    constexpr const char *operations[] = {"add", "remove", "move", "enable", "set", "rootSetting"};
    lua_settop(L, operation == configurationSet ? 4 : operation == configurationRemove ? 2 : 3);
    lua_createtable(L, 0, 4);
    int payload = lua_gettop(L);
    lua_pushstring(L, operations[operation]);
    lua_setfield(L, payload, "op");
    lua_pushvalue(L, 1);
    lua_setfield(L, payload, operation == configurationAdd ? "widget" : operation == configurationRoot ? "key" : "id");
    if (operation == configurationAdd) {
        if (omitOptions || lua_isnoneornil(L, 2)) { lua_newtable(L); } else { lua_pushvalue(L, 2); }
        lua_setfield(L, payload, "options");
    } else if (operation != configurationRemove) {
        lua_pushvalue(L, 2);
        lua_setfield(L, payload, operation == configurationMove ? "index" : operation == configurationEnable ? "enabled"
            : operation == configurationSet ? "key" : "value");
        if (operation == configurationSet) {
            lua_pushvalue(L, 3);
            lua_setfield(L, payload, "value");
        }
    }
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encodeValue(L, payload, bytes, maximumConfigurationBytes, error)) { return returnedError(L, error.c_str()); }
    return admitStructured(L, OMNI_SERVICE_CONFIG, std::move(bytes), callback);
}

int httpRequest(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    if (!lua_istable(L, 1) || !lua_isfunction(L, 2)) { return returnedError(L, "invalid_request"); }
    ServiceState &state = services(L);
    if (!canReserve(L, state, owner, true)) { return returnedError(L, "overloaded"); }
    lua_settop(L, 2);
    lua_createtable(L, 0, 7);
    int payload = lua_gettop(L);
    lua_rawgetfield(L, 1, "url");
    size_t length = 0;
    const char *url = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : nullptr;
    if (url == nullptr || length == 0) {
        return returnedError(L, "invalid_url");
    }
    lua_setfield(L, payload, "url");
    lua_rawgetfield(L, 1, "method");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushliteral(L, "GET"); }
    const char *method = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : nullptr;
    if (method == nullptr || length == 0 || length > 32) {
        return returnedError(L, "invalid_request");
    }
    lua_setfield(L, payload, "method");
    lua_rawgetfield(L, 1, "response");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushliteral(L, "text"); }
    const char *response = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : nullptr;
    if (response == nullptr || !((length == 4 && (std::memcmp(response, "text", 4) == 0 || std::memcmp(response, "json", 4) == 0))
        || (length == 5 && std::memcmp(response, "bytes", 5) == 0))) {
        return returnedError(L, "invalid_request");
    }
    lua_setfield(L, payload, "response");
    lua_rawgetfield(L, 1, "maxBytes");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushinteger(L, 1 << 20); }
    double maximum = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : 0;
    if (!std::isfinite(maximum) || maximum < 1 || maximum > maximumHTTPBodyBytes || std::floor(maximum) != maximum) {
        return returnedError(L, "invalid_request");
    }
    lua_setfield(L, payload, "maxBytes");
    lua_rawgetfield(L, 1, "timeout");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_pushinteger(L, 30); }
    double timeout = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : 0;
    if (!std::isfinite(timeout) || timeout <= 0 || timeout > 120) { return returnedError(L, "invalid_request"); }
    lua_setfield(L, payload, "timeout");
    lua_rawgetfield(L, 1, "body");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
    } else if (lua_type(L, -1) == LUA_TSTRING) {
        lua_tolstring(L, -1, &length);
        if (length > maximumHTTPBodyBytes) { return returnedError(L, "body_too_large"); }
        lua_setfield(L, payload, "body");
    } else {
        if (lua_type(L, -1) != LUA_TUSERDATA || !lua_getmetatable(L, -1)) { return returnedError(L, "invalid_resource"); }
        luaL_getmetatable(L, resourceMetatable);
        bool resource = lua_rawequal(L, -1, -2);
        lua_pop(L, 2);
        if (!resource) { return returnedError(L, "invalid_resource"); }
        auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, -1));
        if (!sameOwner(proxy.owner, scriptOwner(L))) { return returnedError(L, "resource_denied"); }
        ResourceRecord *record = resourceFor(state, proxy.owner, proxy.id);
        if (record == nullptr) { return returnedError(L, "resource_unavailable"); }
        if (record->state != OMNI_RESOURCE_READY) { return returnedError(L, "resource_not_ready"); }
        lua_pushlstring(L, reinterpret_cast<const char *>(proxy.id.bytes), sizeof(proxy.id.bytes));
        lua_setfield(L, payload, "bodyResource");
        lua_pop(L, 1);
    }
    lua_rawgetfield(L, 1, "headers");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); lua_newtable(L); }
    if (!lua_istable(L, -1)) { return returnedError(L, "invalid_request"); }
    int headers = lua_gettop(L);
    lua_newtable(L);
    int copiedHeaders = lua_gettop(L);
    size_t headerBytes = 0;
    size_t headerCount = 0;
    int iterator = 0;
    while ((iterator = lua_rawiter(L, headers, iterator)) >= 0) {
        if (++headerCount > 128 || lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
            return returnedError(L, "invalid_request");
        }
        size_t nameLength = 0, valueLength = 0;
        lua_tolstring(L, -2, &nameLength);
        lua_tolstring(L, -1, &valueLength);
        if (nameLength == 0 || nameLength > maximumHTTPHeaderBytes - headerBytes) { return returnedError(L, "invalid_request"); }
        headerBytes += nameLength;
        if (valueLength > maximumHTTPHeaderBytes - headerBytes) { return returnedError(L, "invalid_request"); }
        headerBytes += valueLength;
        lua_rawset(L, copiedHeaders);
    }
    lua_remove(L, headers);
    lua_setfield(L, payload, "headers");
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encodeValue(L, payload, bytes, maximumHTTPRequestBytes, error)) { return returnedError(L, error.c_str()); }
    return admitStructured(L, OMNI_SERVICE_HTTP, std::move(bytes), 2);
}

const char *providerFiles(lua_State *L, std::array<omni_resource_id, maximumResourceBatch> &files,
                          size_t &count, bool &fileMode) {
    if (!lua_istable(L, 3)) { return nullptr; }
    lua_rawgetfield(L, 3, "files");
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return nullptr; }
    fileMode = true;
    if (!lua_istable(L, -1)) { return "invalid provider files"; }
    int list = lua_gettop(L);
    count = lua_objlen(L, list);
    if (count > maximumResourceBatch) { return "invalid provider files"; }
    int iterator = 0;
    size_t entries = 0;
    while ((iterator = lua_rawiter(L, list, iterator)) >= 0) {
        double index = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;
        if (++entries > count || !(index >= 1 && index <= static_cast<double>(count) && std::floor(index) == index)) {
            return "invalid provider files";
        }
        lua_pop(L, 2);
    }
    if (entries != count) { return "invalid provider files"; }
    for (size_t index = 0; index < count; index++) {
        lua_rawgeti(L, list, static_cast<int>(index + 1));
        if (lua_type(L, -1) != LUA_TUSERDATA || !lua_getmetatable(L, -1)) { return "invalid_resource"; }
        luaL_getmetatable(L, resourceMetatable);
        bool resource = lua_rawequal(L, -1, -2);
        lua_pop(L, 2);
        if (!resource) { return "invalid_resource"; }
        auto &proxy = *static_cast<ResourceProxy *>(lua_touserdata(L, -1));
        if (!sameOwner(proxy.owner, scriptOwner(L))) { return "resource_denied"; }
        ResourceRecord *record = resourceFor(services(L), proxy.owner, proxy.id);
        if (record == nullptr) { return "resource_unavailable"; }
        if (record->state == OMNI_RESOURCE_FAILED) { return "resource_failed"; }
        for (size_t previous = 0; previous < index; previous++) {
            if (std::memcmp(files[previous].bytes, proxy.id.bytes, 16) == 0) { return "duplicate_resource"; }
        }
        files[index] = proxy.id;
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return nullptr;
}

int providerSend(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    ServiceState &state = services(L);
    if (identity(L)->owner.owner == 0 || !owner.providerAuthorized) { return returnedError(L, "provider_denied"); }
    if (owner.providerStatus != OMNI_PROVIDER_STARTING && owner.providerStatus != OMNI_PROVIDER_RUNNING) {
        return returnedError(L, "provider_unavailable");
    }
    size_t nameLength = 0;
    const char *name = lua_type(L, 1) == LUA_TSTRING ? lua_tolstring(L, 1, &nameLength) : nullptr;
    if (!providerToken(name, nameLength) || (!lua_isnoneornil(L, 3) && !lua_istable(L, 3))
        || (!lua_isnoneornil(L, 4) && !lua_isfunction(L, 4))) { return returnedError(L, "invalid provider arguments"); }
    lua_settop(L, 4);
    std::array<omni_resource_id, maximumResourceBatch> files{};
    size_t fileCount = 0;
    bool fileMode = false;
    if (const char *failure = providerFiles(L, files, fileCount, fileMode)) { return returnedError(L, failure); }
    if (!canReserve(L, state, owner)) { return returnedError(L, "overloaded"); }
    std::string prefix = "[\"action\",\"r" + std::to_string(state.nextID) + "\",\"" + std::string(name, nameLength) + "\",";
    std::vector<uint8_t> json;
    std::string error;
    if (!encodeJSONValue(L, 2, json, maximumProviderLineBytes - prefix.size() - 2, error)) { return returnedError(L, error.c_str()); }
    std::vector<uint8_t> bytes;
    bytes.reserve(json.size() + nameLength + (fileMode ? 49 : 35) + fileCount * 21);
    auto count = [&](uint32_t value) {
        auto *start = reinterpret_cast<const uint8_t *>(&value);
        bytes.insert(bytes.end(), start, start + sizeof value);
    };
    auto blob = [&](const char *value, size_t length) {
        count(static_cast<uint32_t>(length));
        bytes.insert(bytes.end(), reinterpret_cast<const uint8_t *>(value), reinterpret_cast<const uint8_t *>(value) + length);
    };
    bytes.push_back(OMNI_VALUE_MAP); count(fileMode ? 3 : 2);
    blob("name", 4); bytes.push_back(OMNI_VALUE_STRING); blob(name, nameLength);
    blob("argsJSON", 8); bytes.push_back(OMNI_VALUE_STRING); blob(reinterpret_cast<const char *>(json.data()), json.size());
    if (fileMode) {
        blob("files", 5); bytes.push_back(OMNI_VALUE_ARRAY); count(static_cast<uint32_t>(fileCount));
        for (size_t index = 0; index < fileCount; index++) {
            bytes.push_back(OMNI_VALUE_STRING); blob(reinterpret_cast<const char *>(files[index].bytes), 16);
        }
    }
    return admitStructured(L, OMNI_SERVICE_PROVIDER, std::move(bytes), 4, fileMode);
}

int storeGet(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    if (lua_type(L, 1) != LUA_TSTRING) {
        return returnedError(L, "store keys must be strings");
    }
    lua_getref(L, owner.storeRef);
    lua_pushvalue(L, 1);
    lua_rawget(L, -2);
    return 1;
}

int storeSet(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    ServiceState &state = services(L);
    if (lua_type(L, 1) != LUA_TSTRING) {
        return returnedError(L, "store keys must be strings");
    }
    lua_settop(L, 2);
    if (owner.storeRequest == 0 && !canReserve(L, state, owner)) {
        return returnedError(L, "overloaded");
    }
    lua_getref(L, owner.storeRef);
    lua_newtable(L);
    int iterator = 0;
    while ((iterator = lua_rawiter(L, 3, iterator)) >= 0) {
        lua_rawset(L, 4);
    }
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_rawset(L, 4);
    std::vector<uint8_t> bytes;
    std::string error;
    if (!encodeValue(L, 4, bytes, maximumStoreBytes, error)) {
        return returnedError(L, error.c_str());
    }
    if (bytes == owner.storeBytes && owner.storeError.empty()) {
        lua_pushboolean(L, true);
        return 1;
    }
    if (!pushEncodedValue(L, bytes.data(), bytes.size(), true)) {
        return returnedError(L, "store snapshot could not be decoded");
    }
    int storeRef = lua_ref(L, -1);
    lua_unref(L, owner.storeRef);
    owner.storeRef = storeRef;
    owner.storeBytes = std::move(bytes);
    owner.revision++;
    if (owner.storeRequest == 0) {
        ServiceRequest &request = reserve(L, state, identity(L)->owner, OMNI_SERVICE_STORE);
        owner.storeRequest = request.id;
    }
    ServiceRequest *request = requestFor(state, identity(L)->owner, owner.storeRequest);
    if (!request->dispatched) {
        request->revision = owner.revision;
    }
    updateStoreStatus(L, owner, "pending");
    lua_pushboolean(L, true);
    return 1;
}

int storeIndex(lua_State *L) {
    OwnerState &owner = currentOwner(L);
    if (lua_type(L, 2) == LUA_TSTRING && std::strcmp(lua_tostring(L, 2), "status") == 0) {
        lua_getref(L, owner.statusRef);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

}

omni_owner_token scriptOwner(lua_State *L) {
    ThreadIdentity *thread = identity(L);
    return thread == nullptr ? omni_owner_token{} : thread->owner;
}

uint32_t scriptDisplay(lua_State *L) {
    ThreadIdentity *thread = identity(L);
    return thread == nullptr ? OMNI_NO_DISPLAY : thread->source.display;
}

bool scriptOwnerIsLive(lua_State *L) {
    return identity(L) != nullptr && ownerIsLive(services(L), identity(L)->owner);
}

ScriptSourceScope::ScriptSourceScope(lua_State *thread, ScriptSource source)
    : L(thread), previous(identity(thread)->source) {
    if (source.surface == 0) { source.view = OMNI_VIEW_NONE; }
    identity(L)->source = source;
}

ScriptSourceScope::~ScriptSourceScope() {
    identity(L)->source = previous;
}

void setScriptDisplay(lua_State *L, uint32_t display) {
    identity(L)->source = {display, OMNI_VIEW_NONE, 0};
}

omni_owner_token switchScriptOwner(lua_State *L, int context) {
    ThreadIdentity *thread = identity(L);
    omni_owner_token previous = thread->owner;
    ServiceState &state = services(L);
    if (context == 0) {
        thread->owner = token(state, 0);
        return previous;
    }
    lua_rawgetfield(L, context, "instance");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_pushvalue(L, context);
    }
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    lua_getref(L, vm->package.componentOwnersRef);
    lua_pushvalue(L, -2);
    lua_rawget(L, -2);
    int slot = lua_isnumber(L, -1) ? lua_tointeger(L, -1) : -1;
    lua_pop(L, 3);
    if (slot <= 0 || static_cast<size_t>(slot) >= state.owners.size() || !state.owners[slot].live) {
        luaL_error(L, "the component owner is no longer available");
    }
    thread->owner = token(state, static_cast<size_t>(slot));
    return previous;
}

void restoreScriptOwner(lua_State *L, omni_owner_token owner) {
    identity(L)->owner = owner;
}

bool isServiceCall(omni_vm *vm) {
    return vm->package.services != nullptr && vm->package.services->delivering;
}

void queueServiceMessage(lua_State *L, omni_message_kind kind, const char *text, size_t length) {
    ServiceState &state = services(L);
    auto &messages = state.messages[kind];
    size_t limit = kind == OMNI_MESSAGE_REQUEST ? 16 : 32;
    if (messages.size() >= limit) {
        if (kind == OMNI_MESSAGE_REQUEST) {
            luaL_error(L, "a callback can run at most 16 commands");
        }
        return;
    }
    messages.push_back({std::string(text, std::min(length, size_t(512))), scriptOwner(L), scriptDisplay(L)});
}

void componentServiceOwner(lua_State *L, int object, bool alive, bool provider) {
    auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
    ServiceState &state = services(L);
    lua_getref(L, vm->package.componentOwnersRef);
    int owners = lua_gettop(L);
    lua_pushvalue(L, object);
    lua_rawget(L, owners);
    int existing = lua_isnumber(L, -1) ? lua_tointeger(L, -1) : -1;
    lua_pop(L, 1);
    if (!alive) {
        if (existing > 0) {
            OwnerState &owner = state.owners[existing];
            retireRenderOwner(vm, {state.generation, static_cast<uint32_t>(existing), owner.epoch});
            flushRetiredStore(L, state, static_cast<size_t>(existing));
            for (ServiceRequest &request : state.requests) {
                if (request.live && request.owner.owner == static_cast<uint32_t>(existing)) {
                    cancel(L, state, request);
                }
            }
            state.seeds[owner.name] = {owner.storeBytes, owner.storeError};
            clearResources(L, owner);
            owner.live = false;
            owner.reservations = 0;
            for (int ref : {owner.instanceRef, owner.storeRef, owner.statusRef, owner.providerRef}) {
                lua_unref(L, ref);
            }
            owner.instanceRef = owner.storeRef = owner.statusRef = LUA_NOREF;
            owner.providerRef = LUA_NOREF;
            owner.storeBytes.clear();
            lua_pushvalue(L, object);
            lua_pushnil(L);
            lua_rawset(L, owners);
        }
        lua_pop(L, 1);
        return;
    }
    if (existing > 0) {
        OwnerState &owner = state.owners[existing];
        bool changed = owner.providerAuthorized != provider;
        configureProvider(L, owner, provider);
        if (changed) { invalidateOwner(vm, token(state, static_cast<size_t>(existing))); }
        lua_pop(L, 1);
        return;
    }
    size_t slot = 1;
    while (slot < state.owners.size() && state.owners[slot].live) {
        slot++;
    }
    if (slot == state.owners.size()) {
        luaL_error(L, "at most 64 component service owners may be active");
    }
    OwnerState &owner = state.owners[slot];
    uint32_t epoch = owner.epoch + 1;
    if (epoch == 0) {
        luaL_error(L, "component owner epoch exhausted");
    }
    owner = OwnerState{};
    owner.epoch = epoch;
    owner.live = true;
    lua_rawgetfield(L, object, "id");
    size_t length = 0;
    const char *name = lua_tolstring(L, -1, &length);
    owner.name.assign(name, length);
    lua_pop(L, 1);
    owner.instanceRef = lua_ref(L, object);
    configureProvider(L, owner, provider);
    auto seed = state.seeds.find(owner.name);
    initializeStore(L, owner, seed == state.seeds.end() ? nullptr : &seed->second);
    if (seed != state.seeds.end()) {
        state.seeds.erase(seed);
    }
    auto resourceSeed = state.resourceSeeds.find(owner.name);
    if (resourceSeed != state.resourceSeeds.end()) {
        owner.resourceTokens = std::move(resourceSeed->second.tokens);
        owner.resourceError = std::move(resourceSeed->second.error);
        state.resourceSeeds.erase(resourceSeed);
    }
    lua_pushvalue(L, object);
    lua_pushinteger(L, static_cast<int>(slot));
    lua_rawset(L, owners);
    lua_pop(L, 1);
}

bool resourceImage(lua_State *L, int index, std::string &recipe) {
    omni_owner_token owner = scriptOwner(L);
    omni_resource_id id{};
    if (lua_type(L, index) == LUA_TUSERDATA) {
        auto &proxy = *static_cast<ResourceProxy *>(luaL_checkudata(L, index, resourceMetatable));
        if (!sameOwner(proxy.owner, owner)) { luaL_error(L, "resource belongs to another owner"); }
        id = proxy.id;
    } else if (lua_type(L, index) == LUA_TSTRING) {
        size_t length = 0;
        const char *value = lua_tolstring(L, index, &length);
        if (length >= 15 && std::memcmp(value, "@omni-resource:", 15) == 0) {
            luaL_error(L, "resource image references can only be issued by the host");
        }
        if (length != 36) { return false; }
        std::string text(value, length);
        if (uuid_parse(text.c_str(), id.bytes) != 0 || resourceFor(services(L), owner, id) == nullptr) { return false; }
    } else { return false; }
    ResourceRecord *record = resourceFor(services(L), owner, id);
    if (record == nullptr) { luaL_error(L, "resource is no longer available"); }
    recordResourceRead(L, owner, id);
    recipe = "v1/" + std::to_string(owner.generation) + "/" + std::to_string(owner.owner) + "/"
        + std::to_string(owner.epoch) + "/" + resourceString(id) + "/" + std::to_string(record->revision);
    return true;
}


void pushResourceDrag(lua_State *L, int index) {
    std::array<omni_resource_id, maximumResourceBatch> ids{};
    size_t count = 0;
    if (const char *failure = readResourceIDs(L, index, false, ids, count)) { luaL_error(L, "dragItems: %s", failure); }
    omni_owner_token owner = scriptOwner(L);
    for (size_t offset = 0; offset < count; offset++) { recordResourceRead(L, owner, ids[offset]); }
    lua_pushlstring(L, reinterpret_cast<const char *>(ids.data()), count * sizeof(omni_resource_id));
    lua_pushcclosure(L, resourceDragMarker, "dragItems", 1);
}

omni_status reserveDrag(omni_vm *vm, uint32_t display, omni_view view, uint32_t declaration, uint32_t action,
                        uint64_t source, omni_owner_token *owner, uint64_t *id, omni_resource_id *resources,
                        size_t resourceCapacity, size_t *count, char *error, size_t errorCapacity) {
    if (owner != nullptr) { *owner = {}; }
    if (id != nullptr) { *id = 0; }
    if (count != nullptr) { *count = 0; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (owner == nullptr || id == nullptr || count == nullptr || resources == nullptr) { return OMNI_ERR_INTERNAL; }
    lua_State *L = vm->thread;
    int function = LUA_NOREF;
    int context = LUA_NOREF;
    try {
        lua_settop(L, 0);
        omni_owner_token target{};
        if (source == 0 || !publishedDrag(vm, display, view, declaration, action)
            || !pushPublishedAction(vm, display, view, declaration, L, target)
            || lua_tocfunction(L, 1) != resourceDragMarker || lua_getupvalue(L, 1, 1) == nullptr) {
            lua_settop(L, 0);
            copyMessage("the drag declaration is no longer available", error, errorCapacity);
            return OMNI_ERR_STALE_ACTION;
        }
        size_t length = 0;
        const char *raw = lua_tolstring(L, -1, &length);
        size_t itemCount = length / sizeof(omni_resource_id);
        if (raw == nullptr || itemCount == 0 || itemCount > maximumResourceBatch
            || length % sizeof(omni_resource_id) != 0 || itemCount > resourceCapacity) {
            lua_settop(L, 0);
            copyMessage("invalid drag resource capacity", error, errorCapacity);
            return OMNI_ERR_RUNTIME;
        }
        std::array<omni_resource_id, maximumResourceBatch> values{};
        std::memcpy(values.data(), raw, length);
        ServiceState &state = *vm->package.services;
        for (size_t index = 0; index < itemCount; index++) {
            ResourceRecord *record = resourceFor(state, target, values[index]);
            if (record == nullptr || record->state != OMNI_RESOURCE_READY) {
                lua_settop(L, 0);
                copyMessage("drag resource is not ready", error, errorCapacity);
                return OMNI_ERR_STALE_ACTION;
            }
        }
        lua_settop(L, 0);
        if (action != 0) {
            omni_owner_token handler{};
            if (!pushPublishedAction(vm, display, view, action, L, handler) || !sameOwner(target, handler)) {
                lua_settop(L, 0);
                copyMessage("the drag handler is no longer available", error, errorCapacity);
                return OMNI_ERR_STALE_ACTION;
            }
        }
        if (!ownerIsLive(state, target) || !canReserve(L, state, state.owners[target.owner])) {
            lua_settop(L, 0);
            copyMessage("service_overload", error, errorCapacity);
            return OMNI_ERR_RUNTIME;
        }
        if (action != 0) { function = lua_ref(L, 1); context = lua_ref(L, 2); }
        ServiceRequest &request = reserve(L, state, target, OMNI_SERVICE_DRAG);
        state.pending.pop_back();
        request.dispatched = true;
        request.callbackRef = function;
        request.contextRef = context;
        request.source = {display, view, source};
        request.action = action;
        *owner = target;
        *id = request.id;
        *count = itemCount;
        std::copy(values.begin(), values.begin() + itemCount, resources);
        lua_settop(L, 0);
        return OMNI_OK;
    } catch (...) {
        lua_unref(L, function);
        lua_unref(L, context);
        lua_settop(L, 0);
        copyMessage("could not reserve the drag operation", error, errorCapacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status reserveDrop(omni_vm *vm, uint32_t display, omni_view view, uint32_t action, uint64_t source,
                        omni_owner_token *owner, uint64_t *id, char *error, size_t capacity) {
    if (owner != nullptr) { *owner = {}; }
    if (id != nullptr) { *id = 0; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (owner == nullptr || id == nullptr) { return OMNI_ERR_INTERNAL; }
    lua_State *L = vm->thread;
    int function = LUA_NOREF;
    int context = LUA_NOREF;
    try {
        lua_settop(L, 0);
        omni_owner_token target{};
        if (!pushPublishedAction(vm, display, view, action, L, target)) {
            copyMessage("the drop handler is no longer available", error, capacity);
            return OMNI_ERR_STALE_ACTION;
        }
        ServiceState &state = *vm->package.services;
        if (!ownerIsLive(state, target) || !canReserve(L, state, state.owners[target.owner])) {
            lua_settop(L, 0);
            copyMessage("service_overload", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        function = lua_ref(L, 1);
        context = lua_ref(L, 2);
        ServiceRequest &request = reserve(L, state, target, OMNI_SERVICE_DROP);
        state.pending.pop_back();
        request.dispatched = true;
        request.callbackRef = function;
        request.contextRef = context;
        request.source = {display, view, source};
        request.action = action;
        *owner = target;
        *id = request.id;
        lua_settop(L, 0);
        return OMNI_OK;
    } catch (...) {
        lua_unref(L, function);
        lua_unref(L, context);
        lua_settop(L, 0);
        copyMessage("could not reserve the drop operation", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}

void installServices(lua_State *L, ShellPackage &package) {
    package.services = new ServiceState();
    ServiceState &state = *package.services;
    state.owners[0].live = true;
    state.owners[0].epoch = 1;
    initializeStore(L, state.owners[0], nullptr);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "k");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    state.threadsRef = lua_ref(L, -1);
    lua_pop(L, 1);
    threadCreated(L, L);
    lua_callbacks(L)->userthread = threadCreated;
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "resume");
    state.resumeRef = lua_ref(L, -1);
    lua_pop(L, 1);
    lua_pushcfunction(L, resumeThread, "resume");
    lua_setfield(L, -2, "resume");
    lua_pushcfunction(L, wrapThread, "wrap");
    lua_setfield(L, -2, "wrap");
    lua_pop(L, 1);
    luaL_newmetatable(L, resourceMetatable);
    lua_pushcfunction(L, resourceIndex, "resource");
    lua_setfield(L, -2, "__index");
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true);
    lua_pop(L, 1);
    luaL_newmetatable(L, handleMetatable);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, cancelHandle, "cancel");
    lua_setfield(L, -2, "cancel");
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true);
    lua_pop(L, 1);
    lua_getglobal(L, "omniwm");
    lua_newtable(L);
    lua_pushboolean(L, true);
    lua_pushcclosure(L, resourceRequest, "persist", 1);
    lua_setfield(L, -2, "persist");
    lua_pushboolean(L, false);
    lua_pushcclosure(L, resourceRequest, "restore", 1);
    lua_setfield(L, -2, "restore");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "resources");
    constexpr const char *desktopNames[] = {"pick", "open", "reveal"};
    for (int index = 0; index < 3; index++) {
        lua_pushinteger(L, index);
        lua_pushcclosure(L, desktopRequest, desktopNames[index], 1);
        lua_setfield(L, -2, desktopNames[index]);
    }
    for (bool share : {false, true}) {
        lua_pushboolean(L, share);
        lua_pushcclosure(L, presentationRequest, share ? "share" : "quicklook", 1);
        lua_setfield(L, -2, share ? "share" : "quicklook");
    }
    lua_newtable(L);
    for (bool read : {false, true}) {
        lua_pushboolean(L, read);
        lua_pushcclosure(L, clipboardRequest, read ? "read" : "copy", 1);
        lua_setfield(L, -2, read ? "read" : "copy");
    }
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "clipboard");
    lua_pushcfunction(L, after, "after");
    lua_setfield(L, -2, "after");
    lua_pushcfunction(L, httpRequest, "http");
    lua_setfield(L, -2, "http");
    lua_newtable(L);
    lua_pushcfunction(L, providerSend, "send");
    lua_setfield(L, -2, "send");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "provider");
    lua_getfield(L, -1, "components");
    constexpr const char *operations[] = {"add", "remove", "move", "enable", "set"};
    for (int operation = configurationAdd; operation <= configurationSet; operation++) {
        lua_pushinteger(L, operation);
        lua_pushcclosure(L, configurationWrite, operations[operation], 1);
        lua_setfield(L, -2, operations[operation]);
    }
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushinteger(L, configurationRoot);
    lua_pushcclosure(L, configurationWrite, "set", 1);
    lua_setfield(L, -2, "set");
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "config");
    lua_newtable(L);
    lua_pushcfunction(L, storeGet, "get");
    lua_setfield(L, -2, "get");
    lua_pushcfunction(L, storeSet, "set");
    lua_setfield(L, -2, "set");
    lua_newtable(L);
    lua_pushcfunction(L, storeIndex, "store");
    lua_setfield(L, -2, "__index");
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true);
    lua_setmetatable(L, -2);
    lua_setreadonly(L, -1, true);
    lua_setfield(L, -2, "store");
    lua_pop(L, 1);
}

void clearStoreSeeds(omni_vm *vm) {
    vm->package.services->seeds.clear();
    vm->package.services->resourceSeeds.clear();
}

void destroyServices(omni_vm *vm) noexcept {
    delete vm->package.services;
    vm->package.services = nullptr;
}

}

using namespace omni_detail;

omni_status omni_vm_set_service_generation(omni_vm *vm, uint64_t generation) noexcept {
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    if (generation == 0 || vm->loads != 0 || state.reserved != 0 || !vm->package.instances.empty()) { return OMNI_ERR_RUNTIME; }
    state.generation = generation;
    identity(vm->main)->owner = token(state, 0);
    identity(vm->thread)->owner = token(state, 0);
    return OMNI_OK;
}

omni_status omni_vm_set_configuration_enabled(omni_vm *vm, bool enabled) noexcept {
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    vm->package.services->configurationEnabled = enabled;
    return OMNI_OK;
}

omni_status omni_vm_seed_store(omni_vm *vm, const char *owner_name, size_t owner_name_length,
    const uint8_t *value, size_t value_length, const char *store_error, size_t store_error_length,
    char *error, size_t error_capacity) noexcept {
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (owner_name_length > 128 || (owner_name_length != 0 && owner_name == nullptr)
        || value_length > maximumStoreBytes || (value_length != 0 && value == nullptr)
        || (store_error_length != 0 && store_error == nullptr)) {
        copyMessage("invalid store snapshot", error, error_capacity);
        return OMNI_ERR_RUNTIME;
    }
    lua_State *L = vm->thread;
    try {
        ServiceState &state = *vm->package.services;
        if (value_length != 0) {
            bool valid = value[0] == OMNI_VALUE_MAP && pushEncodedValue(L, value, value_length, true);
            lua_settop(L, 0);
            if (!valid) {
                copyMessage("store snapshot must contain an encoded map", error, error_capacity);
                return OMNI_ERR_RUNTIME;
            }
        }
        StoreSeed seed;
        if (value_length != 0) { seed.bytes.assign(value, value + value_length); }
        if (store_error_length != 0) { seed.error.assign(store_error, std::min(store_error_length, size_t(512))); }
        if (owner_name_length == 0) {
            if (vm->loads != 0) {
                copyMessage("root store must be seeded before loading the script", error, error_capacity);
                return OMNI_ERR_RUNTIME;
            }
            initializeStore(L, state.owners[0], &seed);
        } else {
            std::string name(owner_name, owner_name_length);
            if (state.seeds.size() >= maximumOwners - 1 && state.seeds.find(name) == state.seeds.end()) {
                copyMessage("at most 64 component stores may be seeded", error, error_capacity);
                return OMNI_ERR_RUNTIME;
            }
            state.seeds[std::move(name)] = std::move(seed);
        }
        return OMNI_OK;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("could not initialize store snapshot", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_next_service(omni_vm *vm, omni_service_request *out) noexcept {
    if (vm->inCall || out == nullptr) { return false; }
    ServiceState &state = *vm->package.services;
    *out = {};
    if (!state.cancellations.empty()) {
        state.outbound = std::move(state.cancellations.front());
        state.cancellations.pop_front();
        const Cancellation &cancelled = state.outbound;
        *out = {cancelled.kind, cancelled.owner, cancelled.id, cancelled.revision, 0, true,
            cancelled.name.data(), cancelled.name.size(), cancelled.bytes.data(), cancelled.bytes.size(),
            OMNI_NO_DISPLAY, OMNI_VIEW_NONE, 0};
        return true;
    }
    if (state.pending.empty()) { return false; }
    ServiceRequest &request = state.requests[state.pending.front()];
    state.pending.pop_front();
    request.dispatched = true;
    const OwnerState &owner = state.owners[request.owner.owner];
    *out = {request.kind, request.owner, request.id, request.revision, request.seconds, false,
        owner.name.data(), owner.name.size(), request.kind == OMNI_SERVICE_STORE ? owner.storeBytes.data() : request.bytes.data(),
        request.kind == OMNI_SERVICE_STORE ? owner.storeBytes.size() : request.bytes.size(),
        request.source.display, request.source.view, request.source.surface};
    return true;
}

omni_status omni_vm_complete_service(omni_vm *vm, omni_owner_token owner_token, uint64_t id, uint64_t revision,
    const uint8_t *value, size_t value_length, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner_token, id);
    if (request == nullptr || request->kind == OMNI_SERVICE_DROP || request->kind == OMNI_SERVICE_DRAG || request->kind == OMNI_SERVICE_RESOURCE || !request->dispatched || !ownerIsLive(state, owner_token)) { return OMNI_OK; }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        OwnerState &owner = state.owners[owner_token.owner];
        if (request->kind == OMNI_SERVICE_STORE) {
            if (revision != request->revision) { return OMNI_OK; }
            bool ok = false;
            std::string failure = "store commit failed";
            if (value_length <= 4096 && pushEncodedValue(L, value, value_length, false) && lua_istable(L, -1)) {
                lua_rawgetfield(L, -1, "ok");
                ok = lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1);
                lua_pop(L, 1);
                lua_rawgetfield(L, -1, "error");
                if (lua_type(L, -1) == LUA_TSTRING) {
                    size_t length = 0;
                    const char *text = lua_tolstring(L, -1, &length);
                    failure.assign(text, std::min(length, size_t(512)));
                }
            }
            lua_settop(L, 0);
            if (handled != nullptr) { *handled = true; }
            if (ok) { owner.committedRevision = revision; }
            if (ok && owner.revision > revision) {
                state.pending.push_back(static_cast<uint16_t>(request - state.requests.data()));
                request->dispatched = false;
                request->revision = owner.revision;
                updateStoreStatus(L, owner, "pending");
            } else {
                owner.storeRequest = 0;
                release(L, state, *request);
                updateStoreStatus(L, owner, ok ? "ready" : "failed", ok ? nullptr : failure.c_str());
            }
            invalidateOwner(vm, owner_token);
            return OMNI_OK;
        }
        bool hasCallback = request->callbackRef != LUA_NOREF;
        omni_service_kind kind = request->kind;
        if (hasCallback) { lua_getref(L, request->callbackRef); }
        ScriptSource source = request->source;
        release(L, state, *request);
        if (handled != nullptr) { *handled = true; }
        if (!hasCallback) { return OMNI_OK; }
        int arguments = 0;
        if (kind != OMNI_SERVICE_TIMER) {
            size_t limit = kind == OMNI_SERVICE_HTTP ? maximumHTTPCompletionBytes : maximumConfigurationBytes;
            int depth = kind == OMNI_SERVICE_HTTP ? 65 : 64;
            if (value == nullptr || value_length == 0 || value_length > limit || value[0] != OMNI_VALUE_MAP
                || !pushEncodedValue(L, value, value_length, true, depth)) {
                lua_createtable(L, 0, 2);
                lua_pushboolean(L, false);
                lua_setfield(L, -2, "ok");
                lua_pushliteral(L, "invalid_response");
                lua_setfield(L, -2, "error");
                lua_setreadonly(L, -1, true);
            }
            arguments = 1;
        }
        captureCount(vm, kind == OMNI_SERVICE_PROVIDER ? &omni_capture_stats::provider_handlers : &omni_capture_stats::service_handlers);
        return deliverOwnedCall(vm, owner_token, source, arguments, budget_ns, false, error, error_capacity);
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception delivering service", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_component_owner(omni_vm *vm, const char *id, size_t length, omni_owner_token *out) noexcept {
    if (vm->inCall || out == nullptr || id == nullptr) { return false; }
    ServiceState &state = *vm->package.services;
    for (size_t slot = 1; slot < state.owners.size(); slot++) {
        const OwnerState &owner = state.owners[slot];
        if (owner.live && owner.name.size() == length && std::memcmp(owner.name.data(), id, length) == 0) {
            *out = token(state, slot);
            return true;
        }
    }
    return false;
}

omni_status omni_vm_provider_update(omni_vm *vm, omni_owner_token owner, const omni_provider_snapshot *snapshot,
    uint64_t budget_ns, bool *applied, char *error, size_t error_capacity) noexcept {
    if (applied != nullptr) { *applied = false; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    if (!ownerIsLive(state, owner) || owner.owner == 0 || !state.owners[owner.owner].providerAuthorized) { return OMNI_OK; }
    OwnerState &target = state.owners[owner.owner];
    if (snapshot == nullptr || snapshot->incarnation == 0 || static_cast<unsigned>(snapshot->status) > OMNI_PROVIDER_FAILED
        || snapshot->topic_count > 64 || (snapshot->topic_count != 0 && snapshot->topics == nullptr)
        || snapshot->error_length > 1024 || (snapshot->error_length != 0 && snapshot->error == nullptr)) {
        copyMessage("invalid provider snapshot", error, error_capacity);
        return OMNI_ERR_COMPONENT;
    }
    if (snapshot->incarnation < target.providerIncarnation) { return OMNI_OK; }
    size_t bytes = 0;
    uint64_t topics = 0;
    for (size_t index = 0; index < snapshot->topic_count; index++) {
        const omni_provider_topic &topic = snapshot->topics[index];
        if (!providerToken(topic.name, topic.name_length) || topic.json_length > maximumProviderLineBytes
            || (!topic.removed && topic.json == nullptr)) {
            copyMessage("invalid provider topic", error, error_capacity);
            return OMNI_ERR_COMPONENT;
        }
        bytes += topic.json_length;
        if (vm->capture.capture_id != 0 && !topic.removed) { topics++; }
        for (size_t prior = 0; prior < index; prior++) {
            const omni_provider_topic &other = snapshot->topics[prior];
            if (other.name_length == topic.name_length && std::memcmp(other.name, topic.name, topic.name_length) == 0) {
                copyMessage("duplicate provider topic", error, error_capacity);
                return OMNI_ERR_COMPONENT;
            }
        }
    }
    if (bytes > maximumProviderStateBytes) {
        copyMessage("provider state exceeds 1 MiB", error, error_capacity);
        return OMNI_ERR_COMPONENT;
    }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        captureCount(vm, &omni_capture_stats::provider_topic_inputs, topics);
        ProviderUpdate input{&target, snapshot};
        lua_pushlightuserdata(L, &input);
        lua_pushcclosure(L, providerUpdateEntry, "provider update", 1);
        omni_status status = deliverOwnedCall(vm, owner, {}, 0, budget_ns, true, error, error_capacity);
        if (status == OMNI_OK && applied != nullptr) { *applied = true; }
        return status;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception updating provider state", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_provider_receive(omni_vm *vm, omni_owner_token owner, uint64_t incarnation,
    const char *name, size_t name_length, const char *json, size_t json_length, uint64_t budget_ns,
    bool *handled, char *error, size_t error_capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    if (!ownerIsLive(state, owner) || owner.owner == 0 || !state.owners[owner.owner].providerAuthorized
        || incarnation == 0 || incarnation != state.owners[owner.owner].providerIncarnation) { return OMNI_OK; }
    if (!providerToken(name, name_length) || json == nullptr || json_length > maximumProviderLineBytes) {
        copyMessage("invalid provider event", error, error_capacity);
        return OMNI_ERR_COMPONENT;
    }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        ProviderEvent input{vm, &state.owners[owner.owner], name, name_length, json, json_length};
        lua_pushlightuserdata(L, &input);
        lua_pushcclosure(L, providerReceiveEntry, "provider receive", 1);
        omni_status status = deliverOwnedCall(vm, owner, {}, 0, budget_ns, true, error, error_capacity);
        if (handled != nullptr) { *handled = input.invoked; }
        return status;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception delivering provider event", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_complete_provider(omni_vm *vm, omni_owner_token owner, uint64_t id, bool ok,
    const char *json, size_t json_length, const omni_resource_id *resources, size_t resource_count,
    uint64_t budget_ns, bool *handled, bool *resources_transferred, char *error, size_t error_capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (resources_transferred != nullptr) { *resources_transferred = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_PROVIDER || !request->dispatched || !ownerIsLive(state, owner)) {
        return OMNI_OK;
    }
    lua_State *L = vm->thread;
    ProviderResult input{owner, ok, json, json_length, resources, resource_count, request->resourceResult, false};
    try {
        lua_settop(L, 0);
        bool hasCallback = request->callbackRef != LUA_NOREF;
        input.valid = resource_count <= maximumResourceBatch && (resource_count == 0 || resources != nullptr)
            && (resource_count == 0 || (ok && input.fileMode));
        if (input.valid) {
            for (size_t index = 0; index < resource_count; index++) {
                ResourceRecord *record = resourceFor(state, owner, resources[index]);
                input.valid = input.valid && record != nullptr && record->state == OMNI_RESOURCE_READY;
                for (size_t previous = 0; previous < index; previous++) {
                    input.valid = input.valid && std::memcmp(resources[index].bytes, resources[previous].bytes, 16) != 0;
                }
            }
        }
        ScriptSource source = request->source;
        if (hasCallback) {
            lua_pushlightuserdata(L, &input);
            lua_pushcclosure(L, providerResultEntry, "provider result", 1);
            lua_getref(L, request->callbackRef);
        }
        release(L, state, *request);
        if (handled != nullptr) { *handled = true; }
        if (!hasCallback) { return OMNI_OK; }
        omni_status status = deliverOwnedCall(vm, owner, source, 1, budget_ns, true, error, error_capacity);
        if (resources_transferred != nullptr) { *resources_transferred = input.transferred; }
        return status;
    } catch (...) {
        if (resources_transferred != nullptr) { *resources_transferred = input.transferred; }
        lua_settop(L, 0);
        copyMessage("unexpected exception delivering provider result", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_seed_resource_tokens(omni_vm *vm, const char *owner_name, size_t owner_name_length,
    const omni_resource_token_descriptor *tokens, size_t count, const char *load_error, size_t load_error_length,
    char *error, size_t error_capacity) noexcept {
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (owner_name_length > 128 || (owner_name_length != 0 && owner_name == nullptr)
        || count > maximumResourceTokens || (count != 0 && tokens == nullptr)
        || !boundedResourceString(load_error, load_error_length, 1024) || (load_error_length != 0 && count != 0)) {
        copyMessage("invalid resource token snapshot", error, error_capacity);
        return OMNI_ERR_RUNTIME;
    }
    try {
        ServiceState &state = *vm->package.services;
        if (owner_name_length == 0 && vm->loads != 0) {
            copyMessage("root resources must be seeded before loading the script", error, error_capacity);
            return OMNI_ERR_RUNTIME;
        }
        ResourceSeed seed;
        if (load_error_length != 0) { seed.error.assign(load_error, load_error_length); }
        for (size_t index = 0; index < count; index++) {
            const auto &input = tokens[index];
            const auto &descriptor = input.descriptor;
            if (!boundedResourceString(descriptor.name, descriptor.name_length, 1024, false)
                || !boundedResourceString(descriptor.kind, descriptor.kind_length, 64, false)
                || !boundedResourceString(descriptor.uti, descriptor.uti_length, 256, false)
                || seed.tokens.count(resourceKey(input.token)) != 0) {
                copyMessage("invalid resource token descriptor", error, error_capacity);
                return OMNI_ERR_RUNTIME;
            }
            seed.tokens.emplace(resourceKey(input.token), ResourceTokenRecord{
                std::string(descriptor.name, descriptor.name_length), std::string(descriptor.kind, descriptor.kind_length),
                std::string(descriptor.uti, descriptor.uti_length), false});
        }
        if (owner_name_length == 0) {
            state.owners[0].resourceTokens = std::move(seed.tokens);
            state.owners[0].resourceError = std::move(seed.error);
        } else {
            std::string name(owner_name, owner_name_length);
            if (state.resourceSeeds.size() >= maximumOwners - 1 && state.resourceSeeds.find(name) == state.resourceSeeds.end()) {
                copyMessage("at most 64 component resource snapshots may be seeded", error, error_capacity);
                return OMNI_ERR_RUNTIME;
            }
            state.resourceSeeds[std::move(name)] = std::move(seed);
        }
        return OMNI_OK;
    } catch (...) {
        copyMessage("could not initialize resource token snapshot", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_complete_resource(omni_vm *vm, omni_owner_token owner, uint64_t id,
    bool ok, uint64_t revision, uint64_t size, bool has_size, const char *operation_error, size_t operation_error_length,
    uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_RESOURCE || !request->dispatched || !ownerIsLive(state, owner)) {
        return OMNI_OK;
    }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        bool valid = boundedResourceString(operation_error, operation_error_length, 1024)
            && (ok ? operation_error_length == 0 : operation_error_length != 0)
            && (request->resourcePersistence || !ok || revision != 0);
        ResourcePersistenceDelivery input{valid && ok, resourceString(request->resourceToken),
            valid ? std::string(operation_error == nullptr ? "" : operation_error, operation_error_length) : "invalid_response"};
        ResourceRecord *resource = resourceFor(state, owner, request->resourceID);
        if (request->resourcePersistence) {
            auto &tokens = state.owners[owner.owner].resourceTokens;
            auto saved = tokens.find(resourceKey(request->resourceToken));
            if (saved == tokens.end() || !saved->second.pending) {
                input.ok = false;
                input.error = "invalid_response";
            } else if (input.ok) { saved->second.pending = false; }
            else { tokens.erase(saved); }
            if (resource != nullptr && resourceKey(resource->persistenceToken) == resourceKey(request->resourceToken)) {
                resource->persistence = input.ok ? 2 : 3;
                resource->persistenceError = input.error;
            }
        } else if (resource != nullptr && (revision > resource->revision || resource->state == OMNI_RESOURCE_PENDING || !valid)) {
            if (revision > resource->revision) { resource->revision = revision; }
            else if (resource->revision == 0) { resource->revision = 1; }
            resource->state = input.ok ? OMNI_RESOURCE_READY : OMNI_RESOURCE_FAILED;
            resource->size = size;
            resource->hasSize = input.ok && has_size;
            resource->error = input.error;
        }
        invalidateResourceReaders(vm, owner, request->resourceID);
        bool hasCallback = request->callbackRef != LUA_NOREF;
        ScriptSource source = request->source;
        if (hasCallback) {
            lua_pushlightuserdata(L, &input);
            lua_pushcclosure(L, resourcePersistenceDeliveryEntry, "resource persistence", 1);
            lua_getref(L, request->callbackRef);
        }
        release(L, state, *request);
        if (handled != nullptr) { *handled = true; }
        return hasCallback ? deliverOwnedCall(vm, owner, source, 1, budget_ns, false, error, error_capacity) : OMNI_OK;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("unexpected exception delivering resource result", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_complete_desktop(omni_vm *vm, omni_owner_token owner, uint64_t id,
    const uint8_t *value, size_t value_length, const omni_resource_id *resources, size_t count,
    uint64_t budget_ns, bool *handled, bool *resources_transferred, char *error, size_t error_capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (resources_transferred != nullptr) { *resources_transferred = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_DESKTOP || !request->dispatched || !ownerIsLive(state, owner)) {
        return OMNI_OK;
    }
    lua_State *L = vm->thread;
    DesktopDelivery input{owner, value, value_length, resources, count, false};
    try {
        lua_settop(L, 0);
        bool hasCallback = request->callbackRef != LUA_NOREF;
        bool valid = request->resourceResult && count <= maximumResourceBatch && (count == 0 || resources != nullptr);
        if (valid) {
            for (size_t index = 0; index < count; index++) {
                valid = valid && resourceFor(state, owner, resources[index]) != nullptr;
                for (size_t previous = 0; previous < index; previous++) {
                    valid = valid && std::memcmp(resources[index].bytes, resources[previous].bytes, 16) != 0;
                }
            }
        }
        ScriptSource source = request->source;
        input.valid = valid;
        if (hasCallback) {
            lua_pushlightuserdata(L, &input);
            lua_pushcclosure(L, desktopDeliveryEntry, "desktop result", 1);
            lua_getref(L, request->callbackRef);
        }
        release(L, state, *request);
        if (handled != nullptr) { *handled = true; }
        if (!hasCallback) { return OMNI_OK; }
        omni_status status = deliverOwnedCall(vm, owner, source, 1, budget_ns, false, error, error_capacity);
        if (resources_transferred != nullptr) { *resources_transferred = input.transferred; }
        return status;
    } catch (...) {
        if (resources_transferred != nullptr) { *resources_transferred = input.transferred; }
        lua_settop(L, 0);
        copyMessage("unexpected exception delivering desktop result", error, error_capacity);
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_cancel_service(omni_vm *vm, omni_owner_token owner, uint64_t id) noexcept {
    if (vm->inCall) { return false; }
    try {
        ServiceState &state = *vm->package.services;
        if (ServiceRequest *request = requestFor(state, owner, id)) {
            cancel(vm->thread, state, *request);
            return true;
        }
    } catch (...) {
    }
    return false;
}

omni_status omni_vm_close_services(omni_vm *vm) noexcept {
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    try {
        ServiceState &state = *vm->package.services;
        for (size_t slot = 0; slot < state.owners.size(); slot++) { flushRetiredStore(vm->thread, state, slot); }
        for (ServiceRequest &request : state.requests) {
            if (request.live) { cancel(vm->thread, state, request); }
        }
        for (OwnerState &owner : state.owners) {
            clearResources(vm->thread, owner);
            owner.live = false;
            owner.reservations = 0;
        }
        state.seeds.clear();
        return OMNI_OK;
    } catch (...) {
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_capture_snapshot(const omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) noexcept {
    if (vm == nullptr || out == nullptr || vm->inCall || capture_id == 0 || vm->capture.capture_id != capture_id) { return false; }
    *out = vm->capture;
    out->vm_bytes = vm->used;
    const ServiceState &state = *vm->package.services;
    out->reservations = state.reserved;
    out->http_reservations = state.httpReserved;
    return true;
}

bool omni_vm_capture_begin(omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) noexcept {
    if (vm == nullptr || out == nullptr || vm->inCall || capture_id == 0 || vm->capture.capture_id != 0) { return false; }
    vm->capture = {};
    vm->capture.capture_id = capture_id;
    vm->capture.vm_bytes_begin = vm->used;
    const ServiceState &state = *vm->package.services;
    vm->capture.reservation_peak = state.reserved;
    vm->capture.http_reservation_peak = state.httpReserved;
    for (const OwnerState &owner : state.owners) {
        vm->capture.owner_reservation_peak = std::max(vm->capture.owner_reservation_peak, static_cast<uint64_t>(owner.reservations));
    }
    return omni_vm_capture_snapshot(vm, capture_id, out);
}

bool omni_vm_capture_end(omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) noexcept {
    if (!omni_vm_capture_snapshot(vm, capture_id, out)) { return false; }
    vm->capture = {};
    return true;
}

omni_service_stats omni_vm_service_stats(const omni_vm *vm) noexcept {
    const ServiceState &state = *vm->package.services;
    return {static_cast<uint32_t>(state.reserved), static_cast<uint32_t>(state.pending.size()), static_cast<uint32_t>(state.cancellations.size())};
}

size_t omni_vm_message_count(const omni_vm *vm, omni_message_kind kind) noexcept {
    return static_cast<unsigned>(kind) < 2 ? vm->package.services->messages[kind].size() : 0;
}

const char *omni_vm_message(const omni_vm *vm, omni_message_kind kind, size_t index, size_t *length) noexcept {
    if (length != nullptr) { *length = 0; }
    if (static_cast<unsigned>(kind) >= 2 || index >= vm->package.services->messages[kind].size()) { return nullptr; }
    const std::string &text = vm->package.services->messages[kind][index].text;
    if (length != nullptr) { *length = text.size(); }
    return text.data();
}

bool omni_vm_message_origin(const omni_vm *vm, omni_message_kind kind, size_t index, omni_owner_token *owner, uint32_t *display_id) noexcept {
    if (static_cast<unsigned>(kind) >= 2 || index >= vm->package.services->messages[kind].size()) { return false; }
    const OwnedMessage &message = vm->package.services->messages[kind][index];
    if (owner != nullptr) { *owner = message.owner; }
    if (display_id != nullptr) { *display_id = message.display; }
    return true;
}

void omni_vm_clear_messages(omni_vm *vm) noexcept {
    if (vm->inCall) { return; }
    for (auto &messages : vm->package.services->messages) { messages.clear(); }
}

omni_status omni_vm_admit_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_descriptor *descriptors,
                                    size_t count, omni_resource_id *ids, char *error, size_t capacity) noexcept {
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (count == 0 || count > maximumResourceBatch || descriptors == nullptr || ids == nullptr) {
        copyMessage("resource admission requires one to 32 items", error, capacity);
        return OMNI_ERR_RUNTIME;
    }
    try {
        ServiceState &state = *vm->package.services;
        if (!ownerIsLive(state, owner)) { return OMNI_ERR_STALE_ACTION; }
        auto &resources = state.owners[owner.owner].resources;
        if (resources.size() + count > maximumResources) {
            copyMessage("resource_limit", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        std::map<ResourceKey, ResourceRecord> prepared;
        std::array<omni_resource_id, maximumResourceBatch> admitted{};
        for (size_t index = 0; index < count; index++) {
            const omni_resource_descriptor &input = descriptors[index];
            if (!boundedResourceString(input.name, input.name_length, 1024, false)
                || !boundedResourceString(input.kind, input.kind_length, 64, false)
                || !boundedResourceString(input.uti, input.uti_length, 256, false)) {
                copyMessage("invalid resource metadata", error, capacity);
                return OMNI_ERR_RUNTIME;
            }
            ResourceRecord record;
            record.name.assign(input.name, input.name_length);
            record.kind.assign(input.kind, input.kind_length);
            record.uti.assign(input.uti, input.uti_length);
            do { uuid_generate_random(admitted[index].bytes); }
            while (resources.count(resourceKey(admitted[index])) != 0 || prepared.count(resourceKey(admitted[index])) != 0);
            prepared.emplace(resourceKey(admitted[index]), std::move(record));
        }
        resources.merge(prepared);
        std::copy_n(admitted.begin(), count, ids);
        return OMNI_OK;
    } catch (...) {
        copyMessage("could not admit resource handles", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_release_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_id *ids, size_t count) noexcept {
    if (vm == nullptr || vm->inCall || count > maximumResourceBatch || (count != 0 && ids == nullptr)) { return false; }
    try {
        ServiceState &state = *vm->package.services;
        if (!ownerIsLive(state, owner)) { return false; }
        auto &resources = state.owners[owner.owner].resources;
        for (size_t index = 0; index < count; index++) {
            if (resources.count(resourceKey(ids[index])) == 0) { return false; }
            for (size_t prior = 0; prior < index; prior++) {
                if (resourceKey(ids[prior]) == resourceKey(ids[index])) { return false; }
            }
        }
        for (size_t index = 0; index < count; index++) {
            auto found = resources.find(resourceKey(ids[index]));
            lua_unref(vm->thread, found->second.proxyRef);
            resources.erase(found);
            invalidateResourceReaders(vm, owner, ids[index]);
        }
        return true;
    } catch (...) { return false; }
}

omni_status omni_vm_update_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_update *updates,
                                     size_t count, bool *applied, char *error, size_t capacity) noexcept {
    if (applied != nullptr) { *applied = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    if (count > maximumResourceBatch || (count != 0 && updates == nullptr)) { return OMNI_ERR_RUNTIME; }
    try {
        ServiceState &state = *vm->package.services;
        if (!ownerIsLive(state, owner)) { return OMNI_OK; }
        std::array<std::string, maximumResourceBatch> errors;
        for (size_t index = 0; index < count; index++) {
            const auto &input = updates[index];
            if (resourceFor(state, owner, input.id) == nullptr || input.revision == 0
                || static_cast<unsigned>(input.state) > OMNI_RESOURCE_FAILED
                || !boundedResourceString(input.error, input.error_length, 1024)) {
                copyMessage("invalid resource update", error, capacity);
                return OMNI_ERR_RUNTIME;
            }
            for (size_t prior = 0; prior < index; prior++) {
                if (resourceKey(updates[prior].id) == resourceKey(input.id)) {
                    copyMessage("duplicate resource update", error, capacity);
                    return OMNI_ERR_RUNTIME;
                }
            }
            if (input.error_length != 0) { errors[index].assign(input.error, input.error_length); }
        }
        for (size_t index = 0; index < count; index++) {
            const auto &input = updates[index];
            ResourceRecord &record = *resourceFor(state, owner, input.id);
            if (input.revision <= record.revision) { continue; }
            record.revision = input.revision;
            record.state = input.state;
            record.hasSize = input.has_size;
            record.size = input.size;
            record.error = std::move(errors[index]);
            invalidateResourceReaders(vm, owner, input.id);
            if (applied != nullptr) { *applied = true; }
        }
        return OMNI_OK;
    } catch (...) {
        copyMessage("could not update resource metadata", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}

size_t omni_vm_resource_count(const omni_vm *vm, omni_owner_token owner) noexcept {
    if (vm == nullptr) { return 0; }
    ServiceState &state = *vm->package.services;
    return ownerIsLive(state, owner) ? state.owners[owner.owner].resources.size() : 0;
}

omni_status omni_vm_deliver_drop(omni_vm *vm, omni_owner_token owner, uint64_t id,
                                const omni_resource_id *resources, size_t count, double x, double y,
                                uint64_t budget, bool *handled, char *error, size_t capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_DROP || request->cancelled || request->delivered
        || !ownerIsLive(state, owner)) { return OMNI_OK; }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        omni_owner_token publishedOwner{};
        if (!pushPublishedAction(vm, request->source.display, request->source.view, request->action, L, publishedOwner)
            || !sameOwner(owner, publishedOwner)) {
            lua_settop(L, 0);
            copyMessage("the drop target is no longer available", error, capacity);
            return OMNI_ERR_STALE_ACTION;
        }
        lua_settop(L, 0);
        if (count == 0 || count > maximumResourceBatch || resources == nullptr || !std::isfinite(x) || !std::isfinite(y)) {
            copyMessage("invalid drop event", error, capacity);
            return OMNI_ERR_RUNTIME;
        }
        for (size_t index = 0; index < count; index++) {
            if (resourceFor(state, owner, resources[index]) == nullptr) {
                copyMessage("drop contains an unavailable resource", error, capacity);
                return OMNI_ERR_RUNTIME;
            }
        }
        request->delivered = true;
        DropDelivery input{request, resources, count, x, y};
        lua_pushlightuserdata(L, &input);
        lua_pushcclosure(L, dropDeliveryEntry, "drop", 1);
        omni_status status = deliverOwnedCall(vm, owner, request->source, 0, budget, true, error, capacity);
        lua_unref(L, request->callbackRef);
        lua_unref(L, request->contextRef);
        request->callbackRef = request->contextRef = LUA_NOREF;
        if (handled != nullptr) { *handled = input.invoked; }
        return status;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("could not deliver the drop event", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}

bool omni_vm_finish_drop(omni_vm *vm, omni_owner_token owner, uint64_t id) noexcept {
    if (vm == nullptr || vm->inCall) { return false; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_DROP) { return false; }
    release(vm->thread, state, *request);
    return true;
}



omni_status omni_vm_begin_drag(omni_vm *vm, omni_owner_token owner, uint64_t id, uint64_t budget,
                               bool *handled, char *error, size_t capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_DRAG || request->cancelled || request->delivered
        || !ownerIsLive(state, owner)) { return OMNI_OK; }
    request->delivered = true;
    if (request->callbackRef == LUA_NOREF) { return OMNI_OK; }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        DragDelivery input{false, false};
        pushDragDelivery(L, *request, input);
        omni_status status = deliverOwnedCall(vm, owner, request->source, 0, budget, true, error, capacity);
        if (handled != nullptr) { *handled = input.invoked; }
        return status;
    } catch (...) {
        lua_settop(L, 0);
        copyMessage("could not deliver drag begin", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}

omni_status omni_vm_finish_drag(omni_vm *vm, omni_owner_token owner, uint64_t id, bool copied, bool deliver,
                                uint64_t budget, bool *handled, char *error, size_t capacity) noexcept {
    if (handled != nullptr) { *handled = false; }
    if (vm == nullptr) { return OMNI_ERR_INTERNAL; }
    if (vm->inCall) { return OMNI_ERR_REENTRANT; }
    ServiceState &state = *vm->package.services;
    ServiceRequest *request = requestFor(state, owner, id);
    if (request == nullptr || request->kind != OMNI_SERVICE_DRAG) { return OMNI_OK; }
    lua_State *L = vm->thread;
    try {
        lua_settop(L, 0);
        bool invoke = deliver && request->delivered && !request->cancelled && ownerIsLive(state, owner)
            && request->callbackRef != LUA_NOREF;
        ScriptSource source = request->source;
        DragDelivery input{true, copied};
        if (invoke) { pushDragDelivery(L, *request, input); }
        release(L, state, *request);
        request = nullptr;
        if (!invoke) { return OMNI_OK; }
        omni_status status = deliverOwnedCall(vm, owner, source, 0, budget, true, error, capacity);
        if (handled != nullptr) { *handled = input.invoked; }
        return status;
    } catch (...) {
        if (request != nullptr) { release(L, state, *request); }
        lua_settop(L, 0);
        copyMessage("could not finish the drag operation", error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}
