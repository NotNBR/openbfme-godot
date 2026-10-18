// OpenBFME unit tests, lane SIEGE-1: the survey of the retail siege units against Helm's Deep's gate and walls. GPL-3.0.
//
// A diagnostic, not a pin: every retail siege unit is made outside Helm's Deep's fortress (the computer player owns the fortress, the human is Mordor at
// start 1), ordered to attack the main gate and then a wall section, and the frames until its first damage, the damage after 120 s and where it stopped are
// printed. Run with `--no-skip -tc="siege1 survey*"`; it is skipped by default (about 10 s per unit and target). SKIPs loudly without the installs.

#include "doctest.h"

#include "StartTestUtil.h"

#include "Common/Player.h"
#include "Common/PlayerList.h"
#include "Common/PlayerTemplate.h"
#include "Common/Thing/ThingTemplate.h"
#include "GameClient/GUI/Skirmish/IniSkirmishSetupSource.h"
#include "GameClient/LiveGame.h"
#include "GameLogic/Combat/ObjectWeapons.h"
#include "GameLogic/System/ShroudManager.h"
#include "GameEngineDevice/Win32Device/Common/Win32BIGFileSystem.h"
#include "GameLogic/AI/AIWorld.h"
#include "GameLogic/Map/TerrainLogic.h"
#include "GameLogic/Module/AIUpdate.h"
#include "GameLogic/NewGame/NewGame.h"
#include "GameLogic/Object/Object.h"
#include "Libraries/WWVegas/WW3D2/assetmgr.h"

#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

using namespace starttest;

namespace
{
int surveyTemplateIndex(Shared &s, const std::string &name)
{
	for (int i = 0; i < s.world->playerTemplates().getPlayerTemplateCount(); ++i)
	{
		const PlayerTemplate *pt = s.world->playerTemplates().getNthPlayerTemplate(i);
		if (pt && pt->getName() == name)
		{
			return i;
		}
	}
	return -1;
}

// slot 0: the computer at start 0 (the fortress, Men), slot 1: the human at start 1 (Mordor)
NewGameMessage surveyMessage(Shared &s)
{
	NewGameMessage m;
	m.game.mapName = "maps/map wor helms deep/map wor helms deep.map";
	m.game.seed = 9;
	m.game.startingCash = 1000;
	const char *factions[2] = { "FactionMen", "FactionMordor" };
	for (int i = 0; i < 2; ++i)
	{
		SkirmishGameSlot &sl = m.game.slots[i];
		sl.state = i == 0 ? SLOT_EASY_AI : SLOT_PLAYER;
		sl.name = i == 0 ? u"Easy" : u"Host";
		sl.accepted = true;
		sl.playerTemplate = surveyTemplateIndex(s, factions[i]);
		REQUIRE(sl.playerTemplate >= 0); // tolerance: the index of a found template (-1: not found)
		sl.startPos = i;
		sl.color = i;
	}
	return m;
}

struct SurveyGame
{
	Shared &s;
	NewGameStart start{ RandomAlgorithm::ZH_CarryChain };
	ArchiveW3DFileSource source;
	WW3DAssetManager assets;
	std::unique_ptr<LiveGame> game;
	explicit SurveyGame(Shared &sh) : s(sh), source(*sh.mount->fs), assets(source)
	{
		std::string error;
		static std::vector<MapCacheEntry> cache;
		if (cache.empty())
		{
			REQUIRE_MESSAGE(IniSkirmishSetupSource::loadMapCache(*s.mount->fs, cache, &error), error);
		}
		REQUIRE_MESSAGE(NewGame::prepareNewGame(surveyMessage(s), s.world->playerTemplates(), s.settings, cache, RandomAlgorithm::ZH_CarryChain, start, &error), error);
		game = std::make_unique<LiveGame>(*s.world, *s.mount->fs, assets, s.options);
		LiveGame::Options o;
		o.start = &start;
		REQUIRE_MESSAGE(game->load(o, &error), error);
	}
	void frames(int n)
	{
		for (int i = 0; i < n; ++i)
		{
			game->advance(0.2);
		}
	}
	Object *named(const std::string &name)
	{
		for (Object *o = game->logic().getFirstObject(); o; o = o->getNextObject())
		{
			if (o->getName() == name)
			{
				return o;
			}
		}
		return nullptr;
	}
	Player *human()
	{
		for (int i = 0; i < game->players().getPlayerCount(); ++i)
		{
			Player *p = game->players().getNthPlayer(i);
			if (p && p->getPlayerType() == PLAYER_HUMAN)
			{
				return p;
			}
		}
		return nullptr;
	}
};

float healthOf(const Object *o)
{
	return o && o->getBodyModule() ? o->getBodyModule()->getHealth() : -1.0f;
}

float dist2(const Coord3D &a, const Coord3D &b)
{
	const float dx = a.x - b.x, dy = a.y - b.y;
	return std::sqrt(dx * dx + dy * dy);
}

// one unit against one target: made `d` outside the target (toward the human's start), ordered to attack it for `frames` frames
void surveyOne(Shared &s, const std::string &unit, bool wall, float d)
{
	SurveyGame g(s);
	g.frames(2);
	Object *gate = g.named("Main Gate");
	REQUIRE(gate);
	Player *me = g.human();
	REQUIRE(me);
	g.game->shroud().revealMapForPlayerPermanently(me->getPlayerIndex()); // an order may not target a fogged object (S-565): the survey sees everything
	const Waypoint *w = g.game->logic().terrain()->findWaypointByName("Player_2_Start");
	REQUIRE(w);
	Object *target = gate;
	if (wall)
	{
		// the wall section nearest the gate that is no gate
		float best = 1e9f;
		for (Object *o = g.game->logic().getFirstObject(); o; o = o->getNextObject())
		{
			if (o != gate && o->isKindOfName("WALK_ON_TOP_OF_WALL") && !o->isKindOfName("BLOCKING_GATE") && o->getBodyModule())
			{
				const float dd = dist2(*o->getPosition(), *gate->getPosition());
				if (dd < best && dd > 50.0f)
				{
					best = dd;
					target = o;
				}
			}
		}
	}
	const Coord3D tp = *target->getPosition();
	float dx = w->location.x - tp.x, dy = w->location.y - tp.y;
	const float len = std::sqrt(dx * dx + dy * dy);
	dx /= len;
	dy /= len;
	const Coord3D at{ tp.x + dx * d, tp.y + dy * d, 0.0f };
	std::string error;
	Object *o = g.game->createObject(unit, me->getPlayerIndex(), at, 0.0f, &error);
	REQUIRE_MESSAGE(o, error);
	g.frames(5);
	AIUpdateInterface *ai = o->getAIUpdateInterface();
	const float h0 = healthOf(target);
	const bool ordered = ai && ai->aiAttackObject(target, CMD_FROM_PLAYER);
	int firstHit = -1, slotAtHit = -1;
	float distAtHit = -1.0f;
	const ObjectID tid = target->getID();
	for (int f = 0; f < 600; ++f)
	{
		g.frames(1);
		Object *t = g.game->logic().findObjectByID(tid);
		if (firstHit < 0 && (!t || healthOf(t) < h0))
		{
			firstHit = f;
			distAtHit = dist2(*o->getPosition(), tp);
			if (o->getWeapons())
			{
				o->getWeapons()->currentWeapon(&slotAtHit);
			}
		}
	}
	Object *t = g.game->logic().findObjectByID(tid);
	const float h1 = t ? healthOf(t) : 0.0f;
	const std::string dead = t && t->isEffectivelyDead() ? " (dead)" : "";
	const std::string victim = ai && ai->currentVictim() ? ai->currentVictim()->getTemplate()->getName() : std::string("none");
	MESSAGE(unit << " vs " << target->getTemplate()->getName() << (wall ? " (wall)" : " (gate)") << ": ordered " << ordered << ", first damage at frame " << firstHit
				  << " from " << distAtHit << " with slot " << slotAtHit << ", health " << h0 << " -> " << h1 << dead << ", unit now " << dist2(*o->getPosition(), tp)
				  << " from it, victim " << victim);
}
} // namespace

