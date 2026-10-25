// OpenBFME. GPL-3.0.
// See GameLogic/SkirmishAI/AIUpgrade.h for the RW facts and what is inference.

#include "GameLogic/SkirmishAI/AIUpgrade.h"

#include "Common/BuildAssistant.h"
#include "Common/Player.h"
#include "Common/StateHash.h"
#include "Common/Thing/ThingFactory.h"
#include "Common/Thing/ThingTemplate.h"
#include "Common/Upgrade.h"
#include "GameClient/ControlBarCommands.h"
#include "GameLogic/AI/AICommandSink.h"
#include "GameLogic/Combat/CombatNames.h"
#include "GameLogic/Construction.h"
#include "GameLogic/ConstructionSite.h"
#include "Common/PlayerList.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Module/AIUpdate.h"
#include "GameLogic/Module/CastleModules.h"
#include "GameLogic/Module/ConstructionModules.h"
#include "GameLogic/Module/ProductionUpdate.h"
#include "GameLogic/Object/Object.h"
#include "GameLogic/ObjectTemplateInfo.h"
#include "GameLogic/SimMath.h"
#include "GameLogic/SkirmishAI/AIBaseBuilder.h"
#include "GameLogic/SkirmishAI/AIStatCollector.h"
#include "GameLogic/SkirmishAI/AITacticalAI.h"
#include "GameLogic/SkirmishAI/SkirmishAIData.h"
#include "GameLogic/SkirmishAI/SkirmishAIManager.h"

#include <algorithm>

