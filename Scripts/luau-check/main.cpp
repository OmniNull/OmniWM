// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "Luau/BuiltinDefinitions.h"
#include "Luau/Common.h"
#include "Luau/ConfigResolver.h"
#include "Luau/Error.h"
#include "Luau/ExperimentalFlags.h"
#include "Luau/Frontend.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>

namespace {

constexpr int typeErrorsStatus = 1;
constexpr int unusableInputStatus = 2;

void enableReleasedAnalysisFlags() {
    for (Luau::FValue<bool> *flag = Luau::FValue<bool>::list; flag; flag = flag->next) {
        if (std::strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name)) {
            flag->value = true;
        }
    }
}

std::optional<std::string> readRegularFile(const std::string &path) {
    std::error_code status;
    if (!std::filesystem::is_regular_file(path, status)) {
        return std::nullopt;
    }
    std::unique_ptr<std::FILE, int (*)(std::FILE *)> file(std::fopen(path.c_str(), "rb"), std::fclose);
    if (!file) {
        return std::nullopt;
    }
    std::string contents;
    std::array<char, 65536> buffer;
    size_t count = 0;
    while ((count = std::fread(buffer.data(), 1, buffer.size(), file.get())) > 0) {
        contents.append(buffer.data(), count);
    }
    if (std::ferror(file.get())) {
        return std::nullopt;
    }
    return contents;
}

struct FileResolver : Luau::FileResolver {
    std::unordered_map<std::string, std::string> sources;

    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName &name) override {
        const auto source = sources.find(name);
        if (source == sources.end()) {
            return std::nullopt;
        }
        return Luau::SourceCode{source->second, Luau::SourceCode::Module};
    }

    std::string getHumanReadableModuleName(const Luau::ModuleName &name) const override {
        return name;
    }
};

std::string describe(const Luau::Frontend &frontend, const Luau::TypeError &error) {
    if (const auto *syntax = Luau::get_if<Luau::SyntaxError>(&error.data)) {
        return "SyntaxError: " + syntax->message;
    }
    return "TypeError: " + Luau::toString(error, Luau::TypeErrorToStringOptions{frontend.fileResolver});
}

void report(const std::string &name, const Luau::Location &location, const std::string &message) {
    std::printf("%s:%u:%u: %s\n", name.c_str(), location.begin.line + 1, location.begin.column + 1, message.c_str());
}

}

int main(int argc, char **argv) {
    enableReleasedAnalysisFlags();
    if (argc < 3) {
        std::fprintf(stderr, "usage: luau-check <definitions.d.luau> <file.luau>...\n");
        return unusableInputStatus;
    }
    const std::string definitionsPath = argv[1];
    const auto definitions = readRegularFile(definitionsPath);
    if (!definitions) {
        std::fprintf(stderr, "%s: not a readable file\n", definitionsPath.c_str());
        return unusableInputStatus;
    }
    FileResolver fileResolver;
    for (int index = 2; index < argc; ++index) {
        auto source = readRegularFile(argv[index]);
        if (!source) {
            std::fprintf(stderr, "%s: not a readable file\n", argv[index]);
            return unusableInputStatus;
        }
        fileResolver.sources.insert_or_assign(argv[index], std::move(*source));
    }

    Luau::NullConfigResolver configResolver;
    configResolver.defaultConfig.mode = Luau::Mode::Strict;
    Luau::Frontend frontend(Luau::SolverMode::New, &fileResolver, &configResolver);
    Luau::registerBuiltinGlobals(frontend, frontend.globals);
    const auto loaded = frontend.loadDefinitionFile(
        frontend.globals, frontend.globals.globalScope, *definitions, "@omniwm", false
    );
    if (!loaded.success) {
        for (const auto &error : loaded.parseResult.errors) {
            report(definitionsPath, error.getLocation(), "SyntaxError: " + error.getMessage());
        }
        if (loaded.module) {
            for (const auto &error : loaded.module->errors) {
                report(definitionsPath, error.location, describe(frontend, error));
            }
        }
        return unusableInputStatus;
    }
    Luau::freeze(frontend.globals.globalTypes);

    bool clean = true;
    for (int index = 2; index < argc; ++index) {
        const std::string name = argv[index];
        const Luau::CheckResult result = frontend.check(name);
        for (const auto &error : result.errors) {
            clean = false;
            report(name, error.location, describe(frontend, error));
        }
        const Luau::SourceModule *module = frontend.getSourceModule(name);
        if (!module || module->mode != Luau::Mode::Strict) {
            clean = false;
            report(name, Luau::Location{}, "ModeError: every checked file must be analyzed in strict mode");
        }
    }
    return clean ? 0 : typeErrorsStatus;
}
