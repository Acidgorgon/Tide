// luau-bench: a minimal Luau 0.700 host for the Tide benchmark harness
// (copied from Ripple's bench host; adds __setvectormt for Roblox-style Vector3 members).
//
// Why a custom host instead of the stock `luau` CLI?
//   * We need EXACT allocation accounting. Luau's VM routes every allocation
//     through luaM_new_/luaM_newgco_/luaM_realloc_, which invoke the
//     `lua_callbacks(L)->onallocate(L, osize, nsize)` hook. The frealloc
//     callback passed to lua_newstate is NOT suitable for this: small objects
//     are carved out of 16 KB size-class pages, so frealloc only sees page
//     allocations. The onallocate hook sees every object/array allocation.
//   * We want `loadstring` to compile at the same optimization level as the
//     main script, keep the global environment "safe" (so GETIMPORT and
//     FASTCALL builtins stay enabled), and to run native codegen on every
//     loaded chunk when --codegen is given. (The stock CLI's loadstring marks
//     the environment unsafe, which would deoptimize everything loaded after.)
//   * We compile with Roblox's vector settings (vectorLib = "Vector3",
//     vectorCtor = "new", vectorType = "Vector3") so `Vector3.new(x, y, z)`
//     in generated Blink code compiles to the native vector builtin, as it
//     does in Roblox.
//
// Usage: luau-bench [-O0|-O1|-O2] [--codegen] script.luau [args...]
//
// Globals added on top of the standard Luau libraries:
//   loadstring(src, chunkname?) -> function | (nil, err)
//   readfile(path) -> string | nil
//   writefile(path, contents) -> boolean
//   listdir(path) -> { {name, dir}, ... } sorted, or nil
//   __alloc_bytes() -> total bytes allocated by the VM since start
//   __alloc_count() -> number of allocations since start
//   __live_bytes()  -> bytes currently held by the VM heap (lua_gc COUNT),
//                      includes garbage not yet collected
//   __trace_alloc(on) -> print every allocation (old size -> new size) to stderr
//   __gc(op, kb?)   -> "collect" (full GC), "stop", "restart", "step" (kb: amount of work)
//   __native()      -> true if native codegen is active
//   __native_code_bytes() -> total native code bytes produced so far
//   __optlevel()    -> optimization level in use
//   __setvectormt(t) -> install t as the metatable of the vector type (Roblox gives
//                      Vector3 members such as .Magnitude/.Unit/:Lerp this way;
//                      .X/.Y/.Z stay native fast paths)
//   arg             -> table of script arguments (arg[1] .. arg[n])

#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include "Luau/CodeGen.h"
#include "Luau/Common.h"
#include "Luau/ExperimentalFlags.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <algorithm>
#include <dirent.h>
#include <sys/stat.h>

static int gOptLevel = 2;
static bool gCodegen = false;

static uint64_t gAllocBytes = 0;
static uint64_t gAllocCount = 0;
static uint64_t gNativeCodeBytes = 0;

// Called by the VM for every allocation / reallocation (and realloc-to-zero).
// A growing realloc is counted as a fresh allocation of nsize bytes because
// Luau's size-class allocator really does allocate a new block and copy.
static bool gTraceAlloc = false; // __trace_alloc(true): print every allocation to stderr

static void onAllocate(lua_State* L, size_t osize, size_t nsize)
{
    if (nsize > 0)
    {
        gAllocBytes += nsize;
        gAllocCount += 1;
        if (gTraceAlloc)
            fprintf(stderr, "alloc %zu -> %zu\n", osize, nsize);
    }
}

static int l_trace_alloc(lua_State* L)
{
    gTraceAlloc = lua_toboolean(L, 1);
    return 0;
}

static void* hostAlloc(void* ud, void* ptr, size_t osize, size_t nsize)
{
    (void)ud;
    (void)osize;
    if (nsize == 0)
    {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, nsize);
}

static const char* const kVectorLib = "Vector3";

static lua_CompileOptions compileOptions()
{
    lua_CompileOptions o = {};
    o.optimizationLevel = gOptLevel;
    o.debugLevel = 1;
    o.typeInfoLevel = 1; // type info helps native codegen specialize
    o.coverageLevel = 0;
    o.vectorLib = kVectorLib;
    o.vectorCtor = "new";
    o.vectorType = "Vector3";
    return o;
}

