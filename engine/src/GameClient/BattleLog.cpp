// OpenBFME. GPL-3.0.
// See GameClient/BattleLog.h.

#include "GameClient/BattleLog.h"

#include "Common/Player.h"
#include "Common/PlayerList.h"
#include "Common/Thing/ThingTemplate.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Module/AIUpdate.h"
#include "GameLogic/Module/SiegeModules.h"
#include "GameLogic/Object/Object.h"
#include "GameLogic/ObjectTemplateInfo.h"
#include "GameLogic/ScriptEngine/ScriptEngine.h"

#include <algorithm>
#include <cstdio>
#include <map>

namespace
{
struct Side
{
	int troops = 0, raised = 0, battalions = 0, heroes = 0;
};
} // namespace

std::string BattleLog::line(GameLogic &logic, const std::vector<std::string> &watch)
{
	const int horde = ObjectTemplateInfoBuilder::kindOfIndex("HORDE");
	const int infantry = ObjectTemplateInfoBuilder::kindOfIndex("INFANTRY");
	const int cavalry = ObjectTemplateInfoBuilder::kindOfIndex("CAVALRY");
	const int monster = ObjectTemplateInfoBuilder::kindOfIndex("MONSTER");
	const int hero = ObjectTemplateInfoBuilder::kindOfIndex("HERO");
	const int gate = ObjectTemplateInfoBuilder::kindOfIndex("BLOCKING_GATE");
	const int wall = ObjectTemplateInfoBuilder::kindOfIndex("WALK_ON_TOP_OF_WALL");
	auto is = [](const Object &o, int bit) { return bit >= 0 && o.isKindOf((unsigned)bit); };
	std::map<int, Side> sides;
	std::string gates, walls, watched;
	int deploys[5] = {};
	char b[320];
	for (Object *o = logic.getFirstObject(); o; o = o->getNextObject())
	{
		const Player *p = o->getControllingPlayer();
		const int owner = p ? p->getPlayerIndex() : -1;
		if (!watch.empty() && std::find(watch.begin(), watch.end(), o->getTemplate()->getName()) != watch.end())
		{
			const Coord3D &pos = *o->getPosition();
			const BodyModuleInterface *body = o->getBodyModule();
			const AIUpdateInterface *ai = o->getAIUpdateInterface();
			const Object *victim = ai ? ai->currentVictim() : nullptr;
			const SiegeDeploySpecialPower *sd = SiegeDeploySpecialPower::of(*o);
			std::snprintf(b, sizeof(b), "\n  %s %s (%.0f %.0f %.0f) hp %.0f%s state %u victim %s phase %d", o->getTemplate()->getName().c_str(),
						  o->getName().c_str(), (double)pos.x, (double)pos.y, (double)pos.z, body ? (double)body->getHealth() : -1.0,
						  o->isEffectivelyDead() ? " dead" : "", ai ? ai->currentStateId() : 0u, victim ? victim->getTemplate()->getName().c_str() : "-",
						  sd ? sd->phase() : -1);
			watched += b;
		}
		if (is(*o, gate) || is(*o, wall))
		{
			const BodyModuleInterface *body = o->getBodyModule();
			if (body && (o->isEffectivelyDead() || body->getHealth() < body->getMaxHealth()))
			{
				std::snprintf(b, sizeof(b), " %s:%.0f/%.0f", o->getTemplate()->getName().c_str(), o->isEffectivelyDead() ? 0.0 : (double)body->getHealth(),
							  (double)body->getMaxHealth());
				(is(*o, gate) ? gates : walls) += b;
			}
			continue;
		}
		if (o->isEffectivelyDead())
		{
			continue;
		}
		if (const SiegeDeploySpecialPower *sd = SiegeDeploySpecialPower::of(*o))
		{
			++deploys[sd->phase() >= 0 && sd->phase() < 5 ? sd->phase() : 0];
		}
		Side &s = sides[owner];
		s.battalions += is(*o, horde) ? 1 : 0;
		s.heroes += is(*o, hero) ? 1 : 0;
		if (is(*o, infantry) || is(*o, cavalry) || is(*o, monster))
		{
			++s.troops;
			const Coord3D &pos = *o->getPosition();
			s.raised += pos.z - logic.getGroundHeight(pos.x, pos.y) > kRaised ? 1 : 0;
		}
	}
	std::string out = "frame " + std::to_string(logic.getFrame());
	for (const auto &[owner, s] : sides)
	{
		if (s.troops == 0 && s.battalions == 0)
		{
			continue;
		}
		const Player *p = logic.players().getNthPlayer(owner);
		std::snprintf(b, sizeof(b), " | %s troops %d raised %d battalions %d heroes %d", p ? p->getPlayerName().c_str() : "none", s.troops, s.raised,
					  s.battalions, s.heroes);
		out += b;
	}
	std::snprintf(b, sizeof(b), " | siege idle %d approach %d lowering %d deployed %d raising %d", deploys[0], deploys[1], deploys[2], deploys[3],
				  deploys[4]);
	out += b;
	out += " | gates" + (gates.empty() ? std::string(" whole") : gates) + " | walls" + (walls.empty() ? std::string(" whole") : walls);
	std::string counters;
	for (const auto &[key, c] : logic.scriptEngine().allCounters())
	{
		counters += " " + key.second + "=" + std::to_string(c.value);
	}
	if (!counters.empty())
	{
		out += " | counters" + counters;
	}
	return out + watched;
}