namespace
{
const char *const kUnitUpgraderFile = "AIUnitUpgrader.cpp";           // RW 0xC882B0
const char *const kScienceBuilderFile = "AIUpgradeScienceBuilder.cpp"; // RW 0xC88170
const char *const kExpansionFile = "AIExpansionScience.cpp";          // RW 0xC8EB40
const char *const kFortressFile = "AIUpgradeHeuristicFortress.cpp";    // RW 0xC8EA68

const char *const kStopSummon =
	"[S-1876] skirmish AI upgrade heuristics (lane AI5): SUMMON_ANTICAVALRY / ANTIARCHER / ANTISPECIAL / ANTIINFANTRY (RW 0x9ECF7F / 0x9ECC0D / 0x9EC8A1 / "
	"0x9EC539: the army trackers AI + 0x164 -> + 0x20, the threat finder and their GetGameLogicRandomValueReal draws) are not ported: they answer 3 (never "
	"bought) and are counted; retail data uses them only for the four Thrall Master summon upgrades";
const char *const kStopWallUpgrade =
	"[S-1876] skirmish AI upgrade legality (lane AI5): RW 0x695338's WALL_UPGRADE test (Object + 0x25C vslot 0x24 == 3) is not read; such an object is "
	"refused (9) and counted";

constexpr unsigned kButtons = 33;                       // RW 0x9A018B / 0x9A155C / 0x9ED4D2: buttons 0 .. 0x20
constexpr float kPriorityNone = -1.0f;                  // RW 0xBD19DC
constexpr float kPriorityWithHeuristic = 9999.0f;       // RW 0xC18414
constexpr std::uint32_t kExpansionDelay = 60 * LOGICFRAMES_PER_SECOND; // RW 0xDEBE48 (RW 0xBC97A2)

const CommandButton *buttonOf(const AIBuildRequest &r)
{
	return TheCommandStore && !r.buttonName.empty() ? TheCommandStore->findCommandButton(r.buttonName) : nullptr;
}

const UpgradeTemplate *upgradeOf(const CommandButton *b)
{
	return b && TheUpgradeCenter && !b->m_upgradeName.empty() ? TheUpgradeCenter->findUpgrade(b->m_upgradeName) : nullptr;
}

const CommandSet *commandSetOf(const Object &obj)
{
	// RW 0x69156B -> 0x71EFA2
	return TheCommandStore ? TheCommandStore->findCommandSet(obj.getCommandSetName()) : nullptr;
}

bool templateIs(GameLogic &logic, const ThingTemplate &tt, const char *kind)
{
	const int bit = ObjectTemplateInfoBuilder::kindOfIndex(kind);
	return bit >= 0 && MaskTest(logic.templateInfo(tt.getFinalOverride()).kindOf, (unsigned)bit);
}

bool objectIs(const Object &obj, const char *kind)
{
	return obj.isKindOfName(kind);
}

const AISkirmishPlayer *aiOf(GameLogic &logic, const Player *p)
{
	return p ? logic.skirmishAI().findAI(p->getPlayerIndex()) : nullptr; // RW 0x6A950B
}

// RW 0x9618BA(owner, 0) -> RW 0x8F0B92: state 0, the pending queue
void submit(AISkirmishPlayer &ai, const std::shared_ptr<AIBuildRequest> &r)
{
	r->state = 0;
	ai.build.pending.push_back(r);
}

// RW 0x9618E3 -> RW 0x8F0602: every entry of the request leaves the pending and the in-progress queues
void leaveQueues(AISkirmishPlayer &ai, const AIBuildRequest *r)
{
	auto &p = ai.build.pending;
	p.erase(std::remove_if(p.begin(), p.end(), [r](const std::shared_ptr<AIBuildRequest> &q) { return q.get() == r; }), p.end());
	auto &g = ai.build.inProgress;
	g.erase(std::remove_if(g.begin(), g.end(), [r](const std::shared_ptr<AIBuildRequest> &q) { return q.get() == r; }), g.end());
}

std::shared_ptr<AIBuildRequest> newRequest(AISkirmishPlayer &ai)
{
	auto r = std::make_shared<AIBuildRequest>();
	r->serial = ai.build.nextSerial++;
	r->requeueOnProducerDeath = true; // the base ctor RW 0x961B48: + 0x20 = 1, + 0x21 = 0, + 0x28 = 1
	return r;
}

// RW 0x99F83D: an upgrade in progress (state >= 1) is done when its object is gone or its production no longer queues the upgrade (a missing production reads
// as done: RW would call through a null interface)
bool upgradeDone(GameLogic &logic, const AIBuildRequest &r)
{
	if (r.state < 1)
	{
		return false;
	}
	const Object *obj = logic.findObjectByID(r.producer);
	if (!obj)
	{
		return true;
	}
	const ProductionUpdateInterface *pu = obj->getProductionUpdate();
	return !pu || !pu->isUpgradeInQueue(upgradeOf(buttonOf(r))); // slot 6
}

// RW 0x99FA40
void completeIfDone(GameLogic &logic, AIBuildRequest &r)
{
	if (upgradeDone(logic, r))
	{
		r.state = 2; // vslot 0x1C(2) (RW 0x993D2E)
	}
}

// RW 0x99FAA6: the walls' KindOf (bits 60 61 150 156 189 201 203)
bool excludedFromScienceBuilder(const Object &obj)
{
	static const char *const kinds[] = { "WALK_ON_TOP_OF_WALL", "DEFENSIVE_WALL", "WALL_UPGRADE", "WALL_HUB", "WALL_SEGMENT", "SCALEABLE_WALL", "WALL_GATE" };
	for (const char *k : kinds)
	{
		if (objectIs(obj, k))
		{
			return true;
		}
	}
	return false;
}

// RW 0x99F4D6 / 0x9EDD1C filled as RW 0x9A018B / 0x9A155C do
std::shared_ptr<AIBuildRequest> makeUpgradeRequest(GameLogic &logic, AISkirmishPlayer &ai, const Object &obj, const CommandButton &b, const UpgradeTemplate &u,
	const Player &owner)
{
	auto r = newRequest(ai);
	r->upgrade = true;
	r->cost = u.calcCostToBuild(&owner, &obj); // RW 0x66F2C8
	r->producer = obj.getID();                 // + 8
	r->buttonName = b.m_name;                  // + 0x30
	r->templateName = u.getUpgradeName();      // + 0xC
	(void)logic;
	return r;
}

// the object's player for the record events: the AI's own player (the listeners belong to its record)
Player *ownerOf(GameLogic &logic, const AISkirmishPlayer &ai)
{
	return logic.players().getNthPlayer(ai.playerIndex);
}

// RW 0x9A155C
void registerUnitUpgrades(GameLogic &logic, AISkirmishPlayer &ai, Object &obj)
{
	AIUnitUpgraderState &u = ai.build.unitUpgrader;
	Player *owner = ownerOf(logic, ai);
	const CommandSet *set = commandSetOf(obj);
	if (!set || !owner || !ai.army)
	{
		return; // RW: no set, nothing; every started AI has an army (RW 0x9A0383; the port's guard)
	}
	for (unsigned i = 0; i < kButtons; ++i)
	{
		const CommandButton *b = set->getCommandButton((int)i);
		const UpgradeTemplate *up = upgradeOf(b);
		if (!b || !up)
		{
			continue;
		}
		auto r = makeUpgradeRequest(logic, ai, obj, *b, *up, *owner);
		// AIUnitUpgrader.cpp 0x5D: GetGameLogicRandomValue(Low, High) of the cvttss2si of + 0xE4 / + 0xE8 (RW 0x9A161E / 0x9A1626), stored as a float (cvtsi2ss)
		r->priority = (float)logic.random().getValue(SimMath::cvttss2si(ai.army->unitUpgradePriorityLow), SimMath::cvttss2si(ai.army->unitUpgradePriorityHigh),
			kUnitUpgraderFile, 0x5D);
		AIUpgrade::makeHeuristic(logic, *r, up->m_skirmishAIHeuristic); // RW 0x9EDDAE
		if (up->m_skirmishAIHeuristic != -1)
		{
			r->priority = kPriorityWithHeuristic;
		}
		u.waiting.push_back(r);
		++u.registered;
	}
}

// RW 0x9A018B
void registerScienceUpgrades(GameLogic &logic, AISkirmishPlayer &ai, Object &obj)
{
	AIUpgradeScienceBuilderState &s = ai.build.scienceBuilder;
	if (excludedFromScienceBuilder(obj))
	{
		return;
	}
	const CommandSet *set = commandSetOf(obj);
	if (0.0f <= obj.getConstructionPercent())
	{
		s.pendingStructures.push_back(obj.getID()); // RW 0x5487BB: under construction, registered again by RW 0x99FCC4
		return;
	}
	Player *owner = ownerOf(logic, ai);
	if (!set || !owner)
	{
		return;
	}
	for (unsigned i = 0; i < kButtons; ++i)
	{
		const CommandButton *b = set->getCommandButton((int)i);
		if (!b)
		{
			continue;
		}
		const UpgradeTemplate *up = upgradeOf(b);
		if (!up)
		{
			const ThingTemplate *tt = b->getThingTemplate(); // RW 0x75D1DC
			if (b->m_command == GUI_COMMAND_FOUNDATION_CONSTRUCT && tt && !templateIs(logic, *tt, "WALL_HUB") && !templateIs(logic, *tt, "GARRISON"))
			{
				auto r = newRequest(ai); // RW 0x9ED687
				r->expansion = true;
				r->buttonName = b->m_name;                     // + 0x40
				r->templateName = tt->getFinalOverride()->getName(); // + 0xC (template + 0x64)
				r->priority = kPriorityNone;                   // + 4
				r->offset = *obj.getPosition();               // + 0x30 .. + 0x38
				r->angle = obj.getOrientation();               // + 0x3C (object + 0x44)
				r->producer = obj.getID();                     // + 8
				r->reserveMoney = true;                        // + 0x21
				s.expansions.push_back(r);
				++s.registered;
			}
			continue;
		}
		auto r = makeUpgradeRequest(logic, ai, obj, *b, *up, *owner);
		r->reserveMoney = true;                                 // + 0x21
		AIUpgrade::makeHeuristic(logic, *r, up->m_skirmishAIHeuristic); // RW 0x99F52F
		s.upgrades.push_back(r);
		++s.registered;
	}
}

// RW 0x9A135B
void unRegisterUnitUpgrades(AISkirmishPlayer &ai, const Object &obj)
{
	AIUnitUpgraderState &u = ai.build.unitUpgrader;
	const ObjectID id = obj.getID();
	u.waiting.erase(std::remove_if(u.waiting.begin(), u.waiting.end(), [id](const std::shared_ptr<AIBuildRequest> &r) { return r->producer == id; }), u.waiting.end());
	for (auto it = u.upgrading.begin(); it != u.upgrading.end();)
	{
		if ((*it)->producer == id)
		{
			leaveQueues(ai, it->get());
			it = u.upgrading.erase(it);
		}
		else
		{
			++it;
		}
	}
}

// RW 0x99FC0C
void unRegisterScienceUpgrades(GameLogic &logic, AISkirmishPlayer &ai, const Object &obj)
{
	AIUpgradeScienceBuilderState &s = ai.build.scienceBuilder;
	const ObjectID id = obj.getID();
	for (auto it = s.upgrades.begin(); it != s.upgrades.end();)
	{
		// RW 0x99FC21: TheGameLogic's object of the record's id is the object
		if (logic.findObjectByID((*it)->producer) == &obj)
		{
			if ((*it)->upgrading)
			{
				leaveQueues(ai, it->get());
			}
			it = s.upgrades.erase(it);
		}
		else
		{
			++it;
		}
	}
	for (auto it = s.expansions.begin(); it != s.expansions.end();)
	{
		AIBuildRequest &r = **it;
		if (r.producer == id)
		{
			if (r.expansionDone)
			{
				leaveQueues(ai, &r);
			}
			it = s.expansions.erase(it);
			continue;
		}
		if (r.built == id)
		{
			leaveQueues(ai, &r); // RW 0x99FCA9
			r.built = INVALID_ID;
			r.expansionDone = false;
		}
		++it;
	}
}

// RW 0x99FDDE: the first record with the result `want` (2, then 1) that is not upgrading and legal; every record is evaluated on the way
std::shared_ptr<AIBuildRequest> forcedUpgrade(GameLogic &logic, AISkirmishPlayer &ai, Player &owner)
{
	for (int want : { 2, 1 })
	{
		for (const auto &r : ai.build.scienceBuilder.upgrades)
		{
			if (AIUpgrade::evaluate(logic, *r, owner) == want && !r->upgrading)
			{
				const Object *obj = logic.findObjectByID(r->producer);
				if (obj && AIUpgrade::legality(logic, *obj, buttonOf(*r)) == 0)
				{
					return r;
				}
			}
		}
	}
	return nullptr;
}

// RW 0x99FE74
void buildNormalUpgrades(GameLogic &logic, AISkirmishPlayer &ai, Player &owner)
{
	AIUpgradeScienceBuilderState &s = ai.build.scienceBuilder;
	unsigned count = 0;
	for (const auto &r : s.upgrades)
	{
		count += (!r->finished() && r->upgrading) ? 1u : 0u;
	}
	unsigned limit = 0;
	if (ai.build.phase == 1)
	{
		limit = 1;
	}
	else if (ai.build.phase == 2)
	{
		limit = 3;
	}
	else
	{
		return;
	}
	if (limit <= count)
	{
		return;
	}
	const float factor = (float)(count + 1); // cvtsi2ss of the unsigned (+ 2^32 when negative, RW 0xBD8698: never here)
	const std::uint32_t money = owner.getMoney()->countMoney(); // Player + 0x94, read once
	std::shared_ptr<AIBuildRequest> pick = forcedUpgrade(logic, ai, owner);
	if (!pick)
	{
		for (const auto &r : s.upgrades)
		{
			if (r->upgrading)
			{
				continue;
			}
			const Object *obj = logic.findObjectByID(r->producer);
			if (!obj || AIUpgrade::legality(logic, *obj, buttonOf(*r)) != 0 || (pick && !(r->cost < pick->cost)))
			{
				continue;
			}
			// (float)cost * factor <= (float)money (the money's fild with the unsigned correction), x87 at PC24, then the evaluation
			if (SimMath::mulf32((float)r->cost, factor) <= (float)money && AIUpgrade::evaluate(logic, *r, owner) != 3)
			{
				pick = r;
			}
		}
		if (!pick)
		{
			return;
		}
	}
	const int result = pick->heuristicResult;
	pick->upgrading = true;
	if (result == 0)
	{
		pick->priority = logic.random().getValueReal(ai.army->upgradeSciencePriorityNormalLow, ai.army->upgradeSciencePriorityNormalHigh, kScienceBuilderFile, 0x18C);
	}
	else if (result == 1)
	{
		pick->priority = logic.random().getValueReal(ai.army->upgradeSciencePriorityImportantLow, ai.army->upgradeSciencePriorityImportantHigh, kScienceBuilderFile, 0x18F);
	}
	else if (result == 2)
	{
		pick->priority = kPriorityNone;
	}
	submit(ai, pick);
	++s.upgradesSubmitted;
}

// RW 0x99FAEF
void buildExpansionUpgrades(GameLogic &logic, AISkirmishPlayer &ai, Player &owner)
{
	AIUpgradeScienceBuilderState &s = ai.build.scienceBuilder;
	if (s.expansions.empty() || (std::uint32_t)(logic.getFrame() - s.lastExpansionFrame) < kExpansionDelay || ai.build.phase <= 0)
	{
		return;
	}
	const int i = logic.random().getValue(0, (int)s.expansions.size() - 1, kScienceBuilderFile, 0x1A2);
	const std::shared_ptr<AIBuildRequest> r = s.expansions[(size_t)i];
	if (r && !r->expansionDone && AIUpgrade::check(logic, ai, *r, owner) == 0) // vslot 0x40 (RW 0x9ED764), not the reserve wrapper RW 0x961975
	{
		submit(ai, r);
		r->expansionDone = true;
		s.lastExpansionFrame = logic.getFrame();
		++s.expansionsSubmitted;
	}
}

// RW 0x9ED374: the FORTRESS heuristic
int evaluateFortress(GameLogic &logic, AIBuildRequest &r, Player &player)
{
	const AISkirmishPlayer *ai = aiOf(logic, &player);
	const int phase = ai ? ai->build.phase : 0;
	if (phase <= 0)
	{
		return r.heuristicFortressResult;
	}
	const std::uint32_t frame = logic.getFrame();
	if (r.heuristicNextFrame != 0xFFFFFFFFu && r.heuristicNextFrame > frame)
	{
		return r.heuristicFortressResult;
	}
	int seconds = (7 - phase) * 5;
	if (player.getSkirmishDifficulty() > 1) // RW 0x6AA61B
	{
		seconds -= 5;
	}
	r.heuristicNextFrame = frame + (std::uint32_t)(LOGICFRAMES_PER_SECOND * seconds);
	static const int dozerFactory = ObjectTemplateInfoBuilder::kindOfIndex("DOZER_FACTORY");
	for (ObjectID id : AITacticalAI::recordOf(logic, player.getPlayerIndex()).structures()) // record + 8 -> + 4 (RW 0x72B229)
	{
		const Object *o = logic.findObjectByID(id);
		if (!o || dozerFactory < 0 || !o->isKindOf((unsigned)dozerFactory)) // template + 0x120 bit 2
		{
			continue;
		}
		// record + 0xC (RW 0x99E766: money + reserve, an unsigned compare with 2000)
		const std::uint32_t money = (std::uint32_t)AIBaseBuilder::moneyPlusReserve(logic, player);
		const int draw = money > 2000 ? logic.random().getValue(1, 5, kFortressFile, 0x4F) : logic.random().getValue(1, 10, kFortressFile, 0x58);
		if (draw == 1)
		{
			r.heuristicFortressResult = 0;
		}
		break;
	}
	return r.heuristicFortressResult;
}

// RW 0x9ED45E: the FACTORY_UNITUNLOCK heuristic
int evaluateUnitUnlock(GameLogic &logic, const AIBuildRequest &r)
{
	const Object *obj = logic.findObjectByID(r.producer);
	const AISkirmishPlayer *ai = obj ? aiOf(logic, obj->getControllingPlayer()) : nullptr;
	if (!ai || !ai->army)
	{
		return 0; // RW reads through a null object / AI here (a crash); the records leave before their object does (UnRegister)
	}
	for (const std::string &name : r.heuristicUnlocks)
	{
		for (const ArmyMemberDefinition &m : ai->army->members) // RW 0x82FE4C: the first member of that unit name (StringBase::compare)
		{
			if (m.unit == name)
			{
				const int phase = ai->build.phase;
				const float pct = m.percentageOfArmy[phase == 0 ? 0 : phase == 1 ? 1 : 2]; // RW 0x82FC8F
				if (pct > 0.0f) // comiss with RW 0xC1B594 (0.0f), ja
				{
					return 1;
				}
				break;
			}
		}
	}
	return 0;
}
} // namespace

