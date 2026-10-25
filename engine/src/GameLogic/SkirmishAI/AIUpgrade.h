// OpenBFME. GPL-3.0.
//
// The skirmish AI's upgrade purchases (lane AI5): AIUnitUpgrader (the army's upgrades), AIUpgradeScienceBuilder (the structures' upgrades and the build plots'
// expansions), their requests (AIUpgrade, AIExpansionScience) and the upgrade heuristics. The retail names are the ones its random draws and asserts carry
// (RW 0xC882B0 "...\SkirmishAI\AIUpgrade\AIUnitUpgrader\AIUnitUpgrader.cpp", RW 0xC88170 "...\AIUpgradeScienceBuilder\AIUpgradeScienceBuilder.cpp",
// RW 0xC8EB40 "...\AIUpgradeScienceBuilder\AIExpansionScience.cpp", RW 0xC8EA68 "...\AIUpgrade\AIUpgradeHeuristicFortress.cpp"). Despite its name the
// "science builder" buys no science: RotWK's only science purchases are the scripts', the player's and ZH's AIPlayer::doUpgradesAndSkills (RW 0x8F7B3B), which
// RW 0x8F9705 runs only for a computer player without a skirmish AI (stop S-1875).
//
// TARGET FACTS (RotWK game.dat, caveat S-001; Ghidra decompiles and disassembly of the addresses cited):
//   * both builders are listeners of the player info record (record + 0x38, objects {vtable, mask}): AIPlayer::init RW 0x8F02CC adds the economy builder's
//     (+ 0xB4, RW 0x8EE74A), the unit upgrader's (+ 0xFC, mask 4, RW 0x9A1340 -> RW 0x8E4264 push_back) and the upgrade builder's (+ 0x12C, mask 1, RW 0x8EE74A)
//     before the default team's object events (RW 0x6A9E48). The record's Register RW 0x8E4591 calls listener vslot 0 (object, 1) for every list that took the
//     object (RW 0x8E3D4C: 2 economy, 1 structures, 4 army / ships), UnRegister RW 0x8E480C vslot 4 (object) for every list that lost it (RW 0x8E3D77).
//   * AIPlayer::update RW 0x8F0EB4 runs the sub systems through RW 0x90CD00 (skipped while + 4 is set) in the order base (+ 4), wall (+ 0xE4), units (+ 0x38),
//     team (+ 0x90), economy (+ 0xC0), unit upgrader (+ 0x108, update RW 0x9A1696), upgrade builder (+ 0x12C -> + 0xC, update RW 0x9A0023); RW 0x8F02CC sets
//     + 0x10C from SkirmishAIData DisableUnitUpgrading (+ 0x968) and (+ 0x12C) + 0x10 from DisableScienceUpgrading (+ 0x967).
//   * AIUnitUpgrader Register RW 0x9A155C: for each of the object's command set buttons 0 .. 32 (RW 0x69156B / 0x71EFA2 / 0x80C837) with an upgrade (button + 0x24): a
//     request (0x44 bytes, ctor RW 0x9EDD1C) with cost = UpgradeTemplate::calcCostToBuild(owner, object) (RW 0x66F2C8), the object (+ 8), the button (+ 0x30), the
//     upgrade's name (+ 0xC), priority (+ 4) = (float)GetGameLogicRandomValue((int)UnitUpgradePriorityLow, (int)UnitUpgradePriorityHigh) (AIUnitUpgrader.cpp
//     0x5D; ArmyDefinition + 0xE4 / + 0xE8), the heuristic of the upgrade's SkirmishAIHeuristic (+ 0x98, RW 0x9EDDAE) and, with a heuristic, priority 9999.0f
//     (RW 0xC18414); appended to the waiting list (+ 0x14). UnRegister RW 0x9A135B: the waiting records of the object (+ 8 == the id) are deleted, the
//     upgrading ones leave the AI's queues (RW 0x9618E3 -> RW 0x8F0602) and are deleted.
//   * AIUnitUpgrader update RW 0x9A1696: for each waiting record, its heuristic is evaluated (RW 0x9EDD3D: + 0x40 = heuristic vslot 0(owner)); with the AI's game
//     phase (AISkirmishPlayer + 0x16C) above 0 or the result 2: an object that no longer resolves is dropped; one whose upgrade is not legal (RW 0x695338) or
//     whose result is 3 stays; else (result 2 skips the draw) GetGameLogicRandomValueReal(0, 1) (AIUnitUpgrader.cpp 0xB4) above ChanceForUnitsToUpgrade
//     (ArmyDefinition + 0xD0) drops it, otherwise it is submitted (vslot 0x18 = RW 0x9618BA(owner, 0): state 0, the pending queue) and moved to the upgrading
//     list. Then the upgrading records whose object is gone or that are finished (RW 0x8EDA5E) leave the queues and are deleted, and every one left that is
//     done (RW 0x99F83D: state >= 1 and the object's production no longer queues the upgrade) is complete (RW 0x99FA40: vslot 0x1C(2)).
//   * AIUpgradeScienceBuilder Register RW 0x9A018B: an object of any KindOf of RW 0x99FAA6's mask (WALK_ON_TOP_OF_WALL, DEFENSIVE_WALL, WALL_UPGRADE, WALL_HUB,
//     WALL_SEGMENT, SCALEABLE_WALL, WALL_GATE: bits 60 61 150 156 189 201 203) is ignored; one under construction (construction percent + 0x288 >= 0) waits in
//     + 0x18 until RW 0x99FCC4 sees it finished (below 0: Register again; a gone id is dropped). Else each button 0 .. 32: with an upgrade, an upgrade request
//     (ctor RW 0x99F4D6) with the cost, the object, the button, the name, the money reserve flag (+ 0x21) and the heuristic (RW 0x99F52F) to + 0x24; without
//     one, a FOUNDATION_CONSTRUCT button (command 1) whose template exists and is neither KindOf WALL_HUB (+ 0x11B bit 4) nor GARRISON (+ 0x116 bit 6): an
//     expansion request (ctor RW 0x9ED687) with the button (+ 0x40), the template's name, priority -1.0f (RW 0xBD19DC), the object's position and angle (+ 0x30
//     .. + 0x3C), the object and the reserve flag, to + 0x30. UnRegister RW 0x99FC0C: upgrade records of the object leave the queues when upgrading and are
//     deleted; expansion records of the object leave them when started (+ 0x2C) and are deleted; one whose structure (+ 0x24) is the object leaves the queues,
//     forgets it and may start again (+ 0x2C cleared). The pending list (+ 0x18) is not touched.
//   * AIUpgradeScienceBuilder update RW 0x9A0023: RW 0x99FCC4 (the pending structures), RW 0x99FD0E (records whose object is gone, dead (+ 0x458 bit 0, expansions
//     only) or that are finished leave the queues when started and are deleted), RW 0x99FE74 (normal upgrades), RW 0x99FAEF (expansions), then RW 0x99FA40
//     on each upgrading record.
//   * RW 0x99FE74: count the upgrade records that are upgrading and not finished; the limit is 1 in the MidGame phase, 3 in the EndGame, none in the Rush; below
//     it, RW 0x99FDDE picks the first record with result 2, else the first with result 1 (each record evaluated, in list order, first pass then second), that
//     is not upgrading and legal; without one, the cheapest (strictly) record that is not upgrading, is legal, costs at most money / (count + 1) (cost *
//     (count + 1) <= money in float) and whose evaluation is not 3. The pick is upgrading; result 0 draws its priority GetGameLogicRandomValueReal(Normal
//     Low, NormalHigh) (AIUpgradeScienceBuilder.cpp 0x18C, ArmyDefinition + 0xD4 / + 0xD8), 1 (ImportantLow, ImportantHigh) (0x18F, + 0xDC / + 0xE0), 2 gives
//     -1.0f; then it is submitted.
//   * RW 0x99FAEF: with expansion records, LOGICFRAMES_PER_SECOND * 60 frames (RW 0xDEBE48, set by RW 0xBC97A2) since + 0x3C and the phase above 0: a record drawn
//     GetGameLogicRandomValue(0, n - 1) (AIUpgradeScienceBuilder.cpp 0x1A2) that is not started and whose check (vslot 0x40, RW 0x9ED764) is 0 is submitted,
//     started, and + 0x3C = the frame.
//   * the heuristics (RW 0x9EDDAE / 0x99F52F, evaluated by vslot 0): IMPORTANT (0, a static of vtable RW 0xC8EAE8) and BOILINGOIL (1, RW 0x9ED610, the same
//     vtable) answer 0 (RW 0x46C6BE); none (-1, RW 0xC8EAF0) answers 1 (RW 0x9ED653): an upgrade without a heuristic draws from the Important range.
//     FACTORY_UNITUNLOCK (2, RW 0x9ED4D2 / 0x9ED45E): the templates of the object's UNIT_BUILD / SECONDARY_UNIT_BUILD buttons (3 / 4) that name the upgrade in
//     their NeededUpgrade list; 1 when the ArmyDefinition (of the object's player's AI) has a member of one of them whose percentage for the AI's phase
//     (RW 0x82FE4C / 0x82FC8F) is above 0.0f, else 0. FORTRESS (3, RW 0x9ED351 / 0x9ED374): starts at 3 with next frame -1; with the phase above 0 and the
//     frame at or past the next frame (or -1): next = frame + LOGICFRAMES_PER_SECOND * ((7 - phase) * 5 - (5 when the AI difficulty RW 0x6AA61B is above 1)),
//     then the first structure of the player info record that is a DOZER_FACTORY makes it 0 when GetGameLogicRandomValue(1, 5) (money + reserve, RW 0x99E766,
//     above 2000; AIUpgradeHeuristicFortress.cpp 0x4F) or GetGameLogicRandomValue(1, 10) (0x58) is 1. SUMMON_ANTICAVALRY / ANTIARCHER / ANTISPECIAL /
//     ANTIINFANTRY (4 .. 7, RW 0x9ECF7F / 0x9ECC0D / 0x9EC8A1 / 0x9EC539) are not ported (stop S-1876).
//   * the requests in the AI's processor (RW 0x8F0F7E): neither needs a producer (vslots 0x2C / 0x10 answer false, RW 0x5188EB); an upgrade's vslot 0x14 does
//     nothing (RW 0x63F3BF), an expansion's is the base's (RW 0x961D28). Check (vslot 0x40) of an upgrade RW 0x99F88B: money (Player + 0x94) below the cost: 2;
//     no object, production or button: 9; production entries (vslot 0x44): 4; else the legality RW 0x695338. Check of an expansion RW 0x9ED764: no template
//     or object: 9; Player::allowedToBuild RW 0x6AC856, the button template's Buildable (RW 0x73BFE8: not No, Only_By_AI only for a computer player), a plot
//     interface (RW 0x68C3C3) without an occupant (slot 3), Player::canBuild RW 0x6AC927, else 9; then 0 when Player::canAfford(template, 0) (RW 0x6AAA2E, with
//     the reserve deposited around it for + 0x21), GetGameLogicRandomValue(600, 1000) (AIExpansionScience.cpp 0x5C, drawn only when affordable) <= the money
//     read before, more than 3 economy and 7 army entries in the record; else 2. Before an execution RW 0x8F0E6C orders a garrisoned object (status
//     INSIDE_GARRISON, with an AI) out of its container (RW 0x7716C1: AI command 0x1A, source 0). Execute (vslot 0x3C) of an upgrade RW 0x99F7EF:
//     Object::doCommandButton(button, 1, 0) (RW 0x696FD2: upgrade commands 6 .. 8 queue the upgrade when legal), then whether the production queues it; of an
//     expansion RW 0x9ED8C4: BuildAssistant slot 0x38 (RW 0x797796) builds the template on the plot at the request's position and angle; the structure's id
//     is + 0x24.
//   * the legality RW 0x695338 (0 legal, 9 not): an upgrade, a production (RW 0x68C327) that is not disabled (slot 25), not (WALL_UPGRADE and body vslot 0x24 == 3),
//     an OBJECT upgrade the object lacks and is affected by; then, for a player that has no skirmish AI and is not human (+ 0x5C != 0), legal; else a NEED_UPGRADE
//     button's NeededUpgrade list (all, or any with NeededUpgradeAny).
//   * the money reserve (record + 0xC -> + 0x14, ported with these: AIBaseBuilder's saveMoney RW 0x8F0502, moneyPlusReserve RW 0x99E766, withdrawFromReserve
//     RW 0x99E79A, the processor's check / execute wrappers RW 0x961975 / 0x96190B, the dozer queue's draw RW 0x9A1AA2, the hero check RW 0x9A0A74).
// INFERENCE / NOT PORTED (stop S-1876): a plot's occupant is the port's CastleMemberBehavior occupant id (S-952); the body vslot 0x24 test of a WALL_UPGRADE object is not
// read (no object the AI registers can reach it: the upgrade builder ignores WALL_UPGRADE, the unit upgrader's army list holds no structure); FACTORY_UNITUNLOCK
// keeps template names (the evaluation compares names, RW 0x82FE4C).

