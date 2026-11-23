// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptHostInternal.h"
#include "ScriptUTF8.h"
#include "Luau/Parser.h"
#include "Luau/Ast.h"

#include <charconv>
#include <cmath>
#include <string_view>
#include <unordered_set>

namespace {
using namespace Luau;

AstExpr *ungroup(AstExpr *expr) {
    while (auto *group = expr->as<AstExprGroup>()) expr = group->expr;
    return expr;
}

struct LiteralJSON {
    std::string json;

    void string(const AstExprConstantString &node) {
        const std::string_view text(node.value.data, node.value.size);
        json += '"';
        for (size_t index = 0; index < text.size();) {
            unsigned char character = text[index];
            if (character < 0x20) {
                constexpr char hex[] = "0123456789abcdef";
                json += "\\u00";
                json += hex[character >> 4];
                json += hex[character & 15];
                ++index;
            } else if (character < 0x80) {
                if (character == '"' || character == '\\') json += '\\';
                json += static_cast<char>(character);
                ++index;
            } else {
                const size_t width = omni_detail::utf8Width(text.data() + index, text.size() - index);
                if (!width) throw ParseError(node.location, "metadata strings must contain valid UTF-8");
                json.append(text.data() + index, width);
                index += width;
            }
        }
        json += '"';
    }

    void table(AstExprTable &node, unsigned depth) {
        const bool array = node.items.size && !node.items.data[0].key;
        std::unordered_set<std::string_view> keys;
        json += array ? '[' : '{';
        bool first = true;
        for (const auto &item : node.items) {
            if (!first) json += ',';
            first = false;
            if (array != !item.key)
                throw ParseError(item.value->location, "metadata tables cannot mix array entries and named fields");
            if (item.key) {
                auto *key = ungroup(item.key)->as<AstExprConstantString>();
                if (!key) throw ParseError(item.key->location, "metadata field names must be literal strings");
                if (!keys.emplace(key->value.data, key->value.size).second)
                    throw ParseError(key->location, "duplicate metadata field");
                string(*key);
                json += ':';
            }
            value(item.value, depth + 1);
        }
        json += array ? ']' : '}';
    }

    void value(AstExpr *expr, unsigned depth) {
        if (depth > 64) throw ParseError(expr->location, "metadata nesting exceeds 64 levels");
        expr = ungroup(expr);
        if (auto *fields = expr->as<AstExprTable>()) return table(*fields, depth);
        if (auto *text = expr->as<AstExprConstantString>()) return string(*text);
        if (auto *boolean = expr->as<AstExprConstantBool>()) {
            json += boolean->value ? "true" : "false";
            return;
        }
        bool negative = false;
        if (auto *unary = expr->as<AstExprUnary>(); unary && unary->op == AstExprUnary::Op::Minus) {
            negative = true;
            expr = ungroup(unary->expr);
        }
        if (auto *integer = expr->as<AstExprConstantInteger>()) {
            if (negative && integer->value == INT64_MIN) throw ParseError(expr->location, "metadata integer overflows");
            json += std::to_string(negative ? -integer->value : integer->value);
            return;
        }
        if (auto *number = expr->as<AstExprConstantNumber>(); number && std::isfinite(number->value)) {
            char digits[64];
            auto result = std::to_chars(digits, digits + sizeof digits, negative ? -number->value : number->value);
            if (result.ec == std::errc()) {
                json.append(digits, result.ptr);
                return;
            }
        }
        throw ParseError(expr->location, "metadata values must be literal strings, finite numbers, booleans or tables");
    }

    void parse(omni_config_span source) {
        Allocator arena;
        AstNameTable names(arena);
        auto parsed = Parser::parse(source.data ? source.data : "", source.length, names, arena);
        if (!parsed.errors.empty()) throw parsed.errors.front();
        const auto &body = parsed.root->body;
        auto *statement = body.size ? body.data[0]->as<AstStatReturn>() : nullptr;
        auto *root = statement && statement->list.size == 1 ? ungroup(statement->list.data[0])->as<AstExprTable>() : nullptr;
        if (!root || body.size != 1)
            throw ParseError(body.size ? body.data[0]->location : parsed.root->location, "metadata must contain only return { ... }");
        table(*root, 0);
    }
};
}

omni_status omni_metadata_parse(omni_config_span source, void *context, omni_settings_table table,
    uint32_t *line, char *error, size_t capacity) noexcept {
    using omni_detail::copyMessage;
    if (!line || !table || (!source.data && source.length) || source.length > OMNI_CONFIG_BYTE_LIMIT) {
        copyMessage("invalid metadata input or source exceeds 1 MiB", error, capacity);
        return OMNI_ERR_COMPILE;
    }
    *line = 1;
    try {
        LiteralJSON result;
        result.parse(source);
        table(context, reinterpret_cast<const uint8_t *>(result.json.data()), result.json.size());
        return OMNI_OK;
    } catch (const Luau::ParseError &issue) {
        *line = issue.getLocation().begin.line + 1;
        copyMessage(issue.what(), error, capacity);
        return OMNI_ERR_COMPILE;
    } catch (const std::bad_alloc &) {
        copyMessage("metadata allocation failed", error, capacity);
        return OMNI_ERR_MEMORY;
    } catch (const std::exception &issue) {
        copyMessage(issue.what(), error, capacity);
        return OMNI_ERR_INTERNAL;
    }
}