void AIUpgrade::init(AISkirmishPlayer &ai, const SkirmishAIData &data)
{
	ai.build.unitUpgrader.listening = true;  // RW 0x9A1340
	ai.build.scienceBuilder.listening = true; // RW 0x8EE74A
	ai.build.unitUpgrader.disabled = data.disableUnitUpgrading;     // RW 0x8F02CC: + 0x968 -> + 0x10C
	ai.build.scienceBuilder.disabled = data.disableScienceUpgrading; // + 0x967 -> (+ 0x12C) + 0x10
}

void AIUpgrade::onRegister(GameLogic &logic, AISkirmishPlayer &ai, Object &obj, unsigned lists)
{
	// RW 0x8E3D4C in the record's listener order (unit upgrader, then the upgrade builder); one object is in one list (the filters exclude each other)
	if ((lists & AIStatCollector::LISTEN_ARMY) && ai.build.unitUpgrader.listening)
	{
		registerUnitUpgrades(logic, ai, obj);
	}
	if ((lists & AIStatCollector::LISTEN_STRUCTURES) && ai.build.scienceBuilder.listening)
	{
		registerScienceUpgrades(logic, ai, obj);
	}
}

void AIUpgrade::onUnRegister(GameLogic &logic, AISkirmishPlayer &ai, Object &obj, unsigned lists)
{
	if ((lists & AIStatCollector::LISTEN_ARMY) && ai.build.unitUpgrader.listening)
	{
		unRegisterUnitUpgrades(ai, obj);
	}
	if ((lists & AIStatCollector::LISTEN_STRUCTURES) && ai.build.scienceBuilder.listening)
	{
		unRegisterScienceUpgrades(logic, ai, obj);
	}
}