TEST_CASE("siege1 survey: every retail siege unit against Helm's Deep's main gate and a wall section (diagnostic)" * doctest::skip(true))
{
	OPENBFME_REQUIRE_START(s);
	const struct
	{
		const char *name;
		float d;
	} units[] = {
		{ "IsengardBatteringRam", 250.0f }, { "MordorBatteringRam", 250.0f }, { "DwarvenDemolisher", 250.0f }, { "MordorGrond", 300.0f },
		{ "GondorTrebuchet", 500.0f },      { "ArnorTrebuchet", 500.0f },     { "MordorCatapult", 500.0f },    { "IsengardBallista", 400.0f },
		{ "DwarvenCatapult", 500.0f },      { "AngmarTrollSling", 500.0f },   { "MordorMumakil", 300.0f },     { "RohanEntBase", 250.0f },
		{ "WildMountainGiant", 250.0f },    { "MordorAttackTroll", 250.0f },  { "IsengardSiegeLadder", 250.0f }, { "MordorSiegeTower", 300.0f },
	};
	for (const auto &u : units)
	{
		surveyOne(*s, u.name, false, u.d);
		surveyOne(*s, u.name, true, u.d);
	}
}

TEST_CASE("siege1 survey: a battering ram's approach to Helm's Deep's main gate, traced (diagnostic)" * doctest::skip(true))
{
	OPENBFME_REQUIRE_START(s);
	SurveyGame g(*s);
	g.frames(2);
	Object *gate = g.named("Main Gate");
	REQUIRE(gate);
	Player *me = g.human();
	REQUIRE(me);
	g.game->shroud().revealMapForPlayerPermanently(me->getPlayerIndex());
	const Waypoint *w = g.game->logic().terrain()->findWaypointByName("Player_2_Start");
	REQUIRE(w);
	const Coord3D tp = *gate->getPosition();
	float dx = w->location.x - tp.x, dy = w->location.y - tp.y;
	const float len = std::sqrt(dx * dx + dy * dy);
	dx /= len;
	dy /= len;
	std::string error;
	Object *o = g.game->createObject("IsengardBatteringRam", me->getPlayerIndex(), Coord3D{ tp.x + dx * 250.0f, tp.y + dy * 250.0f, 0.0f }, 0.0f, &error);
	REQUIRE_MESSAGE(o, error);
	g.frames(5);
	AIUpdateInterface *ai = o->getAIUpdateInterface();
	REQUIRE(ai);
	REQUIRE(ai->aiAttackObject(gate, CMD_FROM_PLAYER));
	const float h0 = healthOf(gate);
	MESSAGE("gate at " << tp.x << ", " << tp.y << "; ram from " << o->getPosition()->x << ", " << o->getPosition()->y);
	for (int f = 0; f < 300; f += 5)
	{
		g.frames(5);
		int slot = -1;
		if (o->getWeapons())
		{
			o->getWeapons()->currentWeapon(&slot);
		}
		MESSAGE("frame " << f + 5 << ": ram at " << o->getPosition()->x << ", " << o->getPosition()->y << " (" << dist2(*o->getPosition(), tp) << " from the gate), state "
						 << ai->currentStateId() << ", moving " << ai->isMoving() << ", slot " << slot << ", gate health " << healthOf(gate) << " / " << h0);
		if (healthOf(gate) < h0)
		{
			break;
		}
	}
}
