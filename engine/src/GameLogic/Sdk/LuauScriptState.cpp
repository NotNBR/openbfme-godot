// OpenBFME. GPL-3.0. See GameLogic/Sdk/LuauScriptState.h (lane SDK-2).

#include "GameLogic/Sdk/LuauScriptState.h"

#include "Common/ArchiveFileSystem.h"
#include "Common/DeterministicLibm.h"
#include "GameLogic/Sdk/LuauSimMath.h"

#include "luau/lua.h"
#include "luau/lua_openbfme.h"
#include "luau/luacode.h"
#include "luau/lualib.h"

#include <cstdlib>
#include <cstring>
#include <memory>

namespace
{

const char *const kSimDisabledBuiltins[] = { "vector.angle", "math.sin", "math.cos", "math.tan", "math.asin", "math.acos", "math.atan", "math.atan2",
	"math.exp", "math.log", "math.log10", "math.pow", "math.sinh", "math.cosh", "math.tanh",
	"setmetatable", nullptr }; // setmetatable: its fast path would skip the weak-table check of lua_setmetatable (Libraries/Luau/README.md)

LuauScriptState *self(lua_State *L)
{
	return static_cast<LuauScriptState *>(lua_callbacks(L)->userdata);
}

// a module of the state's role: openbfme/sdk/<role>/<name>.luau (GameLogic/Sdk/SdkManifest.h)
std::string chunkPath(SdkScriptRole role, const std::string &name)
{
	return std::string(role == SdkScriptRole::Sim ? "openbfme/sdk/sim/" : "openbfme/sdk/presentation/") + name + ".luau";
}

// ---- sim role math: the deterministic libm (DetLibm), never the platform's ----------------------------------------------------------

template <double (*F)(double)>
int detUnary(lua_State *L)
{
	lua_pushnumber(L, F(luaL_checknumber(L, 1)));
	return 1;
}

int detAtan2(lua_State *L)
{
	lua_pushnumber(L, DetLibm::atan2(luaL_checknumber(L, 1), luaL_checknumber(L, 2)));
	return 1;
}

int detPow(lua_State *L)
{
	lua_pushnumber(L, DetLibm::pow(luaL_checknumber(L, 1), luaL_checknumber(L, 2)));
	return 1;
}

int detLog(lua_State *L)
{
	const double x = luaL_checknumber(L, 1);
	lua_pushnumber(L, lua_isnoneornil(L, 2) ? DetLibm::log(x) : SdkSimMath::logBase(x, luaL_checknumber(L, 2)));
	return 1;
}

int detAtan(lua_State *L)
{
	lua_pushnumber(L, DetLibm::atan(luaL_checknumber(L, 1)));
	return 1;
}

// math.random with the game's synchronized generator: () -> [0, 1); (m) -> [1, m]; (m, n) -> [m, n]
int simRandom(lua_State *L)
{
	LuauScriptState *s = self(L);
	const int n = lua_gettop(L);
	if (n > 2)
		luaL_error(L, "wrong number of arguments");
	const std::uint32_t r = s->randomBits();
	if (n == 0)
	{
		lua_pushnumber(L, SdkSimMath::unitFromBits(r));
		return 1;
	}
	const int lo = n == 2 ? luaL_checkinteger(L, 1) : 1;
	const int hi = n == 2 ? luaL_checkinteger(L, 2) : luaL_checkinteger(L, 1);
	luaL_argcheck(L, lo <= hi, n, "interval is empty");
	lua_pushnumber(L, SdkSimMath::rangeFromBits(r, lo, hi));
	return 1;
}

// vector.angle (lveclib.cpp's vector_angle) on DetLibm::atan2 (Sol r1: the platform atan2 differed between CPU dispatches)
int simVectorAngle(lua_State *L)
{
	const float *a = luaL_checkvector(L, 1);
	const float *b = luaL_checkvector(L, 2);
	const float *axis = luaL_optvector(L, 3, nullptr);
	lua_pushnumber(L, SdkSimMath::vectorAngle(a, b, axis));
	return 1;
}

int simRandomSeed(lua_State *L)
{
	luaL_error(L, "math.randomseed is not available to a sim script: math.random is the game's shared generator");
	return 0;
}

// ---- both roles ---------------------------------------------------------------------------------------------------------------------

int scriptPrint(lua_State *L)
{
	std::string line;
	// Sol r2: every line costs its newline and a fixed overhead (the string object kept for it), also an empty print()
	if (!self(L)->reservePrint(LuauScriptState::kPrintLineCost))
		luaL_error(L, "print: the script printed more than its output budget (%d bytes a call, %d in all)", (int)LuauScriptState::kPrintPerCall,
			(int)LuauScriptState::kPrintTotal);
	for (int i = 1; i <= lua_gettop(L); ++i)
	{
		size_t len = 0;
		const char *s = luaL_tolstring(L, i, &len);
		if (!self(L)->reservePrint(len + 1))
			luaL_error(L, "print: the script printed more than its output budget (%d bytes a call, %d in all)", (int)LuauScriptState::kPrintPerCall,
				(int)LuauScriptState::kPrintTotal);
		if (i > 1)
			line += '\t';
		line.append(s, len);
		lua_pop(L, 1);
	}
	self(L)->notePrinted(line);
	return 0;
}

// sdk.read(path): a file of the mod's own folder, as a string
int sdkRead(lua_State *L)
{
	const std::string path = luaL_checkstring(L, 1);
	if (!LuauScriptState::safePath(path))
		luaL_error(L, "sdk.read: '%s' is not a path inside the mod (relative, '/'-separated, no '..')", path.c_str());
	std::string out, error;
	if (!self(L)->readModFile(path, out, error))
		luaL_error(L, "sdk.read: %s", error.c_str());
	lua_pushlstring(L, out.data(), out.size());
	return 1;
}

// require(name): openbfme/sdk/<role>/<name>.luau of the mod (only the state's own role), run once; its result is cached
int scriptRequire(lua_State *L)
{
	const std::string name = luaL_checkstring(L, 1);
	if (!LuauScriptState::safePath(name))
		luaL_error(L, "require: '%s' is not a module of the mod (relative, '/'-separated, no '..')", name.c_str());
	lua_getfield(L, LUA_REGISTRYINDEX, "openbfme.modules");
	lua_getfield(L, -1, name.c_str());
	if (!lua_isnil(L, -1))
		return 1;
	lua_pop(L, 1);
	std::string source, error;
	if (!self(L)->readModFile(chunkPath(self(L)->role(), name), source, error))
		luaL_error(L, "require '%s': %s", name.c_str(), error.c_str());
	if (!self(L)->enterModule(name, error))
		luaL_error(L, "%s", error.c_str());
	size_t size = 0;
	lua_CompileOptions options = {};
	options.optimizationLevel = 1;
	options.debugLevel = 1;
	if (self(L)->role() == SdkScriptRole::Sim)
		options.disabledBuiltins = LuauScriptState::simDisabledBuiltins();
	std::unique_ptr<char, void (*)(void *)> bytecode(luau_compile(source.data(), source.size(), &options, &size), std::free);
	const std::string chunk = "@" + chunkPath(self(L)->role(), name);
	if (luau_load(L, chunk.c_str(), bytecode.get(), size, 0) != 0)
	{
		self(L)->leaveModule();
		lua_error(L);
	}
	lua_call(L, 0, 1);
	self(L)->leaveModule();
	if (lua_isnil(L, -1))
	{
		lua_pop(L, 1);
		lua_pushboolean(L, 1);
	}
	lua_pushvalue(L, -1);
	lua_setfield(L, -3, name.c_str());
	return 1;
}

// luau_load under lua_pcall: loading may raise (a lockstep state checks the keys of a chunk's table templates as they are built)
struct LoadRequest
{
	const char *chunk;
	const char *bytecode;
	size_t size;
};

int protectedLoad(lua_State *L)
{
	const LoadRequest *r = static_cast<const LoadRequest *>(lua_tolightuserdata(L, 1));
	lua_settop(L, 0);
	if (luau_load(L, r->chunk, r->bytecode, r->size, 0) != 0)
		lua_error(L);
	return 1;
}

void *scriptAlloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	LuauScriptState *s = static_cast<LuauScriptState *>(ud);
	return s->allocate(ptr, osize, nsize);
}