void AIUpgrade::updateUnitUpgrader(GameLogic &logic, AISkirmishPlayer &ai, Player &player)
{
	// RW 0x9A1696
	AIUnitUpgraderState &u = ai.build.unitUpgrader;
	for (size_t i = 0; i < u.waiting.size();)
	{
		const std::shared_ptr<AIBuildRequest> r = u.waiting[i];
		const int result = evaluate(logic, *r, player);
		if (!(ai.build.phase > 0 || result == 2))
		{
			++i;
			continue;
		}
		if (const Object *obj = logic.findObjectByID(r->producer))
		{
			if (legality(logic, *obj, buttonOf(*r)) != 0)
			{
				++i;
				continue;
			}
			bool declined = false;
			if (result != 2)
			{
				if (result == 3)
				{
					++i;
					continue;
				}
				const float draw = logic.random().getValueReal(0.0f, 1.0f, kUnitUpgraderFile, 0xB4);
				declined = ai.army && ai.army->chanceForUnitsToUpgrade < draw; // ArmyDefinition + 0xD0
			}
			if (declined)
			{
				++u.declined;
			}
			else
			{
				submit(ai, r); // vslot 0x18(owner, 0)
				u.upgrading.push_back(r);
				++u.submitted;
			}
		}
		u.waiting.erase(u.waiting.begin() + (long)i); // RW 0x9A176F
	}
	for (auto it = u.upgrading.begin(); it != u.upgrading.end();)
	{
		if (!logic.findObjectByID((*it)->producer) || (*it)->finished())
		{
			leaveQueues(ai, it->get()); // RW 0x9618E3
			it = u.upgrading.erase(it);
		}
		else
		{
			++it;
		}
	}
	for (const auto &r : u.upgrading)
	{
		completeIfDone(logic, *r); // RW 0x99FA40
	}
}

