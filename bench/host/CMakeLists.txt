# Builds `luau-bench`, a Luau 0.700 host with exact allocation counting and
# native codegen (copied from Ripple's bench). Luau sources live in ../third_party/luau-0.700-src
# (not committed: `fetch_luau.sh` links Ripple's copy or downloads the `luau0-src` crate 0.16.0+luau700, which packages the
# Ast/Compiler/VM/CodeGen sources of the 0.700 release).
cmake_minimum_required(VERSION 3.16)
project(luau_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

if(NOT LUAU_ROOT)
  set(LUAU_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/luau-0.700-src/luau)
endif()

file(GLOB LUAU_COMMON_SRC ${LUAU_ROOT}/Common/src/*.cpp)
file(GLOB LUAU_AST_SRC ${LUAU_ROOT}/Ast/src/*.cpp)
file(GLOB LUAU_COMPILER_SRC ${LUAU_ROOT}/Compiler/src/*.cpp)
file(GLOB LUAU_VM_SRC ${LUAU_ROOT}/VM/src/*.cpp)
file(GLOB LUAU_CODEGEN_SRC ${LUAU_ROOT}/CodeGen/src/*.cpp)

add_executable(luau-bench
  main.cpp
  ${LUAU_COMMON_SRC} ${LUAU_AST_SRC} ${LUAU_COMPILER_SRC} ${LUAU_VM_SRC} ${LUAU_CODEGEN_SRC})

target_include_directories(luau-bench PRIVATE
  ${LUAU_ROOT}/Common/include
  ${LUAU_ROOT}/Ast/include
  ${LUAU_ROOT}/Compiler/include
  ${LUAU_ROOT}/VM/include
  ${LUAU_ROOT}/VM/src
  ${LUAU_ROOT}/CodeGen/include)

# Same as upstream: C API entry points use C linkage.
target_compile_definitions(luau-bench PRIVATE
  LUA_API=extern\ \"C\"
  LUACODE_API=extern\ \"C\"
  LUACODEGEN_API=extern\ \"C\"
  LUAU_BENCH_NO_STACK_SHRINK=1)

target_compile_options(luau-bench PRIVATE -O2 -fno-math-errno)