void scriptInterrupt(lua_State *L, int gc)
{
	if (gc >= 0)
		return; // a collector step: not script work
	self(L)->step(L);
}

} // namespace

const char *const *LuauScriptState::simDisabledBuiltins()
{
	return kSimDisabledBuiltins;
}

bool LuauScriptState::safePath(const std::string &path)
{
	if (path.empty() || path.front() == '/' || path.find('\\') != std::string::npos || path.find(':') != std::string::npos ||
		path.find('\0') != std::string::npos)
		return false;
	size_t start = 0;
	while (start <= path.size())
	{
		const size_t end = path.find('/', start);
		const std::string part = path.substr(start, end == std::string::npos ? std::string::npos : end - start);
		if (part.empty() || part == "." || part == "..")
			return false;
		if (end == std::string::npos)
			break;
		start = end + 1;
	}
	return true;
}

LuauScriptState::LuauScriptState(SdkScriptRole role, std::string modName, SdkScriptLimits limits, Reader reader, Random random, Setup setup)
	: m_role(role), m_modName(std::move(modName)), m_limits(limits), m_reader(std::move(reader)), m_random(std::move(random))
{
	m_L = lua_newstate(scriptAlloc, this);
	if (!m_L)
	{
		fail("cannot create the script state (memory cap " + std::to_string(m_limits.memoryBytes) + " bytes)");
		return;
	}
	lua_callbacks(m_L)->userdata = this;
	lua_callbacks(m_L)->interrupt = scriptInterrupt;

	// the libraries a script gets: no os, debug, integer or class libraries
	const luaL_Reg libs[] = { { "", luaopen_base }, { LUA_COLIBNAME, luaopen_coroutine }, { LUA_TABLIBNAME, luaopen_table },
		{ LUA_STRLIBNAME, luaopen_string }, { LUA_MATHLIBNAME, luaopen_math }, { LUA_UTF8LIBNAME, luaopen_utf8 },
		{ LUA_BITLIBNAME, luaopen_bit32 }, { LUA_BUFFERLIBNAME, luaopen_buffer }, { LUA_VECLIBNAME, luaopen_vector }, { nullptr, nullptr } };
	for (const luaL_Reg *lib = libs; lib->func; ++lib)
	{
		lua_pushcfunction(m_L, lib->func, nullptr);
		lua_pushstring(m_L, lib->name);
		lua_call(m_L, 1, 0);
	}
	for (const char *name : { "getfenv", "setfenv", "newproxy", "gcinfo", "collectgarbage", "loadstring", "load", "dofile", "loadfile" })
	{
		lua_pushnil(m_L);
		lua_setglobal(m_L, name);
	}
	lua_pushcfunction(m_L, scriptPrint, "print");
	lua_setglobal(m_L, "print");
	lua_pushcfunction(m_L, scriptRequire, "require");
	lua_setglobal(m_L, "require");

	lua_newtable(m_L); // sdk
	lua_pushcfunction(m_L, sdkRead, "sdk.read");
	lua_setfield(m_L, -2, "read");
	lua_pushstring(m_L, m_role == SdkScriptRole::Sim ? "sim" : "presentation");
	lua_setfield(m_L, -2, "role");
	// Sol r4: a sim script is not told the manifest's name (the name is not part of the sim fingerprint the peers share); a presentation
	// script is
	if (m_role == SdkScriptRole::Presentation)
	{
		lua_pushstring(m_L, m_modName.c_str());
		lua_setfield(m_L, -2, "mod");
	}
	lua_setglobal(m_L, "sdk");

	if (m_role == SdkScriptRole::Sim)
	{
		lua_getglobal(m_L, LUA_MATHLIBNAME);
		const luaL_Reg simMath[] = { { "sin", detUnary<DetLibm::sin> }, { "cos", detUnary<DetLibm::cos> }, { "tan", detUnary<DetLibm::tan> },
			{ "asin", detUnary<DetLibm::asin> }, { "acos", detUnary<DetLibm::acos> }, { "atan", detAtan }, { "atan2", detAtan2 },
			{ "exp", detUnary<DetLibm::exp> }, { "log", detLog }, { "log10", detUnary<DetLibm::log10> }, { "pow", detPow },
			{ "sinh", detUnary<SdkSimMath::sinh> }, { "cosh", detUnary<SdkSimMath::cosh> }, { "tanh", detUnary<SdkSimMath::tanh> }, { "random", simRandom },
			{ "randomseed", simRandomSeed }, { nullptr, nullptr } };
		for (const luaL_Reg *f = simMath; f->func; ++f)
		{
			lua_pushcfunction(m_L, f->func, f->name);
			lua_setfield(m_L, -2, f->name);
		}
		lua_pop(m_L, 1);
		lua_getglobal(m_L, LUA_VECLIBNAME);
		lua_pushcfunction(m_L, simVectorAngle, "angle");
		lua_setfield(m_L, -2, "angle");
		lua_pop(m_L, 1);
	}

	lua_newtable(m_L);
	lua_setfield(m_L, LUA_REGISTRYINDEX, "openbfme.modules");
	if (setup)
		setup(m_L);

	luaL_sandbox(m_L); // the globals and the libraries read-only
	lua_State *T = lua_newthread(m_L); // the mod's environment: its chunks' globals live here
	luaL_sandboxthread(T);
	lua_setfield(m_L, LUA_REGISTRYINDEX, "openbfme.thread");
	// lockstep from here on (the libraries above set metatables and then fill them, which lockstep's frozen metatables would refuse)
	if (m_role == SdkScriptRole::Sim)
		lua_openbfme_setlockstep(m_L, 1);
}