void AIUpgrade::updateScienceBuilder(GameLogic &logic, AISkirmishPlayer &ai, Player &player)
{
	// RW 0x9A0023
	AIUpgradeScienceBuilderState &s = ai.build.scienceBuilder;
	// RW 0x99FCC4
	for (size_t i = 0; i < s.pendingStructures.size();)
	{
		Object *obj = logic.findObjectByID(s.pendingStructures[i]);
		if (obj && !(obj->getConstructionPercent() < 0.0f))
		{
			++i;
			continue;
		}
		const ObjectID id = s.pendingStructures[i];
		s.pendingStructures.erase(s.pendingStructures.begin() + (long)i);
		if (obj)
		{
			(void)id;
			registerScienceUpgrades(logic, ai, *obj); // vslot 0 (object, 1): finished, its records now
		}
	}
	// RW 0x99FD0E
	for (auto it = s.upgrades.begin(); it != s.upgrades.end();)
	{
		if (logic.findObjectByID((*it)->producer) && !(*it)->finished())
		{
			++it;
			continue;
		}
		if ((*it)->upgrading)
		{
			leaveQueues(ai, it->get());
		}
		it = s.upgrades.erase(it);
	}
	for (auto it = s.expansions.begin(); it != s.expansions.end();)
	{
		const Object *obj = logic.findObjectByID((*it)->producer);
		if (obj && !obj->isEffectivelyDead() && !(*it)->finished()) // + 0x458 bit 0
		{
			++it;
			continue;
		}
		if ((*it)->expansionDone)
		{
			leaveQueues(ai, it->get());
		}
		it = s.expansions.erase(it);
	}
	buildNormalUpgrades(logic, ai, player);    // RW 0x99FE74
	buildExpansionUpgrades(logic, ai, player); // RW 0x99FAEF
	for (const auto &r : s.upgrades)
	{
		if (r->upgrading)
		{
			completeIfDone(logic, *r); // RW 0x99FA40
		}
	}
}

