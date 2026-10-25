// OpenBFME. GPL-3.0.
// CommandStreamChecks (lane ANTICHEAT-1): see CommandStreamChecks.h.

#include "GameNetwork/CommandStreamChecks.h"

#include "Common/Player.h"
#include "Common/PlayerList.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Object/Object.h"
#include "GameNetwork/OrdersIntoFog.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <utility>

namespace
{
std::string jsonString(const std::string &s)
{
	std::string out = "\"";
	for (unsigned char c : s)
	{
		if (c == '"' || c == '\\')
		{
			out += '\\';
			out += (char)c;
		}
		else if (c < 0x20)
		{
			char buf[8];
			std::snprintf(buf, sizeof buf, "\\u%04x", c);
			out += buf;
		}
		else
		{
			out += (char)c;
		}
	}
	return out + "\"";
}

std::string jsonNumber(double v)
{
	if (!std::isfinite(v))
	{
		return "null"; // lane ANTICHEAT-1 (Sol r3): a client-reported value can be anything; the report stays valid JSON
	}
	char buf[32];
	std::snprintf(buf, sizeof buf, "%.6f", v);
	return buf;
}

std::string commandName(int type)
{
	const char *n = GameMessageTypeName(type);
	return n && *n ? std::string(n) : "MSG_UNKNOWN_" + std::to_string(type);
}

std::string header(const char *detector, const std::string &abstain, const std::string &gameId, const std::string &crcParity, UnsignedInt frames)
{
	std::string s = std::string("{\"v\":1,\"detector\":\"") + detector + "\",\"detector_version\":1";
	s += ",\"game_id\":" + (gameId.empty() ? std::string("null") : jsonString(gameId));
	s += ",\"status\":" + jsonString(abstain.empty() ? "ok" : "abstained");
	s += ",\"abstain_reason\":" + (abstain.empty() ? std::string("null") : jsonString(abstain));
	s += ",\"frames\":" + std::to_string(frames) + ",\"crc_parity\":" + jsonString(crcParity);
	return s;
}

template <class R> void fillNames(GameLogic &logic, std::vector<int> players, std::vector<R> &out)
{
	std::sort(players.begin(), players.end());
	players.erase(std::unique(players.begin(), players.end()), players.end());
	for (int p : players)
	{
		R r;
		r.player = p;
		if (const Player *pl = logic.players().getNthPlayer(p))
		{
			r.name = pl->getPlayerName();
		}
		out.push_back(std::move(r));
	}
}
} // namespace

// ---- D5 ------------------------------------------------------------------------------------------------------------------------------------
InputRateCheck::InputRateCheck(GameLogic &logic, std::vector<int> players, Settings settings)
	: m_settings(settings)
{
	fillNames(logic, std::move(players), m_results);
	m_windows.resize(m_results.size());
}

InputRateCheck::InputRateCheck(GameLogic &logic, std::vector<int> players)
	: InputRateCheck(logic, std::move(players), Settings{})
{
}

InputRateCheck::PlayerResult *InputRateCheck::resultFor(int player, size_t *index)
{
	for (size_t i = 0; i < m_results.size(); ++i)
	{
		if (m_results[i].player == player)
		{
			*index = i;
			return &m_results[i];
		}
	}
	return nullptr;
}

void InputRateCheck::setSlot(int player, int slot)
{
	size_t i = 0;
	if (PlayerResult *r = resultFor(player, &i))
	{
		r->slot = slot;
	}
}

void InputRateCheck::abstain(const std::string &reason)
{
	if (m_abstain.empty())
	{
		m_abstain = reason;
	}
}

void InputRateCheck::beforeFrame(UnsignedInt frame, const std::vector<GameMessage> &commands)
{
	if (m_any && frame <= m_lastFrame)
	{
		abstain("frame order: batch " + std::to_string(frame) + " after batch " + std::to_string(m_lastFrame));
		return;
	}
	m_any = true;
	m_lastFrame = frame;
	std::vector<std::vector<int>> types(m_results.size());
	for (const GameMessage &m : commands)
	{
		size_t i = 0;
		if (counted(m.getType()) && resultFor(m.getPlayerIndex(), &i))
		{
			types[i].push_back(m.getType());
		}
	}
	for (size_t i = 0; i < m_results.size(); ++i)
	{
		PlayerResult &r = m_results[i];
		Window &w = m_windows[i];
		r.commands += types[i].size();
		w.count += (unsigned)types[i].size();
		w.frames.emplace_back(frame, std::move(types[i]));
		while (!w.frames.empty() && w.frames.front().first + m_settings.windowFrames <= frame)
		{
			w.count -= (unsigned)w.frames.front().second.size();
			w.frames.pop_front();
		}
		if (w.count > r.peak)
		{
			r.peak = w.count;
			r.peakFrame = frame;
		}
		if (w.count <= m_settings.threshold)
		{
			w.inEpisode = false;
			continue;
		}
		if (!w.inEpisode)
		{
			w.inEpisode = true;
			Episode e;
			e.startFrame = frame;
			r.episodes.push_back(e);
		}
		Episode &e = r.episodes.back();
		e.endFrame = frame;
		if (w.count > e.peak)
		{
			e.peak = w.count;
			e.peakFrame = frame;
			std::map<int, unsigned> byType;
			for (const auto &f : w.frames)
			{
				for (int t : f.second)
				{
					++byType[t];
				}
			}
			unsigned best = 0;
			for (const auto &kv : byType) // ascending type: the lowest type wins a tie
			{
				if (kv.second > best)
				{
					best = kv.second;
					e.topCommand = kv.first;
				}
			}
		}
	}
}