LuauScriptState::~LuauScriptState()
{
	if (m_L)
		lua_close(m_L);
}

std::uint32_t LuauScriptState::randomBits()
{
	if (m_random)
		return m_random();
	// no host generator (tests, tools): a fixed sequence (PCG32, seed 0)
	m_rngState = m_rngState * 6364136223846793005ull + 1442695040888963407ull;
	const std::uint32_t x = std::uint32_t(((m_rngState >> 18u) ^ m_rngState) >> 27u);
	const std::uint32_t rot = std::uint32_t(m_rngState >> 59u);
	return (x >> rot) | (x << ((32u - rot) & 31u));
}

void LuauScriptState::notePrinted(const std::string &line)
{
	m_printed.push_back(line);
}

bool LuauScriptState::reservePrint(std::size_t bytes)
{
	// Sol r1: printed text is held outside the VM's memory cap, so it has budgets of its own: per call and in total
	if (m_printOverflow || m_printedThisCall + bytes > kPrintPerCall || m_printedTotal + bytes > kPrintTotal)
	{
		m_printOverflow = true;
		return false;
	}
	m_printedThisCall += bytes;
	m_printedTotal += bytes;
	return true;
}

bool LuauScriptState::readModFile(const std::string &path, std::string &out, std::string &error)
{
	// Sol r1: a sim script reads nothing of the presentation scripts' folder (it is not part of the fingerprint the peers share)
	if (m_role == SdkScriptRole::Sim)
	{
		// Sol r1 / r2: nor the presentation scripts' files nor the manifest (neither is in the fingerprint; the manifest's sim part is the "sdk sim"
		// line); the path is matched as the mount keys it (ModLooseIndex::key: any case, either separator)
		const std::string key = ModLooseIndex::key(path);
		if (key.rfind("openbfme\\sdk\\presentation\\", 0) == 0 || key == "openbfme\\sdk\\mod.json")
		{
			error = "a sim script cannot read " + path + ": it is not part of the game the players share (the presentation scripts' files and the "
				"manifest)";
			return false;
		}
	}
	if (!m_reader)
	{
		error = "this script has no mod folder to read from";
		return false;
	}
	return m_reader(path, out, error);
}

