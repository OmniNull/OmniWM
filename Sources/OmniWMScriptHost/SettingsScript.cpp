// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "ScriptModules.h"
#include "Luau/Parser.h"
#include "Luau/Ast.h"
#include <algorithm>
#include <charconv>
#include <unordered_set>

namespace {
using namespace Luau;
using namespace omni_detail;

struct SettingsVM : ModuleRuntime {
    using ModuleRuntime::ModuleRuntime;
    ~SettingsVM() { closeRuntime(*this); }
};

AstExpr *innerExpression(AstExpr *expr) {
    while (expr) {
        if (auto *group = expr->as<AstExprGroup>()) expr = group->expr;
        else if (auto *typed = expr->as<AstExprTypeAssertion>()) expr = typed->expr;
        else break;
    }
    return expr;
}

struct ReturnSites : AstVisitor {
    std::vector<AstStatReturn *> sites;
    bool visit(AstExprFunction *) override { return false; }
    bool visit(AstStatTypeFunction *) override { return false; }
    bool visit(AstStatReturn *node) override {
        sites.push_back(node);
        return false;
    }
};

struct LocalUses : AstVisitor {
    AstLocal *local;
    size_t count = 0;
    explicit LocalUses(AstLocal *local) : local(local) {}
    bool visit(AstExprLocal *node) override {
        if (node->local == local) ++count;
        return false;
    }
};

AstExpr *returnedExpression(AstStatBlock *root, const ReturnSites &returns) {
    auto *expr = innerExpression(returns.sites.front()->list.data[0]);
    auto *ref = expr->as<AstExprLocal>();
    if (ref) {
        bool same = std::all_of(returns.sites.begin(), returns.sites.end(), [&](AstStatReturn *site) {
            auto *value = innerExpression(site->list.data[0])->as<AstExprLocal>();
            return value && value->local == ref->local;
        });
        if (same) {
            LocalUses uses(ref->local);
            root->visit(&uses);
            if (uses.count == returns.sites.size()) {
                for (auto *stat : root->body) {
                    auto *decl = stat->as<AstStatLocal>();
                    if (decl && decl->vars.size == 1 && decl->vars.data[0] == ref->local && decl->values.size == 1) {
                        auto *init = innerExpression(decl->values.data[0]);
                        if (init->is<AstExprTable>()) return init;
                    }
                }
            }
        }
    }
    return returns.sites.size() == 1 ? expr : nullptr;
}

bool isRecord(AstExprTable *table) {
    if (!table) return false;
    std::unordered_set<std::string_view> keys;
    for (auto &item : table->items) {
        auto *key = item.key ? item.key->as<AstExprConstantString>() : nullptr;
        if (!key || !keys.emplace(key->value.data, key->value.size).second) return false;
    }
    return true;
}

bool listOrder(AstExprTable *table, std::vector<size_t> &positions) {
    if (!table) return false;
    if (std::none_of(table->items.begin(), table->items.end(),
            [](const AstExprTable::Item &item) { return item.key != nullptr; })) return true;
    size_t count = table->items.size;
    std::vector<bool> seen(count);
    positions.reserve(count);
    size_t implicit = 0;
    for (const auto &item : table->items) {
        size_t position;
        if (item.key) {
            auto *number = innerExpression(item.key)->as<AstExprConstantNumber>();
            if (!number || !(number->value >= 1 && number->value <= count)) return false;
            position = static_cast<size_t>(number->value);
            if (position != number->value) return false;
        } else {
            position = ++implicit;
        }
        if (seen[position - 1]) return false;
        seen[position - 1] = true;
        positions.push_back(position);
    }
    return true;
}

bool isScalarLiteral(AstExpr *expr) {
    auto *unary = expr->as<AstExprUnary>();
    return expr->is<AstExprConstantBool>() || expr->is<AstExprConstantString>()
        || expr->is<AstExprConstantNumber>() || expr->is<AstExprConstantNil>()
        || (unary && unary->op == AstExprUnary::Op::Minus && unary->expr->is<AstExprConstantNumber>());
}

struct SourceMapper {
    const CstNodeMap &syntax;
    const std::vector<size_t> &lines;
    void *context;
    omni_settings_field field;
    omni_settings_formula formula;
    omni_settings_constructor constructor;

