// OpenBFME. GPL-3.0. See GameLogic/Sdk/SdkScriptHost.h (lane SDK-2).

#include "GameLogic/Sdk/SdkScriptHost.h"

#include "Common/GameState.h"
#include "Common/Money.h"
#include "Common/Player.h"
#include "Common/PlayerList.h"
#include "Common/RandomValue.h"
#include "Common/StateHash.h"
#include "Common/Thing/ThingTemplate.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Object/Object.h"
#include "GameLogic/Sdk/SdkManifest.h"

#include "luau/lua.h"
#include "luau/lualib.h"

namespace
{

SdkScriptHost *hostOf(lua_State *L)
{
	return static_cast<SdkScriptHost *>(lua_tolightuserdata(L, lua_upvalueindex(1)));
}

Player *playerArg(lua_State *L, int arg)
{
	const int i = luaL_checkinteger(L, arg);
	Player *p = hostOf(L)->logic().players().getNthPlayer(i);
	if (!p)
		luaL_error(L, "game: there is no player %d (0 .. %d)", i, hostOf(L)->logic().players().getPlayerCount() - 1);
	return p;
}

int gameFrame(lua_State *L)
{
	lua_pushinteger(L, (int)hostOf(L)->logic().getFrame());
	return 1;
}

int gamePlayerCount(lua_State *L)
{
	lua_pushinteger(L, hostOf(L)->logic().players().getPlayerCount());
	return 1;
}

int gamePlayerName(lua_State *L)
{
	lua_pushstring(L, playerArg(L, 1)->getPlayerName().c_str());
	return 1;
}

int gamePlayerSide(lua_State *L)
{
	lua_pushstring(L, playerArg(L, 1)->getSide().c_str());
	return 1;
}

int gameMoney(lua_State *L)
{
	lua_pushinteger(L, (int)playerArg(L, 1)->getMoney()->countMoney());
	return 1;
}

int gameAddMoney(lua_State *L)
{
	Player *p = playerArg(L, 1);
	const int amount = luaL_checkinteger(L, 2);
	if (amount < 1 || amount > 1000000)
		luaL_error(L, "game.addMoney: the amount must be a whole number 1 .. 1000000, not %d", amount);
	p->getMoney()->deposit((std::uint32_t)amount, nullptr, false);
	return 0;
}

// presentation only: the player this machine plays (-1: none, an observer); differs between peers, so a sim script never sees it
int gameLocalPlayer(lua_State *L)
{
	const Player *p = hostOf(L)->logic().players().getLocalPlayer();
	lua_pushinteger(L, p ? p->getPlayerIndex() : -1);
	return 1;
}

int uiBanner(lua_State *L)
{
	hostOf(L)->pushBanner(luaL_checkstring(L, 1));
	return 0;
}

void registerGame(lua_State *L, SdkScriptHost *host, bool sim)
{
	const luaL_Reg api[] = { { "frame", gameFrame }, { "playerCount", gamePlayerCount }, { "playerName", gamePlayerName },
		{ "playerSide", gamePlayerSide }, { "money", gameMoney }, { sim ? "addMoney" : nullptr, gameAddMoney }, { nullptr, nullptr } };
	lua_newtable(L);
	for (const luaL_Reg *f = api; f->name; ++f)
	{
		lua_pushlightuserdata(L, host);
		lua_pushcclosure(L, f->func, f->name, 1);
		lua_setfield(L, -2, f->name);
	}
	lua_setglobal(L, "game");
	if (!sim)
	{
		lua_getglobal(L, "game");
		lua_pushlightuserdata(L, host);
		lua_pushcclosure(L, gameLocalPlayer, "localPlayer", 1);
		lua_setfield(L, -2, "localPlayer");
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushlightuserdata(L, host);
		lua_pushcclosure(L, uiBanner, "banner", 1);
		lua_setfield(L, -2, "banner");
		lua_setglobal(L, "ui");
	}
}

} // namespace

SdkScriptHost::SdkScriptHost(GameLogic &logic, SdkScriptLimits limits) : m_logic(logic), m_limits(limits)
{
}