int AIUpgrade::legality(GameLogic &logic, const Object &obj, const CommandButton *button)
{
	// RW 0x695338
	const UpgradeTemplate *u = upgradeOf(button);
	const ProductionUpdateInterface *pu = u ? obj.getProductionUpdate() : nullptr;
	if (!u || !pu || pu->isFactoryDisabled()) // slot 25
	{
		return 9;
	}
	if (objectIs(obj, "WALL_UPGRADE"))
	{
		logic.noteStop(kStopWallUpgrade);
		return 9;
	}
	if (u->getUpgradeType() == UPGRADE_TYPE_OBJECT && (obj.hasUpgrade(u) || !obj.affectedByUpgrade(u))) // RW 0x691421 / 0x694914
	{
		return 9;
	}
	const Player *player = obj.getControllingPlayer(); // RW 0x68B678
	if (!player)
	{
		return 0;
	}
	if (player->getPlayerType() != PLAYER_HUMAN && !aiOf(logic, player))
	{
		return 0; // + 0x5C != 0 without a skirmish AI (RW 0x695457)
	}
	if (!button->hasOption(COMMAND_OPTION_NEED_UPGRADE)) // + 0x1C & 0x40
	{
		return 0;
	}
	const bool any = button->m_neededUpgradeAny; // + 0x34
	bool refuse = any;
	for (const std::string &name : button->m_neededUpgrade) // + 0x28
	{
		const UpgradeTemplate *need = TheUpgradeCenter ? TheUpgradeCenter->findUpgrade(name) : nullptr;
		if (!need)
		{
			continue; // a null entry
		}
		if (need->getUpgradeType() == UPGRADE_TYPE_PLAYER)
		{
			const bool have = player->hasUpgradeComplete(need); // RW 0x6AC2AF
			if (!any && !have)
			{
				return 9;
			}
			if (any && have)
			{
				return 0;
			}
		}
		else
		{
			const bool have = obj.hasUpgrade(need); // RW 0x691421
			if (!any && !have)
			{
				refuse = true;
			}
			else if (any && have)
			{
				refuse = false;
				break;
			}
		}
	}
	return refuse ? 9 : 0;
}

void AIUpgrade::makeHeuristic(GameLogic &logic, AIBuildRequest &r, int type)
{
	// RW 0x9EDDAE / 0x99F52F: the old heuristic goes (RW 0x9EDD52), the new one is made, + 0x3C = the type
	r.heuristicType = type;
	r.heuristicNextFrame = 0xFFFFFFFFu;
	r.heuristicFortressResult = 3;
	r.heuristicUnlocks.clear();
	if (type != HEURISTIC_FACTORY_UNITUNLOCK)
	{
		return;
	}
	// RW 0x9ED4D2: the templates of the object's UNIT_BUILD / SECONDARY_UNIT_BUILD buttons that name this upgrade in their NeededUpgrade list
	const Object *obj = logic.findObjectByID(r.producer);
	const UpgradeTemplate *own = upgradeOf(buttonOf(r));
	const CommandSet *set = obj ? commandSetOf(*obj) : nullptr;
	if (!set || !own)
	{
		return;
	}
	for (unsigned i = 0; i < kButtons; ++i)
	{
		const CommandButton *b = set->getCommandButton((int)i);
		if (!b || (b->m_command != GUI_COMMAND_UNIT_BUILD && b->m_command != GUI_COMMAND_SECONDARY_UNIT_BUILD))
		{
			continue;
		}
		for (const std::string &name : b->m_neededUpgrade)
		{
			const UpgradeTemplate *need = TheUpgradeCenter ? TheUpgradeCenter->findUpgrade(name) : nullptr;
			if (need && need == own) // + 0xC equal: the same upgrade
			{
				const ThingTemplate *tt = b->getThingTemplate(); // RW 0x75D1DC
				r.heuristicUnlocks.push_back(tt ? tt->getFinalOverride()->getName() : std::string());
				break;
			}
		}
	}
}