    size_t offset(Position pos) const { return lines.at(pos.line) + pos.column; }

    void map(AstExpr *expr, uint32_t parent, omni_config_span key) const {
        auto *table = expr->as<AstExprTable>();
        bool record = isRecord(table);
        const Location loc = expr->location;
        bool literal = isScalarLiteral(expr);
        auto id = field(context, parent, key, offset(loc.begin), offset(loc.end), loc.begin.line + 1, literal, record);
        if (literal) return;
        std::vector<size_t> positions;
        if (!record && !listOrder(table, positions)) {
            formula(context, id, offset(loc.begin), offset(loc.end), loc.begin.line + 1);
            return;
        }
        auto *cst = (*syntax.find(table))->as<CstExprTable>();
        std::vector<omni_settings_item> items;
        items.reserve(table->items.size);
        for (size_t i = 0; i < table->items.size; ++i) {
            const auto &item = table->items.data[i];
            const auto &tokens = cst->items.data[i];
            auto value = item.value->location;
            auto begin = item.kind == AstExprTable::Item::Kind::General ? tokens.indexerOpenPosition :
                item.key ? item.key->location.begin : value.begin;
            size_t separator = tokens.separator == CstExprTable::Separator::Missing ? 0 : offset(tokens.separatorPosition);
            omni_config_span name{};
            if (record) {
                auto keyText = item.key->as<AstExprConstantString>()->value;
                name = {keyText.size ? keyText.data : "", keyText.size};
            }
            char index[3 * sizeof(size_t) + 1];
            size_t position = 0, indexBegin = 0, indexEnd = 0;
            if (!record) {
                position = positions.empty() ? i + 1 : positions[i];
                if (item.key) {
                    auto loc = innerExpression(item.key)->location;
                    indexBegin = offset(loc.begin);
                    indexEnd = offset(loc.end);
                }
            }
            items.push_back({name, offset(begin), offset(value.begin), offset(value.end), separator,
                position, indexBegin, indexEnd});
            if (position) {
                auto end = std::to_chars(std::begin(index), std::end(index), position - 1).ptr;
                name = {index, size_t(end - index)};
            }
            map(innerExpression(item.value), id, name);
        }
        constructor(context, id, offset(loc.begin), offset(loc.end), items.data(), items.size());
    }
};

void installLibraries(lua_State *L) {
    for (lua_CFunction open : {luaopen_base, luaopen_table, luaopen_string, luaopen_math, luaopen_bit32, luaopen_utf8}) {
        lua_pushcfunction(L, open, nullptr);
        lua_call(L, 0, 0);
    }
    for (auto name : {"print", "getfenv", "setfenv", "gcinfo", "collectgarbage"}) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    lua_getglobal(L, "math");
    for (auto name : {"random", "randomseed"}) {
        lua_pushnil(L);
        lua_setfield(L, -2, name);
    }
    lua_pop(L, 1);
}
}