bool LuauScriptState::enterModule(const std::string &name, std::string &error)
{
	for (const std::string &n : m_loading)
	{
		if (n == name)
		{
			error = "require cycle: ";
			for (const std::string &m : m_loading)
				error += m + " -> ";
			error += name;
			return false;
		}
	}
	m_loading.push_back(name);
	return true;
}

void LuauScriptState::leaveModule()
{
	if (!m_loading.empty())
		m_loading.pop_back();
}

void *LuauScriptState::allocate(void *ptr, size_t osize, size_t nsize)
{
	if (nsize == 0)
	{
		std::free(ptr);
		m_bytes -= osize;
		return nullptr;
	}
	if (nsize > osize && m_bytes - osize + nsize > m_limits.memoryBytes)
		return nullptr; // over the cap: Luau raises its "not enough memory" error
	void *p = std::realloc(ptr, nsize);
	if (p)
		m_bytes = m_bytes - osize + nsize;
	return p;
}

void LuauScriptState::step(lua_State *L)
{
	// Sol r1: the budget is sticky for the rest of the call: a script that catches the error (pcall, xpcall, a coroutine) meets it again at
	// its next safepoint, so it can only unwind to the host
	if (m_budgetExceeded || ++m_steps > m_limits.stepsPerCall)
	{
		m_budgetExceeded = true;
		luaL_error(L, "the script ran longer than its step budget (%llu VM safepoints in one call)", (unsigned long long)m_limits.stepsPerCall);
	}
}

lua_State *LuauScriptState::thread()
{
	lua_getfield(m_L, LUA_REGISTRYINDEX, "openbfme.thread");
	lua_State *T = lua_tothread(m_L, -1);
	lua_pop(m_L, 1);
	return T;
}

