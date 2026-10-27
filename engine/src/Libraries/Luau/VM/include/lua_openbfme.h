// OpenBFME. GPL-3.0. New file of the Luau patch layer (lane SDK-2; README.md).
#pragma once

#include "lua.h"

// Lockstep mode for a state that runs simulation (sim role) scripts: table keys must be numbers / strings / booleans, no weak tables, no
// addresses (lua_encodepointer returns 0) and the collector is paced by allocation alone. Set it once the libraries are opened (they set metatables and then fill them).
LUA_API void lua_openbfme_setlockstep(lua_State* L, int on);
LUA_API int lua_openbfme_lockstep(lua_State* L);