// Compile `src`, load it as a function on top of the stack. Returns true on success;
// on failure pushes the error message.
static bool compileAndLoad(lua_State* L, const char* src, size_t len, const char* chunkname)
{
    lua_CompileOptions opts = compileOptions();
    size_t bcSize = 0;
    char* bc = luau_compile(src, len, &opts, &bcSize);
    int status = luau_load(L, chunkname, bc, bcSize, 0);
    free(bc);
    if (status != 0)
        return false;

    if (gCodegen)
    {
        Luau::CodeGen::CompilationOptions copts;
        Luau::CodeGen::CompilationStats stats;
        Luau::CodeGen::compile(L, -1, copts, &stats);
        gNativeCodeBytes += stats.nativeCodeSizeBytes;
    }
    return true;
}

static int l_loadstring(lua_State* L)
{
    size_t len = 0;
    const char* src = luaL_checklstring(L, 1, &len);
    const char* chunkname = luaL_optstring(L, 2, "=loadstring");
    if (compileAndLoad(L, src, len, chunkname))
        return 1;
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
}

static bool readFile(const char* path, std::string& out)
{
    FILE* f = fopen(path, "rb");
    if (!f)
        return false;
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        out.append(buf, n);
    fclose(f);
    return true;
}

static int l_readfile(lua_State* L)
{
    std::string s;
    if (!readFile(luaL_checkstring(L, 1), s))
    {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

static int l_writefile(lua_State* L)
{
    size_t len = 0;
    const char* path = luaL_checkstring(L, 1);
    const char* data = luaL_checklstring(L, 2, &len);
    FILE* f = fopen(path, "wb");
    if (!f)
    {
        lua_pushboolean(L, false);
        return 1;
    }
    fwrite(data, 1, len, f);
    fclose(f);
    lua_pushboolean(L, true);
    return 1;
}

// listdir(path) -> { {name = string, dir = boolean}, ... } | nil (sorted by name)
static int l_listdir(lua_State* L)
{
    const char* path = luaL_checkstring(L, 1);
    DIR* d = opendir(path);
    if (!d)
    {
        lua_pushnil(L);
        return 1;
    }
    std::vector<std::pair<std::string, bool>> entries;
    while (struct dirent* e = readdir(d))
    {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        std::string full = std::string(path) + "/" + e->d_name;
        struct stat st;
        bool isDir = stat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
        entries.emplace_back(e->d_name, isDir);
    }
    closedir(d);
    std::sort(entries.begin(), entries.end());
    lua_createtable(L, int(entries.size()), 0);
    for (size_t i = 0; i < entries.size(); i++)
    {
        lua_createtable(L, 0, 2);
        lua_pushstring(L, entries[i].first.c_str());
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, entries[i].second);
        lua_setfield(L, -2, "dir");
        lua_rawseti(L, -2, int(i + 1));
    }
    return 1;
}

static int l_alloc_bytes(lua_State* L)
{
    lua_pushnumber(L, double(gAllocBytes));
    return 1;
}

static int l_alloc_count(lua_State* L)
{
    lua_pushnumber(L, double(gAllocCount));
    return 1;
}

static int l_live_bytes(lua_State* L)
{
    double kb = lua_gc(L, LUA_GCCOUNT, 0);
    double b = lua_gc(L, LUA_GCCOUNTB, 0);
    lua_pushnumber(L, kb * 1024.0 + b);
    return 1;
}

static int l_gc(lua_State* L)
{
    const char* op = luaL_checkstring(L, 1);
    if (strcmp(op, "collect") == 0)
        lua_gc(L, LUA_GCCOLLECT, 0);
    else if (strcmp(op, "stop") == 0)
        lua_gc(L, LUA_GCSTOP, 0);
    else if (strcmp(op, "restart") == 0)
        lua_gc(L, LUA_GCRESTART, 0);
    else if (strcmp(op, "step") == 0)
        lua_gc(L, LUA_GCSTEP, (int)luaL_optinteger(L, 2, 0)); // optional: KB of work
    else
        luaL_error(L, "unknown gc op '%s'", op);
    return 0;
}

static int l_native(lua_State* L)
{
    lua_pushboolean(L, gCodegen);
    return 1;
}

static int l_native_code_bytes(lua_State* L)
{
    lua_pushnumber(L, double(gNativeCodeBytes));
    return 1;
}

static int l_setvectormt(lua_State* L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushvector(L, 0.0f, 0.0f, 0.0f);
    lua_pushvalue(L, 1);
    lua_setmetatable(L, -2);
    lua_pop(L, 1);
    return 0;
}

static int l_optlevel(lua_State* L)
{
    lua_pushinteger(L, gOptLevel);
    return 1;
}

// Mirror the stock CLI: enable all non-experimental "Luau*" fast flags.
static void setLuauFlagsDefault()
{
    for (Luau::FValue<bool>* flag = Luau::FValue<bool>::list; flag; flag = flag->next)
        if (strncmp(flag->name, "Luau", 4) == 0 && !Luau::isAnalysisFlagExperimental(flag->name))
            flag->value = true;
}

int main(int argc, char** argv)
{
    int argi = 1;
    for (; argi < argc; argi++)
    {
        const char* a = argv[argi];
        if (strcmp(a, "-O0") == 0)
            gOptLevel = 0;
        else if (strcmp(a, "-O1") == 0)
            gOptLevel = 1;
        else if (strcmp(a, "-O2") == 0)
            gOptLevel = 2;
        else if (strcmp(a, "--codegen") == 0)
            gCodegen = true;
        else
            break;
    }
    if (argi >= argc)
    {
        fprintf(stderr, "usage: %s [-O0|-O1|-O2] [--codegen] script.luau [args...]\n", argv[0]);
        return 2;
    }
    const char* scriptPath = argv[argi];

    setLuauFlagsDefault();

    lua_State* L = lua_newstate(hostAlloc, NULL);
    lua_callbacks(L)->onallocate = onAllocate;

    if (gCodegen)
    {
        if (!Luau::CodeGen::isSupported())
        {
            fprintf(stderr, "native codegen not supported on this platform\n");
            return 2;
        }
        Luau::CodeGen::create(L);
    }

    luaL_openlibs(L);

    static const luaL_Reg funcs[] = {
        {"loadstring", l_loadstring},
        {"readfile", l_readfile},
        {"writefile", l_writefile},
        {"listdir", l_listdir},
        {"__alloc_bytes", l_alloc_bytes},
        {"__alloc_count", l_alloc_count},
        {"__live_bytes", l_live_bytes},
        {"__gc", l_gc},
        {"__trace_alloc", l_trace_alloc},
        {"__native", l_native},
        {"__native_code_bytes", l_native_code_bytes},
        {"__optlevel", l_optlevel},
        {"__setvectormt", l_setvectormt},
        {NULL, NULL},
    };
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    luaL_register(L, NULL, funcs);
    lua_pop(L, 1);

    lua_createtable(L, argc - argi - 1, 0);
    for (int i = argi + 1; i < argc; i++)
    {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - argi);
    }
    lua_setglobal(L, "arg");

    // Globals stay writable (the driver installs Roblox-like globals such as
    // Vector3), but we mark the environment as safe so that imports are resolved
    // at load time and builtin fastcalls are used, like in Roblox.
    lua_setsafeenv(L, LUA_GLOBALSINDEX, true);

    std::string src;
    if (!readFile(scriptPath, src))
    {
        fprintf(stderr, "cannot read %s\n", scriptPath);
        return 2;
    }

    std::string chunkname = std::string("@") + scriptPath;
    if (!compileAndLoad(L, src.data(), src.size(), chunkname.c_str()))
    {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }

    // Run the main chunk in a thread so errors carry a traceback.
    lua_State* T = lua_newthread(L);
    lua_pushvalue(L, -2);
    lua_remove(L, -3);
    lua_xmove(L, T, 1);

    int status = lua_resume(T, NULL, 0);
    int rc = 0;
    if (status == LUA_YIELD)
    {
        fprintf(stderr, "main script yielded unexpectedly\n");
        rc = 1;
    }
    else if (status != 0)
    {
        const char* msg = lua_tostring(T, -1);
        fprintf(stderr, "%s\nstacktrace:\n%s", msg ? msg : "(error object is not a string)", lua_debugtrace(T));
        rc = 1;
    }

    fflush(stdout);
    lua_close(L);
    return rc;
}