int AIUpgrade::evaluate(GameLogic &logic, AIBuildRequest &r, Player &player)
{
	// RW 0x9EDD3D: + 0x40 = heuristic vslot 0(player)
	int result = 1; // none (RW 0x9ED653)
	switch (r.heuristicType)
	{
	case HEURISTIC_NONE:
		result = 1;
		break;
	case HEURISTIC_IMPORTANT:
	case HEURISTIC_BOILINGOIL:
		result = 0; // RW 0x46C6BE
		break;
	case HEURISTIC_FACTORY_UNITUNLOCK:
		result = evaluateUnitUnlock(logic, r);
		break;
	case HEURISTIC_FORTRESS:
		result = evaluateFortress(logic, r, player);
		break;
	default:
		if (r.heuristicType >= HEURISTIC_SUMMON_ANTICAVALRY && r.heuristicType <= HEURISTIC_SUMMON_ANTIINFANTRY)
		{
			logic.noteStop(kStopSummon);
			result = 3;
		}
		else
		{
			result = 1; // RW 0x9EDDAE's default: the static of vtable RW 0xC8EAF0
		}
		break;
	}
	r.heuristicResult = result;
	return result;
}

int AIUpgrade::check(GameLogic &logic, AISkirmishPlayer &ai, AIBuildRequest &r, Player &player)
{
	if (r.upgrade)
	{
		// RW 0x99F88B
		if (player.getMoney()->countMoney() < (std::uint32_t)r.cost) // Player + 0x94 < + 0x2C (unsigned, jnc)
		{
			return 2;
		}
		const Object *obj = logic.findObjectByID(r.producer);
		const CommandButton *b = buttonOf(r);
		const ProductionUpdateInterface *pu = obj ? obj->getProductionUpdate() : nullptr;
		if (!obj || !pu || !b)
		{
			return 9;
		}
		if (pu->getProductionCount() != 0) // vslot 0x44
		{
			return 4;
		}
		return legality(logic, *obj, b);
	}
	// RW 0x9ED764
	const ThingTemplate *tt = logic.things().findTemplate(r.templateName);
	const Object *obj = logic.findObjectByID(r.producer);
	if (!tt || !obj || !BuildAssistant::playerAllowedToBuild(player, tt, logic)) // RW 0x6AC856
	{
		return 9;
	}
	const CommandButton *b = buttonOf(r);
	const ThingTemplate *bt = b ? b->getThingTemplate() : nullptr; // + 0x40 -> RW 0x75D1DC
	const int buildable = bt ? BuildAssistant::buildable(*bt) : 2;  // RW 0x73BFE8
	if (buildable == 2 || (buildable == 3 && (!obj->getControllingPlayer() || obj->getControllingPlayer()->getPlayerType() != PLAYER_COMPUTER)))
	{
		return 9;
	}
	bool plot = false;
	for (const std::unique_ptr<BehaviorModule> &m : obj->modules())
	{
		plot = plot || m->getFoundationAIUpdate() != nullptr; // RW 0x68C3C3
	}
	const CastleMemberBehavior *member = dynamic_cast<const CastleMemberBehavior *>(const_cast<Object *>(obj)->findModule("CastleMemberBehavior"));
	if (!plot || (member && member->occupantId() != INVALID_ID) || !BuildAssistant::playerCanBuild(player, tt, logic)) // slot 3 (S-952), RW 0x6AC927
	{
		return 9;
	}
	const std::uint32_t money = player.getMoney()->countMoney(); // read before the reserve deposit
	// RW 0x6AAA2E(template, 0) with the reserve deposited (RW 0x7B18B8) and withdrawn (RW 0x7B17EF) around it for + 0x21; the processor's check wrapper
	// RW 0x961975 has deposited it once already, so there the template is compared with money + 2 * reserve and the floor with money + reserve, as in RW
	AIStatCollector *rec = r.reserveMoney ? logic.skirmishAI().record(player.getPlayerIndex()) : nullptr;
	const std::uint32_t lent = rec ? rec->reserve() : 0u;
	if (lent != 0)
	{
		player.getMoney()->deposit(lent, nullptr, false);
	}
	const bool afford = (std::int64_t)BuildAssistant::calcCostToBuild(*tt, &player, nullptr, -1) <= (std::int64_t)(std::int32_t)player.getMoney()->countMoney();
	if (lent != 0)
	{
		player.getMoney()->withdraw(lent, nullptr, false);
	}
	const AIStatCollector &stats = AITacticalAI::recordOf(logic, player.getPlayerIndex());
	const int economy = (int)stats.economy().size(), army = (int)stats.army().size(); // RW 0x945ADA on + 0xC and + 0
	if (!afford)
	{
		return 2;
	}
	const int floor = logic.random().getValue(600, 1000, kExpansionFile, 0x5C);
	(void)ai;
	return ((std::int32_t)money >= floor && economy > 3 && army > 7) ? 0 : 2;
}