#pragma once

#include "GameLogic/ObjectTypes.h"

#include <memory>
#include <string>

class CommandButton;
class GameLogic;
class Object;
class Player;
class StateHasher;
struct AIBuildRequest;
struct AISkirmishPlayer;
struct AIUnitUpgraderState;
struct AIUpgradeScienceBuilderState;
struct SkirmishAIData;

namespace AIUpgrade
{
// the heuristic types (Upgrade SkirmishAIHeuristic, RW 0xDB4F44)
enum Heuristic
{
	HEURISTIC_NONE = -1,
	HEURISTIC_IMPORTANT = 0,
	HEURISTIC_BOILINGOIL = 1,
	HEURISTIC_FACTORY_UNITUNLOCK = 2,
	HEURISTIC_FORTRESS = 3,
	HEURISTIC_SUMMON_ANTICAVALRY = 4,
	HEURISTIC_SUMMON_ANTIINFANTRY = 7
};

// RW 0x9A1340 / 0x8EE74A and the Disable flags of RW 0x8F02CC
void init(AISkirmishPlayer &ai, const SkirmishAIData &data);
// the record's listener calls for the AI of the record's player (RW 0x8E3D4C vslot 0 / RW 0x8E3D77 vslot 4); `lists` = AIStatCollector's mask
void onRegister(GameLogic &logic, AISkirmishPlayer &ai, Object &obj, unsigned lists);
void onUnRegister(GameLogic &logic, AISkirmishPlayer &ai, Object &obj, unsigned lists);
// RW 0x9A1696 / RW 0x9A0023 (called by AIBaseBuilder::update in RW 0x8F0EB4's order)
void updateUnitUpgrader(GameLogic &logic, AISkirmishPlayer &ai, Player &player);
void updateScienceBuilder(GameLogic &logic, AISkirmishPlayer &ai, Player &player);
// the processor's calls for an upgrade or expansion request: check (vslot 0x40), execute (RW 0x8F0E6C then vslot 0x3C)
int check(GameLogic &logic, AISkirmishPlayer &ai, AIBuildRequest &r, Player &player);
bool execute(GameLogic &logic, AISkirmishPlayer &ai, AIBuildRequest &r, Player &player);
// RW 0x695338 (exposed for tests)
int legality(GameLogic &logic, const Object &obj, const CommandButton *button);
// RW 0x9EDD3D: evaluate the request's heuristic for `player` and store it (+ 0x40)
int evaluate(GameLogic &logic, AIBuildRequest &r, Player &player);
// RW 0x9EDDAE / 0x99F52F: (re)build the heuristic of `type` for the request (FACTORY_UNITUNLOCK reads its object's command set)
void makeHeuristic(GameLogic &logic, AIBuildRequest &r, int type);
void crc(const AIUnitUpgraderState &u, const AIUpgradeScienceBuilderState &b, StateHasher &h);
} // namespace AIUpgrade