std::string InputRateCheck::json(const std::string &gameId, const std::string &crcParity, UnsignedInt frames) const
{
	std::string s = header("D5-input-rate", m_abstain, gameId, crcParity, frames);
	s += ",\"settings\":{\"window_frames\":" + std::to_string(m_settings.windowFrames) + ",\"threshold\":" + std::to_string(m_settings.threshold) + "}";
	s += ",\"players\":[";
	for (size_t i = 0; i < m_results.size(); ++i)
	{
		const PlayerResult &r = m_results[i];
		const std::string band = !m_abstain.empty() ? "abstained" : r.episodes.empty() ? "none" : "review";
		s += (i ? "," : "") + std::string("{\"player_index\":") + std::to_string(r.player) + ",\"slot\":" + std::to_string(r.slot) +
			 ",\"name\":" + jsonString(r.name) + ",\"band\":" + jsonString(band) + ",\"score\":" + jsonNumber(r.episodes.empty() ? 0.0 : 1.0) +
			 ",\"encounters\":" + std::to_string(r.episodes.size()) + ",\"commands_total\":" + std::to_string(r.commands) +
			 ",\"peak_5s\":" + std::to_string(r.peak) + ",\"peak_frame\":" + std::to_string(r.peakFrame) + ",\"events\":[";
		for (size_t k = 0; k < r.episodes.size(); ++k)
		{
			const Episode &e = r.episodes[k];
			s += (k ? "," : "") + std::string("{\"frame\":") + std::to_string(e.peakFrame) + ",\"time_s\":" + jsonNumber(e.peakFrame / 5.0) +
				 ",\"command\":" + jsonString(commandName(e.topCommand)) + ",\"count\":" + std::to_string(e.peak) +
				 ",\"start_frame\":" + std::to_string(e.startFrame) + ",\"end_frame\":" + std::to_string(e.endFrame) +
				 ",\"encounter\":" + std::to_string(k + 1) + "}";
		}
		s += "]}";
	}
	return s + "]}";
}

// ---- D6 ------------------------------------------------------------------------------------------------------------------------------------
CommandIntegrityCheck::CommandIntegrityCheck(GameLogic &logic, std::vector<int> players, unsigned encounterFrames)
	: m_logic(logic)
	, m_encounterFrames(encounterFrames)
{
	fillNames(logic, std::move(players), m_results);
}

void CommandIntegrityCheck::setSlot(int player, int slot)
{
	for (PlayerResult &r : m_results)
	{
		if (r.player == player)
		{
			r.slot = slot;
		}
	}
}

void CommandIntegrityCheck::abstain(const std::string &reason)
{
	if (m_abstain.empty())
	{
		m_abstain = reason;
	}
}

int CommandIntegrityCheck::issuerArgument(int messageType)
{
	switch (messageType)
	{
	case MSG_SET_RALLY_POINT:          // { object id (the building), location, bool global, object id target } (GameLogicDispatch, issuerObject)
	case MSG_HORDE_SET_FORMATION:      // { object id (the horde), int formation template } (HordeFormation.cpp)
	case MSG_HORDE_TOGGLE_FORMATION:   // { object id (the horde) }
	case MSG_ENTER:                    // { object id (the one that enters), object id (the container) } (CommandXlat)
		return 0;
	case MSG_DO_AUTO_ABILITY:          // { int power, object id (the caster) } (HeroAbilityModules.cpp, issuerObject)
	case MSG_DO_AUTO_ABILITY_WEAPON:   // { int slot, object id }
		return 1;
	default:
		return -1;
	}
}

void CommandIntegrityCheck::beforeFrame(UnsignedInt frame, const std::vector<GameMessage> &commands)
{
	for (const GameMessage &m : commands)
	{
		for (PlayerResult &r : m_results)
		{
			if (r.player == m.getPlayerIndex())
			{
				check(frame, m, r);
			}
		}
	}
}