bool AIUpgrade::execute(GameLogic &logic, AISkirmishPlayer &ai, AIBuildRequest &r, Player &player)
{
	(void)ai;
	Object *obj = logic.findObjectByID(r.producer);
	// RW 0x8F0E6C: a garrisoned object with an AI leaves its container first (AI command 0x1A from source 0)
	if (obj && obj->testStatus((unsigned)CombatNames::statuses().insideGarrison) && obj->getAIUpdateInterface())
	{
		obj->getAIUpdateInterface()->aiExit(obj->getContainedBy(), CMD_FROM_PLAYER);
	}
	if (r.upgrade)
	{
		// RW 0x99F7EF: Object::doCommandButton(button, 1, 0) -> RW 0x696FD2 case 6 .. 8 (a disabled object does nothing, RW 0x9325B4; Object + 0xA0 bit 6 taken
		// as clear as in AISpecialPowerUpdate), then the production's isUpgradeInQueue (slot 6)
		const CommandButton *b = buttonOf(r);
		const UpgradeTemplate *u = upgradeOf(b);
		if (!obj || !b || !u)
		{
			return false;
		}
		ProductionUpdateInterface *pu = obj->getProductionUpdate();
		if (obj->getDisabledMask() == 0 && (b->m_command == GUI_COMMAND_PLAYER_UPGRADE || b->m_command == GUI_COMMAND_OBJECT_UPGRADE || b->m_command == GUI_COMMAND_CASTLE_UPGRADE) &&
			legality(logic, *obj, b) == 0 && pu)
		{
			pu->queueUpgrade(u); // slot 3
		}
		return pu && pu->isUpgradeInQueue(u);
	}
	// RW 0x9ED8C4: BuildAssistant slot 0x38 (RW 0x797796) on the plot: the site is prepared, then the plot's construct (BuildCommands::foundationConstruct's path)
	const ThingTemplate *tt = logic.things().findTemplate(r.templateName);
	if (!tt || !obj)
	{
		return false;
	}
	// RW 0x9ED8E1 .. 0x9ED951: the template's cost (vslot 0x44, RW 0x9ED6BF: calcCostToBuild(player, no producer)), ftol; with + 0x21, above 0 and within the
	// reserve it is drawn from the reserve (RW 0x99E79A)
	const int cost = BuildAssistant::calcCostToBuild(*tt->getFinalOverride(), &player, nullptr, -1);
	const AIStatCollector *rec = logic.skirmishAI().record(player.getPlayerIndex());
	if (r.reserveMoney && rec && cost > 0 && (std::uint32_t)cost <= rec->reserve())
	{
		AIBaseBuilder::withdrawFromReserve(logic, player, (std::uint32_t)cost);
	}
	FoundationAIUpdate *foundation = nullptr;
	for (const std::unique_ptr<BehaviorModule> &m : obj->modules())
	{
		if (FoundationAIUpdate *f = m->getFoundationAIUpdate())
		{
			foundation = f;
			break;
		}
	}
	if (!foundation)
	{
		return false;
	}
	// INFERENCE (Sol review r1): RW reads the plot's position and angle at its registration (+ 0x30 .. + 0x3C); the port's world entry event runs before the map
	// placement sets them (S-142's seam), so the registration saw (0, 0). A plot never moves: its position here is the one RW registered
	r.offset = *obj->getPosition();
	r.angle = obj->getOrientation();
	ConstructionSite::prepareSite(logic, *obj, *tt, r.offset, r.angle, player);
	Object *built = foundation->construct(*tt, r.offset, r.angle, player, false);
	if (!built)
	{
		return false;
	}
	r.built = built->getID(); // + 0x24
	return true;
}

void AIUpgrade::crc(const AIUnitUpgraderState &u, const AIUpgradeScienceBuilderState &b, StateHasher &h)
{
	h.addU32(0x41495550u); // "AIUP"
	h.addU32((u.listening ? 1u : 0u) | (u.disabled ? 2u : 0u) | (b.listening ? 4u : 0u) | (b.disabled ? 8u : 0u));
	auto requests = [&h](const std::vector<std::shared_ptr<AIBuildRequest>> &v) {
		h.addU32((std::uint32_t)v.size());
		for (const auto &r : v)
		{
			AIBaseBuilder::crcRequest(*r, h);
		}
	};
	requests(u.waiting);
	requests(u.upgrading);
	h.addU32((std::uint32_t)b.pendingStructures.size());
	for (ObjectID id : b.pendingStructures)
	{
		h.addU32(id);
	}
	requests(b.upgrades);
	requests(b.expansions);
	h.addU32(b.lastExpansionFrame);
	h.addU64(u.registered);
	h.addU64(u.submitted);
	h.addU64(u.declined);
	h.addU64(b.registered);
	h.addU64(b.upgradesSubmitted);
	h.addU64(b.expansionsSubmitted);
}
