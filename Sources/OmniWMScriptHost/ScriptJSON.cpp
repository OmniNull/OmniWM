// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"

#include <array>
#include <charconv>
#include <cmath>
#include <cstring>
#include <limits>

namespace {

constexpr size_t jsonLimit = 4 * 1024 * 1024;
constexpr int valueDepth = 64;
char nullIdentity;
char arrayIdentity;

bool markedArray(lua_State *L, int index) {
    index = lua_absindex(L, index);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &arrayIdentity);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    lua_pushvalue(L, index);
    lua_rawget(L, -2);
    bool result = lua_toboolean(L, -1);
    lua_pop(L, 2);
    return result;
}

struct NativeBudget {
    lua_State *L;
    size_t work = 0;

    void check(size_t amount = 1) {
        work += amount;
        if (work < 4096) { return; }
        work = 0;
        auto *vm = static_cast<omni_vm *>(lua_callbacks(L)->userdata);
        if (vm != nullptr && vm->inCall && (vm->latched || omni_detail::threadCPU() - vm->callStartCPU > vm->budget)) {
            vm->latched = true;
            luaL_error(L, "script exceeded CPU budget");
        }
    }
};

size_t utf8Width(const char *bytes, size_t remaining) {
    unsigned char first = static_cast<unsigned char>(bytes[0]);
    if (first < 0x80) { return 1; }
    size_t width = first >= 0xC2 && first <= 0xDF ? 2
        : first >= 0xE0 && first <= 0xEF ? 3
        : first >= 0xF0 && first <= 0xF4 ? 4 : 0;
    if (width == 0 || remaining < width) { return 0; }
    for (size_t index = 1; index < width; index++) {
        unsigned char next = static_cast<unsigned char>(bytes[index]);
        if (next < 0x80 || next > 0xBF) { return 0; }
    }
    unsigned char second = static_cast<unsigned char>(bytes[1]);
    if ((first == 0xE0 && second < 0xA0) || (first == 0xED && second >= 0xA0)
        || (first == 0xF0 && second < 0x90) || (first == 0xF4 && second >= 0x90)) { return 0; }
    return width;
}

}

namespace omni_detail {

bool isJSONNull(lua_State *L, int index) {
    return lua_islightuserdata(L, index) && lua_tolightuserdata(L, index) == &nullIdentity;
}

void pushJSONNull(lua_State *L) {
    lua_pushlightuserdata(L, &nullIdentity);
}

void markJSONArray(lua_State *L, int index) {
    index = lua_absindex(L, index);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &arrayIdentity);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_newtable(L);
        lua_pushliteral(L, "k");
        lua_setfield(L, -2, "__mode");
        lua_setmetatable(L, -2);
        lua_pushvalue(L, -1);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &arrayIdentity);
    }
    lua_pushvalue(L, index);
    lua_pushboolean(L, true);
    lua_rawset(L, -3);
    lua_pop(L, 1);
}

}

namespace {

struct Encoder {
    lua_State *L;
    std::vector<uint8_t> &output;
    size_t limit;
    std::string &error;
    bool wire;
    NativeBudget budget;
    std::array<const void *, valueDepth + 1> parents{};

    bool fail(const char *message) {
        error = message;
        return false;
    }

    bool append(const void *bytes, size_t length) {
        if (length > limit - output.size()) { return fail("encoded value exceeds byte limit"); }
        const auto *start = static_cast<const uint8_t *>(bytes);
        output.insert(output.end(), start, start + length);
        budget.check(length);
        return true;
    }

    bool byte(uint8_t value) { return append(&value, 1); }
    bool count(uint32_t value) { return append(&value, sizeof value); }

    bool string(const char *value, size_t length) {
        if (wire) { return count(static_cast<uint32_t>(length)) && append(value, length); }
        if (!byte('"')) { return false; }
        for (size_t index = 0; index < length;) {
            unsigned char character = static_cast<unsigned char>(value[index]);
            if (character < 0x20) {
                constexpr char hex[] = "0123456789abcdef";
                char escaped[] = {'\\', 'u', '0', '0', hex[character >> 4], hex[character & 15]};
                if (!append(escaped, sizeof escaped)) { return false; }
                index++;
            } else if (character == '"' || character == '\\') {
                if (!byte('\\') || !byte(character)) { return false; }
                index++;
            } else {
                size_t width = utf8Width(value + index, length - index);
                if (width == 0) { return fail("JSON strings must contain valid UTF-8"); }
                if (!append(value + index, width)) { return false; }
                index += width;
            }
        }
        return byte('"');
    }

