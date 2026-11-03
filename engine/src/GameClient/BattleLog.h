// OpenBFME. GPL-3.0.
//
// BattleLog (lane WALL-1, the fortress battles' observation): one line of what a siege battle holds after a logic frame, for openbfme_peer's
// --battle-log: per player its living troops (KindOf INFANTRY, CAVALRY or MONSTER, horde members one by one), how many of them stand raised (more
// than kRaised over the ground: on a wall top, a ramp or a deployed ladder), its battalions (HORDE) and heroes (HERO); every gate (BLOCKING_GATE) and
// every wall piece with a body (WALK_ON_TOP_OF_WALL) that is hurt, by name with its health; the siege deploys (SiegeDeploySpecialPower) by phase;
// the map scripts' counters; and every object of the watched templates (--battle-watch) one by one: its name, position, health, AI state, victim and
// deploy phase. Diagnostics only, like GameClient/FrameCensus: it reads the logic between frames, writes nothing, and nothing reads
// it back into the game (excluded from the simulation audit in tools/sim/sim_policy.json).

#pragma once

#include <string>
#include <vector>

class GameLogic;

namespace BattleLog
{
constexpr float kRaised = 15.0f; ///< a troop this far over the ground under it counts as raised
std::string line(GameLogic &logic, const std::vector<std::string> &watch = {});
} // namespace BattleLog