void LuauScriptState::fail(const std::string &message)
{
	m_failed = true;
	m_failure = m_modName + ": " + message;
}

bool LuauScriptState::run(lua_State *T, int nargs, std::string &error)
{
	m_steps = 0;
	m_budgetExceeded = false;
	m_printedThisCall = 0;
	int status = lua_pcall(T, nargs, 0, 0);
	m_stepsLastCall = m_steps;
	m_steps = 0;
	if (status == LUA_OK && (m_budgetExceeded || m_printOverflow))
	{
		lua_settop(T, 0);
		lua_pushstring(T, m_budgetExceeded ? "the script ran longer than its step budget" : "the script printed more than its output budget");
		status = LUA_ERRRUN;
	}
	m_budgetExceeded = false;
	if (status != LUA_OK)
	{
		const char *msg = lua_tostring(T, -1);
		fail(msg ? msg : (status == LUA_ERRMEM ? "not enough memory (the script's memory cap)" : "error"));
		lua_settop(T, 0);
		error = m_failure;
		return false;
	}
	return true;
}

bool LuauScriptState::load(const std::string &chunkName, const std::string &source, std::string &error)
{
	if (m_failed || !m_L)
	{
		error = m_failure;
		return false;
	}
	lua_CompileOptions options = {};
	options.optimizationLevel = 1;
	options.debugLevel = 1;
	if (m_role == SdkScriptRole::Sim)
		options.disabledBuiltins = kSimDisabledBuiltins;
	size_t size = 0;
	std::unique_ptr<char, void (*)(void *)> bytecode(luau_compile(source.data(), source.size(), &options, &size), std::free);
	lua_State *T = thread();
	const std::string chunk = "@" + chunkName;
	LoadRequest request{ chunk.c_str(), bytecode.get(), size };
	lua_pushcfunction(T, protectedLoad, "load");
	lua_pushlightuserdata(T, &request);
	if (lua_pcall(T, 1, 1, 0) != LUA_OK)
	{
		const char *msg = lua_tostring(T, -1);
		fail(msg ? msg : "cannot load " + chunkName);
		lua_settop(T, 0);
		error = m_failure;
		return false;
	}
	return run(T, 0, error);
}

bool LuauScriptState::loadFile(const std::string &name, std::string &error)
{
	if (!safePath(name))
	{
		error = m_modName + ": '" + name + "' is not a script of the mod";
		return false;
	}
	std::string source;
	if (!readModFile(chunkPath(m_role, name), source, error))
	{
		error = m_modName + ": " + error;
		return false;
	}
	return load(chunkPath(m_role, name), source, error);
}

bool LuauScriptState::pushFunction(lua_State *T, const std::string &name, std::string &error)
{
	if (m_failed || !m_L)
	{
		error = m_failure;
		return false;
	}
	lua_getglobal(T, name.c_str());
	if (!lua_isfunction(T, -1))
	{
		lua_settop(T, 0);
		error = m_modName + ": the scripts define no function " + name;
		return false;
	}
	return true;
}

bool LuauScriptState::call(const std::string &name, const std::vector<std::string> &stringArgs, std::string &error)
{
	lua_State *T = m_L ? thread() : nullptr;
	if (!T || !pushFunction(T, name, error))
	{
		if (!T)
			error = m_failure;
		return false;
	}
	for (const std::string &a : stringArgs)
		lua_pushlstring(T, a.data(), a.size());
	return run(T, (int)stringArgs.size(), error);
}

bool LuauScriptState::callNumbers(const std::string &name, const std::vector<double> &args, std::string &error)
{
	lua_State *T = m_L ? thread() : nullptr;
	if (!T || !pushFunction(T, name, error))
	{
		if (!T)
			error = m_failure;
		return false;
	}
	for (double a : args)
		lua_pushnumber(T, a);
	return run(T, (int)args.size(), error);
}

bool LuauScriptState::callWith(const std::string &name, const std::function<int(lua_State *T)> &push, std::string &error)
{
	lua_State *T = m_L ? thread() : nullptr;
	if (!T || !pushFunction(T, name, error))
	{
		if (!T)
			error = m_failure;
		return false;
	}
	return run(T, push(T), error);
}

bool LuauScriptState::hasFunction(const std::string &name)
{
	if (m_failed || !m_L)
		return false;
	lua_State *T = thread();
	lua_getglobal(T, name.c_str());
	const bool is = lua_isfunction(T, -1);
	lua_pop(T, 1);
	return is;
}