    bool value(int index, int depth) {
        if (depth > valueDepth) { return fail("value exceeds depth 64"); }
        if (!lua_checkstack(L, 6)) { return fail("value exceeds stack capacity"); }
        index = lua_absindex(L, index);
        budget.check();
        int type = lua_type(L, index);
        if (type == LUA_TNIL || omni_detail::isJSONNull(L, index)) {
            return wire ? byte(OMNI_VALUE_NIL) : append("null", 4);
        }
        if (type == LUA_TBOOLEAN) {
            bool boolean = lua_toboolean(L, index);
            return wire ? byte(boolean ? OMNI_VALUE_TRUE : OMNI_VALUE_FALSE)
                : append(boolean ? "true" : "false", boolean ? 4 : 5);
        }
        if (type == LUA_TNUMBER) {
            double number = lua_tonumber(L, index);
            if (!std::isfinite(number)) { return fail("values require finite numbers"); }
            if (wire) { return byte(OMNI_VALUE_NUMBER) && append(&number, sizeof number); }
            char buffer[64];
            auto converted = std::to_chars(buffer, buffer + sizeof buffer, number);
            return converted.ec == std::errc() ? append(buffer, static_cast<size_t>(converted.ptr - buffer))
                : fail("number cannot be encoded");
        }
        if (type == LUA_TSTRING) {
            size_t length = 0;
            const char *bytes = lua_tolstring(L, index, &length);
            if (length > limit) { return fail("encoded value exceeds byte limit"); }
            return (!wire || byte(OMNI_VALUE_STRING)) && string(bytes, length);
        }
        if (type != LUA_TTABLE) { return fail("values require nil, booleans, numbers, strings, arrays or records"); }
        const void *identity = lua_topointer(L, index);
        for (int parent = 0; parent < depth; parent++) {
            if (parents[parent] == identity) { return fail("values must be acyclic"); }
        }
        parents[depth] = identity;
        uint32_t arrays = 0;
        uint32_t records = 0;
        int length = lua_objlen(L, index);
        int iterator = 0;
        while ((iterator = lua_rawiter(L, index, iterator)) >= 0) {
            budget.check();
            int keyType = lua_type(L, -2);
            if (keyType == LUA_TSTRING) { records++; }
            else if (keyType == LUA_TNUMBER) {
                double key = lua_tonumber(L, -2);
                if (key < 1 || key > length || key != std::floor(key)) {
                    return fail("values require dense arrays or string-keyed records");
                }
                arrays++;
            } else { return fail("values require dense arrays or string-keyed records"); }
            lua_pop(L, 2);
            if (arrays != 0 && records != 0) { return fail("values cannot mix array and record keys"); }
            if (static_cast<size_t>(arrays) + records > limit) { return fail("encoded value exceeds byte limit"); }
        }
        if (arrays != 0 && arrays != static_cast<uint32_t>(length)) { return fail("values require dense arrays"); }
        bool array = arrays != 0 || (records == 0 && markedArray(L, index));
        if (wire) {
            if (!byte(array ? OMNI_VALUE_ARRAY : OMNI_VALUE_MAP) || !count(array ? arrays : records)) { return false; }
        } else if (!byte(array ? '[' : '{')) { return false; }
        if (array) {
            for (uint32_t element = 1; element <= arrays; element++) {
                if (!wire && element != 1 && !byte(',')) { return false; }
                lua_rawgeti(L, index, static_cast<int>(element));
                if (!value(-1, depth + 1)) { return false; }
                lua_pop(L, 1);
            }
        } else {
            iterator = 0;
            bool first = true;
            while ((iterator = lua_rawiter(L, index, iterator)) >= 0) {
                if (!wire && !first && !byte(',')) { return false; }
                first = false;
                size_t size = 0;
                const char *key = lua_tolstring(L, -2, &size);
                if (!string(key, size) || (!wire && !byte(':')) || !value(-1, depth + 1)) { return false; }
                lua_pop(L, 2);
            }
        }
        return wire || byte(array ? ']' : '}');
    }
};

struct Parser {
    lua_State *L;
    const char *cursor;
    const char *end;
    std::string error;
    NativeBudget budget;
    bool readonly = false;

    bool fail(const char *message) {
        error = message;
        return false;
    }

    void whitespace() {
        while (cursor != end && (*cursor == ' ' || *cursor == '\n' || *cursor == '\r' || *cursor == '\t')) {
            cursor++;
            budget.check();
        }
    }

    bool hex(uint32_t &value) {
        if (end - cursor < 4) { return fail("incomplete Unicode escape"); }
        value = 0;
        for (int index = 0; index < 4; index++) {
            char digit = *cursor++;
            unsigned number = digit >= '0' && digit <= '9' ? digit - '0'
                : digit >= 'a' && digit <= 'f' ? digit - 'a' + 10
                : digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : 16;
            if (number == 16) { return fail("invalid Unicode escape"); }
            value = value * 16 + number;
        }
        return true;
    }