void CommandIntegrityCheck::check(UnsignedInt frame, const GameMessage &m, PlayerResult &r)
{
	const int type = m.getType();
	if (!InputRateCheck::counted(type))
	{
		return;
	}
	++r.commands;
	auto add = [&](const char *reason, ObjectID object, int argument) {
		Event e;
		e.frame = frame;
		e.messageType = type;
		e.reason = reason;
		e.object = object;
		e.argument = argument;
		r.events.push_back(std::move(e));
	};
	const char *name = GameMessageTypeName(type);
	if (!name || !*name || type <= MSG_BEGIN_NETWORK_MESSAGES)
	{
		add("unknown_type", 0, -1);
		return;
	}
	auto isType = [&](int index, GameMessageArgumentDataType want) {
		const GameMessageArgument *a = m.getArgument((size_t)index);
		return a && a->type == want;
	};
	if (OrdersIntoFog::isSelection(type))
	{
		if (!isType(0, ARGUMENTDATATYPE_BOOLEAN))
		{
			add("malformed", 0, 0);
			return;
		}
		for (size_t i = 1; i < m.getArgumentCount(); ++i)
		{
			if (!isType((int)i, ARGUMENTDATATYPE_OBJECTID))
			{
				add("malformed", 0, (int)i);
				return;
			}
		}
		return;
	}
	const int target = OrdersIntoFog::targetArgument(type);
	if (target >= 0 && type != MSG_DO_SPECIAL_POWER_AT_LOCATION && !isType(target, ARGUMENTDATATYPE_OBJECTID))
	{
		add("malformed", 0, target);
		return;
	}
	const int issuer = issuerArgument(type);
	if (issuer < 0)
	{
		return;
	}
	if (!isType(issuer, ARGUMENTDATATYPE_OBJECTID))
	{
		add("malformed", 0, issuer);
		return;
	}
	const ObjectID id = m.getArgument((size_t)issuer)->objectID;
	const Object *obj = id == INVALID_ID ? nullptr : m_logic.findObjectByID(id);
	const Player *owner = obj ? obj->getControllingPlayer() : nullptr;
	if (owner && owner->getPlayerIndex() != m.getPlayerIndex())
	{
		add("foreign_object", id, issuer); // GameLogicDispatch::issuerObject refuses it; a clean client never names it
	}
}

std::vector<CommandIntegrityCheck::PlayerResult> CommandIntegrityCheck::results() const
{
	std::vector<PlayerResult> out = m_results;
	for (PlayerResult &r : out)
	{
		UnsignedInt first = 0;
		for (Event &e : r.events)
		{
			if (r.encounters == 0 || e.frame > first + m_encounterFrames)
			{
				first = e.frame;
				++r.encounters;
			}
			e.encounter = r.encounters;
		}
	}
	return out;
}

std::string CommandIntegrityCheck::json(const std::string &gameId, const std::string &crcParity, UnsignedInt frames) const
{
	std::string s = header("D6-command-integrity", m_abstain, gameId, crcParity, frames);
	s += ",\"settings\":{\"encounter_frames\":" + std::to_string(m_encounterFrames) + "}";
	s += ",\"players\":[";
	const std::vector<PlayerResult> rs = results();
	for (size_t i = 0; i < rs.size(); ++i)
	{
		const PlayerResult &r = rs[i];
		const std::string band = !m_abstain.empty() ? "abstained" : r.events.empty() ? "none" : "review";
		s += (i ? "," : "") + std::string("{\"player_index\":") + std::to_string(r.player) + ",\"slot\":" + std::to_string(r.slot) +
			 ",\"name\":" + jsonString(r.name) + ",\"band\":" + jsonString(band) + ",\"score\":" + jsonNumber(r.events.empty() ? 0.0 : 1.0) +
			 ",\"encounters\":" + std::to_string(r.encounters) + ",\"commands_total\":" + std::to_string(r.commands) + ",\"events\":[";
		for (size_t k = 0; k < r.events.size(); ++k)
		{
			const Event &e = r.events[k];
			s += (k ? "," : "") + std::string("{\"frame\":") + std::to_string(e.frame) + ",\"time_s\":" + jsonNumber(e.frame / 5.0) +
				 ",\"command\":" + jsonString(commandName(e.messageType)) + ",\"reason\":" + jsonString(e.reason) +
				 ",\"target_id\":" + std::to_string(e.object) + ",\"argument\":" + std::to_string(e.argument) +
				 ",\"encounter\":" + std::to_string(e.encounter) + "}";
		}
		s += "]}";
	}
	return s + "]}";
}
