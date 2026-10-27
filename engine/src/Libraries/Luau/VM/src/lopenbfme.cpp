// OpenBFME. GPL-3.0. New file of the Luau patch layer (lane SDK-2; README.md).
#include "lua_openbfme.h"

#include "lstate.h"

void lua_openbfme_setlockstep(lua_State* L, int on)
{
    L->global->openbfmelockstep = on ? 1 : 0;
}

int lua_openbfme_lockstep(lua_State* L)
{
    return L->global->openbfmelockstep;
}