    bool string() {
        if (cursor == end || *cursor++ != '"') { return fail("expected JSON string"); }
        std::string decoded;
        while (cursor != end) {
            budget.check();
            unsigned char character = static_cast<unsigned char>(*cursor++);
            if (character == '"') {
                lua_pushlstring(L, decoded.data(), decoded.size());
                return true;
            }
            if (character < 0x20) { return fail("unescaped control character in JSON string"); }
            if (character != '\\') {
                const char *start = cursor - 1;
                size_t width = utf8Width(start, static_cast<size_t>(end - start));
                if (width == 0) { return fail("JSON strings must contain valid UTF-8"); }
                decoded.append(start, width);
                cursor = start + width;
                continue;
            }
            if (cursor == end) { return fail("incomplete JSON escape"); }
            switch (*cursor++) {
            case '"': decoded += '"'; break;
            case '\\': decoded += '\\'; break;
            case '/': decoded += '/'; break;
            case 'b': decoded += '\b'; break;
            case 'f': decoded += '\f'; break;
            case 'n': decoded += '\n'; break;
            case 'r': decoded += '\r'; break;
            case 't': decoded += '\t'; break;
            case 'u': {
                uint32_t scalar = 0;
                if (!hex(scalar)) { return false; }
                if (scalar >= 0xD800 && scalar <= 0xDBFF) {
                    if (end - cursor < 2 || cursor[0] != '\\' || cursor[1] != 'u') { return fail("missing low surrogate"); }
                    cursor += 2;
                    uint32_t low = 0;
                    if (!hex(low)) { return false; }
                    if (low < 0xDC00 || low > 0xDFFF) { return fail("invalid low surrogate"); }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00;
                } else if (scalar >= 0xDC00 && scalar <= 0xDFFF) { return fail("unexpected low surrogate"); }
                if (scalar < 0x80) { decoded += static_cast<char>(scalar); }
                else if (scalar < 0x800) {
                    decoded += static_cast<char>(0xC0 | (scalar >> 6));
                    decoded += static_cast<char>(0x80 | (scalar & 63));
                } else if (scalar < 0x10000) {
                    decoded += static_cast<char>(0xE0 | (scalar >> 12));
                    decoded += static_cast<char>(0x80 | ((scalar >> 6) & 63));
                    decoded += static_cast<char>(0x80 | (scalar & 63));
                } else {
                    decoded += static_cast<char>(0xF0 | (scalar >> 18));
                    decoded += static_cast<char>(0x80 | ((scalar >> 12) & 63));
                    decoded += static_cast<char>(0x80 | ((scalar >> 6) & 63));
                    decoded += static_cast<char>(0x80 | (scalar & 63));
                }
                break;
            }
            default: return fail("invalid JSON escape");
            }
        }
        return fail("unterminated JSON string");
    }

    bool number() {
        const char *start = cursor;
        if (cursor != end && *cursor == '-') { cursor++; }
        if (cursor == end) { return fail("invalid JSON number"); }
        if (*cursor == '0') { cursor++; }
        else if (*cursor >= '1' && *cursor <= '9') {
            do { cursor++; budget.check(); } while (cursor != end && *cursor >= '0' && *cursor <= '9');
        } else { return fail("invalid JSON number"); }
        if (cursor != end && *cursor == '.') {
            cursor++;
            const char *digits = cursor;
            while (cursor != end && *cursor >= '0' && *cursor <= '9') { cursor++; budget.check(); }
            if (cursor == digits) { return fail("invalid JSON number fraction"); }
        }
        if (cursor != end && (*cursor == 'e' || *cursor == 'E')) {
            cursor++;
            if (cursor != end && (*cursor == '+' || *cursor == '-')) { cursor++; }
            const char *digits = cursor;
            while (cursor != end && *cursor >= '0' && *cursor <= '9') { cursor++; budget.check(); }
            if (cursor == digits) { return fail("invalid JSON number exponent"); }
        }
        double result = 0;
        auto parsed = std::from_chars(start, cursor, result);
        if (parsed.ec != std::errc() || parsed.ptr != cursor || !std::isfinite(result)) {
            return fail("JSON number is outside the finite number range");
        }
        lua_pushnumber(L, result);
        return true;
    }