SdkScriptHost::~SdkScriptHost()
{
	if (m_worldHooks)
		m_logic.removeWorldHooks(m_worldHooks);
	if (m_frameHook)
		m_logic.removeEndOfFrameHook(m_frameHook);
	if (m_hashContributor)
		m_logic.removeStateHashContributor(m_hashContributor);
}

bool SdkScriptHost::start(const ModLooseIndex &modFolder, std::string &error)
{
	m_files = std::make_unique<SdkModFiles>(modFolder);
	if (!m_files->has(SdkManifest::path()))
		return true;
	std::string json;
	SdkManifest manifest;
	if (!m_files->read(SdkManifest::path(), json, error) || !SdkManifest::parse(json, manifest, error))
		return false;
	m_modName = manifest.name;
	if (manifest.sim.empty() && manifest.presentation.empty())
		return true;
	if (!manifest.sim.empty())
	{
		m_state = std::make_unique<LuauScriptState>(SdkScriptRole::Sim, manifest.name, m_limits, m_files->reader(),
			[this] { return m_logic.random().randomValue(); }, [this](lua_State *L) { registerGame(L, this, true); });
		for (const std::string &entry : manifest.sim)
		{
			if (!m_state->loadFile(entry, error))
			{
				error = "SDK " + error;
				m_state.reset();
				return false;
			}
			m_steps += m_state->stepsLastCall();
		}
		for (const std::string &line : m_state->printed())
			report("SDK " + m_modName + ": " + line);
		m_printedSeen = m_state->printed().size();
	}
	if (!manifest.presentation.empty())
	{
		m_presentation = std::make_unique<LuauScriptState>(SdkScriptRole::Presentation, manifest.name, m_limits, m_files->reader(),
			LuauScriptState::Random(), [this](lua_State *L) { registerGame(L, this, false); });
		for (const std::string &entry : manifest.presentation)
		{
			std::string presentationError;
			if (!m_presentation->loadFile(entry, presentationError))
			{
				report("SDK presentation " + presentationError + " (the mod's presentation scripts are stopped)");
				m_presentationStopped = true;
				break;
			}
		}
	}
	m_worldHooks = m_logic.addWorldHooks(
		[this](Object &o) {
			const Player *p = o.getControllingPlayer();
			m_events.push_back(Event{ true, (std::uint32_t)o.getID(), o.getTemplate() ? o.getTemplate()->getName() : std::string(), p ? p->getPlayerIndex() : -1 });
		},
		[this](Object &o) {
			const Player *p = o.getControllingPlayer();
			m_events.push_back(Event{ false, (std::uint32_t)o.getID(), o.getTemplate() ? o.getTemplate()->getName() : std::string(), p ? p->getPlayerIndex() : -1 });
		});
	m_frameHook = m_logic.addEndOfFrameHook([this](UnsignedInt frame) { endOfFrame(frame); });
	if (m_state)
	{
		// Sol r1: a running script VM is not saved yet: a save of this game is a refusal naming the mod's scripts (GameState), and the players
		// are told at the start
		m_logic.gameState().declareBlockWithoutXfer("obfme:SdkScripts (the sim scripts of the mod " + m_modName + ")", 1u << SNAPSHOT_SAVELOAD, "SDK-2",
			{ "sdk scripts" });
		report("SDK " + m_modName + ": this game cannot be saved: a mod's sim scripts are not saved yet");
		pushBanner(m_modName + ": this game cannot be saved (its scripts are not saved yet)"); // Sol r2: on screen too
	}
	if (m_state)
		m_hashContributor = m_logic.addStateHashContributor(
		[this](StateHasher &h) {
			h.addU64(m_calls);
			h.addU64(m_steps);
			h.addBool(m_stopped);
		},
		"sdk scripts");
	return true;
}

bool SdkScriptHost::callIfDefined(const char *name, const std::function<int(lua_State *T)> &push)
{
	if (m_stopped || !m_state->hasFunction(name))
		return true;
	std::string error;
	++m_calls;
	const bool ok = m_state->callWith(name, push, error);
	m_steps += m_state->stepsLastCall();
	for (size_t i = m_printedSeen; i < m_state->printed().size(); ++i)
		report("SDK " + m_modName + ": " + m_state->printed()[i]);
	m_printedSeen = m_state->printed().size();
	if (!ok)
	{
		m_stopped = true;
		report("SDK " + error + " (frame " + std::to_string(m_logic.getFrame()) + "; the mod's scripts are stopped)");
	}
	return ok;
}

