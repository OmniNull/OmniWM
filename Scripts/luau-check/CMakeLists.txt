cmake_minimum_required(VERSION 3.15)
project(luau-check LANGUAGES CXX)

set(LUAU_SOURCE_DIR "" CACHE PATH "Luau source tree at the revision in Sources/OmniWMLuau/VERSION")
if(NOT IS_DIRECTORY "${LUAU_SOURCE_DIR}")
    message(FATAL_ERROR "LUAU_SOURCE_DIR must name the pinned Luau source tree")
endif()

set(LUAU_BUILD_CLI OFF CACHE BOOL "" FORCE)
set(LUAU_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${LUAU_SOURCE_DIR}" luau EXCLUDE_FROM_ALL)

add_executable(luau-check main.cpp)
target_compile_features(luau-check PRIVATE cxx_std_17)
target_link_libraries(luau-check PRIVATE Luau.Analysis)
install(TARGETS luau-check RUNTIME DESTINATION bin)