    bool value(int depth) {
        if (depth > valueDepth) { return fail("JSON exceeds depth 64"); }
        if (!lua_checkstack(L, 4)) { return fail("JSON exceeds stack capacity"); }
        whitespace();
        if (cursor == end) { return fail("expected JSON value"); }
        budget.check();
        char first = *cursor;
        if (first == '"') { return string(); }
        if (first == '-' || (first >= '0' && first <= '9')) { return number(); }
        for (const auto &literal : {std::pair<const char *, int>{"null", 0}, {"true", 1}, {"false", 2}}) {
            size_t length = std::strlen(literal.first);
            if (static_cast<size_t>(end - cursor) >= length && std::memcmp(cursor, literal.first, length) == 0) {
                cursor += length;
                if (literal.second == 0) { omni_detail::pushJSONNull(L); }
                else { lua_pushboolean(L, literal.second == 1); }
                return true;
            }
        }
        bool array = first == '[';
        if (!array && first != '{') { return fail("invalid JSON value"); }
        cursor++;
        lua_newtable(L);
        int table = lua_gettop(L);
        if (array) { omni_detail::markJSONArray(L, table); }
        whitespace();
        char close = array ? ']' : '}';
        if (cursor != end && *cursor == close) { cursor++; if (readonly) { lua_setreadonly(L, table, true); } return true; }
        int index = 0;
        for (;;) {
            if (!array) {
                if (!string()) { return false; }
                whitespace();
                if (cursor == end || *cursor++ != ':') { return fail("expected JSON object colon"); }
            }
            if (!value(depth + 1)) { return false; }
            if (array) { lua_rawseti(L, table, ++index); }
            else { lua_rawset(L, table); }
            whitespace();
            if (cursor == end) { return fail("unterminated JSON container"); }
            if (*cursor == close) { cursor++; if (readonly) { lua_setreadonly(L, table, true); } return true; }
            if (*cursor++ != ',') { return fail("expected JSON comma"); }
            whitespace();
        }
    }
};

int encodeJSON(lua_State *L) {
    lua_settop(L, 1);
    std::vector<uint8_t> output;
    std::string error;
    Encoder encoder{L, output, jsonLimit, error, false, {L}};
    if (!encoder.value(1, 0)) {
        lua_settop(L, 0);
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }
    lua_settop(L, 0);
    lua_pushlstring(L, reinterpret_cast<const char *>(output.data()), output.size());
    return 1;
}

int decodeJSON(lua_State *L) {
    if (lua_type(L, 1) != LUA_TSTRING) {
        lua_pushnil(L);
        lua_pushliteral(L, "json.decode requires a string");
        return 2;
    }
    size_t length = 0;
    const char *bytes = lua_tolstring(L, 1, &length);
    if (length > jsonLimit) {
        lua_pushnil(L);
        lua_pushliteral(L, "JSON input exceeds 4 MiB");
        return 2;
    }
    lua_settop(L, 1);
    omni_detail::captureCount(L, &omni_capture_stats::json_decodes);
    Parser parser{L, bytes, bytes + length, {}, {L}};
    bool parsed = parser.value(0);
    parser.whitespace();
    if (!parsed || parser.cursor != parser.end) {
        lua_settop(L, 0);
        lua_pushnil(L);
        const std::string message = parsed ? "unexpected data after JSON value" : parser.error;
        lua_pushlstring(L, message.data(), message.size());
        return 2;
    }
    omni_detail::captureCount(L, &omni_capture_stats::json_decode_successes);
    return 1;
}

}

namespace omni_detail {

bool encodeValue(lua_State *L, int index, std::vector<uint8_t> &output, size_t byteLimit, std::string &error) {
    int top = lua_gettop(L);
    output.clear();
    error.clear();
    Encoder encoder{L, output, byteLimit, error, true, {L}};
    bool result = encoder.value(index, 0);
    lua_settop(L, top);
    if (!result) { output.clear(); }
    return result;
}

bool encodeJSONValue(lua_State *L, int index, std::vector<uint8_t> &output, size_t byteLimit, std::string &error) {
    int top = lua_gettop(L);
    output.clear();
    error.clear();
    Encoder encoder{L, output, byteLimit, error, false, {L}};
    bool result = encoder.value(index, 0);
    lua_settop(L, top);
    if (!result) { output.clear(); }
    return result;
}

bool decodeJSONValue(lua_State *L, const char *bytes, size_t length, bool readonly, std::string &error) {
    int top = lua_gettop(L);
    if (bytes == nullptr || length > jsonLimit) { error = "invalid JSON input size"; return false; }
    Parser parser{L, bytes, bytes + length, {}, {L}, readonly};
    bool parsed = parser.value(0);
    parser.whitespace();
    if (!parsed || parser.cursor != parser.end) {
        lua_settop(L, top);
        error = parsed ? "unexpected data after JSON value" : parser.error;
        return false;
    }
    return true;
}

void installJSON(lua_State *L) {
    lua_createtable(L, 0, 3);
    lua_pushcfunction(L, encodeJSON, "json.encode");
    lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, decodeJSON, "json.decode");
    lua_setfield(L, -2, "decode");
    pushJSONNull(L);
    lua_setfield(L, -2, "null");
    lua_setreadonly(L, -1, true);
    lua_setglobal(L, "json");
}

}