omni_status omni_settings_evaluate(omni_config_span source, size_t heap_limit, uint64_t budget,
    void *context, omni_settings_field field, omni_settings_formula formula, omni_settings_constructor constructor,
    omni_settings_comment comment, omni_settings_return_site returnSite,
    omni_settings_table table, omni_read_module readModule, omni_config_location *site, char *error, size_t capacity) noexcept {
    using namespace omni_detail;
    using namespace Luau;
    if (source.length > OMNI_CONFIG_BYTE_LIMIT || !site || !field || !formula || !constructor || !comment || !returnSite || !table || !heap_limit || !budget) {
        copyMessage("invalid settings input or source exceeds 1 MiB", error, capacity);
        return OMNI_ERR_COMPILE;
    }
    try {
        const char *bytes = source.data ? source.data : "";
        const uint64_t start = threadCPU();
        Allocator arena;
        AstNameTable names(arena);
        ParseOptions parseOptions;
        parseOptions.captureComments = true;
        parseOptions.storeCstData = true;
        auto parsed = Parser::parse(bytes, source.length, names, arena, parseOptions);
        if (!parsed.errors.empty()) {
            auto &issue = parsed.errors.front();
            auto message = std::to_string(issue.getLocation().begin.line + 1) + ": " + issue.getMessage();
            copyMessage(message.c_str(), error, capacity);
            return OMNI_ERR_COMPILE;
        }
        std::vector<size_t> lines{0};
        for (size_t i = 0; i < source.length; ++i) if (bytes[i] == '\n') lines.push_back(i + 1);
        auto offset = [&](Position pos) { return lines.at(pos.line) + pos.column; };
        for (const auto &entry : parsed.commentLocations)
            comment(context, offset(entry.location.begin), offset(entry.location.end));
        ReturnSites returns;
        parsed.root->visit(&returns);
        if (!returns.sites.empty() && std::all_of(returns.sites.begin(), returns.sites.end(),
                [](AstStatReturn *site) { return site->list.size == 1; })) {
            if (auto *expr = returnedExpression(parsed.root, returns)) {
                SourceMapper{parsed.cstNodeMap, lines, context, field, formula, constructor}.map(expr, 0, {});
            } else {
                size_t insertion = offset(parsed.root->body.data[0]->location.begin);
                for (auto *site : returns.sites) {
                    auto loc = innerExpression(site->list.data[0])->location;
                    returnSite(context, offset(loc.begin), offset(loc.end), loc.begin.line + 1, insertion);
                }
            }
        } else {
            for (auto *site : returns.sites) {
                auto loc = site->location;
                formula(context, 0, offset(loc.begin), offset(loc.end), loc.begin.line + 1);
            }
        }
        SettingsVM vm(readModule, context);
        if (!openRuntime(vm, heap_limit, static_cast<ModuleRuntime *>(&vm), false)) throw std::bad_alloc();
        installLibraries(vm.main);
        if (readModule) {
            lua_pushcfunction(vm.main, requireConfigModule, "require");
            lua_setglobal(vm.main, "require");
        }
        vm.modules.push_back({"@settings.luau"});
        vm.chain.push_back(0);
        sandboxRuntime(vm);
        omni_status loaded = loadChunk(vm.thread, "@settings.luau", source, site->line, error, capacity);
        if (loaded != OMNI_OK) return loaded;
        std::vector<uint8_t> json;
        omni_status status;
        {
            const uint64_t used = threadCPU() - start;
            if (used >= budget) {
                copyMessage("settings exceeded the CPU budget", error, capacity);
                return OMNI_ERR_TIMEOUT;
            }
            CallScope scope(&vm, budget - used);
            auto *L = vm.thread;
            status = finishModuleCall(vm, L, lua_resume(L, nullptr, 0), error, capacity);
            *site = vm.location;
            if (status == OMNI_ERR_TIMEOUT) copyMessage("settings exceeded the CPU budget", error, capacity);
            if (status == OMNI_OK) {
                std::string reason;
                if (lua_gettop(L) != 1 || !lua_istable(L, 1)) reason = "return exactly one settings table";
                else encodeJSONValue(L, 1, json, OMNI_CONFIG_BYTE_LIMIT, reason);
                if (!reason.empty()) {
                    copyMessage(reason.c_str(), error, capacity);
                    status = OMNI_ERR_RUNTIME;
                }
            }
        }
        status = enforceBudget(&vm, status, error, capacity);
        if (status == OMNI_OK) table(context, json.data(), json.size());
        return status;
    } catch (...) {
        copyMessage("unable to evaluate settings within resource limits", error, capacity);
        return OMNI_ERR_MEMORY;
    }
}