void SdkScriptHost::presentationCall(const char *name, const std::function<int(lua_State *T)> &push)
{
	if (!m_presentation || m_presentationStopped || !m_presentation->hasFunction(name))
		return;
	std::string error;
	const bool ok = m_presentation->callWith(name, push, error);
	for (size_t i = m_presentationPrinted; i < m_presentation->printed().size(); ++i)
		report("SDK presentation " + m_modName + ": " + m_presentation->printed()[i]);
	m_presentationPrinted = m_presentation->printed().size();
	if (!ok)
	{
		m_presentationStopped = true;
		report("SDK presentation " + error + " (the mod's presentation scripts are stopped)");
	}
}

void SdkScriptHost::report(const std::string &line)
{
	// bounded by bytes (Sol r1, r2): the scripts' own output is limited (LuauScriptState::kPrintTotal) and the mod's name is at most 64
	// characters; this caps the copies the host keeps (each line counted with its string object), the overflow notice included
	const std::size_t cost = line.size() + 64;
	const std::size_t noticeRoom = 128; // Sol r3: the overflow notice fits inside the budget too
	if (m_reportBytes + cost > kReportBytes - noticeRoom)
	{
		if (!m_reportsFull)
		{
			m_reportsFull = true;
			m_reports.push_back("SDK: more report lines than the host keeps; the rest are not kept");
		}
		return;
	}
	m_reportBytes += cost;
	m_reports.push_back(line);
	std::lock_guard<std::mutex> lock(m_outboxMutex);
	if (m_newReportBytes + cost <= kReportBytes)
	{
		m_newReportBytes += cost;
		m_newReports.push_back(line);
	}
}

void SdkScriptHost::pushBanner(const std::string &text)
{
	if (m_bannersThisFrame >= 8)
		return;
	++m_bannersThisFrame;
	std::lock_guard<std::mutex> lock(m_outboxMutex);
	m_banners.push_back(text.substr(0, 200));
}

std::vector<std::string> SdkScriptHost::takeBanners()
{
	std::lock_guard<std::mutex> lock(m_outboxMutex);
	std::vector<std::string> out;
	out.swap(m_banners);
	return out;
}

std::vector<std::string> SdkScriptHost::takeNewReports()
{
	std::lock_guard<std::mutex> lock(m_outboxMutex);
	std::vector<std::string> out;
	out.swap(m_newReports);
	m_newReportBytes = 0;
	return out;
}

void SdkScriptHost::endOfFrame(std::uint32_t frame)
{
	m_bannersThisFrame = 0;
	const std::vector<Event> events = std::move(m_events);
	m_events.clear();
	const bool first = !m_started;
	m_started = true;
	// the sim scripts first (lockstep), then the presentation scripts (this player's screen only); the same events, in the same order
	for (int pass = 0; pass < 2; ++pass)
	{
		const bool sim = pass == 0;
		if (sim && (!m_state || m_stopped))
			continue;
		auto call = [this, sim](const char *name, const std::function<int(lua_State *T)> &push) {
			if (sim)
				return callIfDefined(name, push);
			presentationCall(name, push);
			return true;
		};
		if (first && !call("onGameStart", [](lua_State *) { return 0; }))
			continue;
		bool ok = true;
		for (const Event &e : events)
		{
			if (!call(e.created ? "onObjectCreated" : "onObjectDestroyed", [&e](lua_State *T) {
					lua_pushinteger(T, (int)e.id);
					lua_pushstring(T, e.templateName.c_str());
					lua_pushinteger(T, e.player);
					return 3;
				}))
			{
				ok = false;
				break;
			}
		}
		if (ok)
			call("onFrame", [frame](lua_State *T) {
				lua_pushinteger(T, (int)frame);
				return 1;
			});
	}
}
