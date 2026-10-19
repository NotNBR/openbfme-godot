// OpenBFME unit tests, lanes WALL-1 / WALL-2 with upstream's SAVE-4: a walled map's snapshot. GPL-3.0.
//
// Helm's Deep (wall tops and ramps in the ground grid's 7-bit layers, the raised walkway over the gate, its portal waypoints): the game saved while a
// horde walks on the Deeping Wall loads into itself (LiveGame::loadSnapshot) and every following frame hashes as the run that was not loaded; the
// pathfinder's wall pieces, wall heights and waypoints come back. SKIPs loudly without the installs.

#include "doctest.h"

#include "HudTestUtil.h"

#include "GameLogic/AI/AIPathfind.h"
#include "GameLogic/AI/AIWorld.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Module/AIUpdate.h"
#include "GameLogic/Object/Object.h"

#include <string>
#include <vector>

using namespace hudtest;

TEST_CASE("walls snapshot retail: Helm's Deep with a horde on its wall top saves and loads into itself; the wall pieces, heights and waypoints come "
		  "back and the next 100 frames hash as before")
{
	if (!haveWorld("walls snapshot"))
	{
		return;
	}
	Rig r(shared(), "map wor helms deep", "FactionMen");
	const auto worldContext = shared().world->enterContext();
	r.frame(3);
	Pathfinder &pf = r.logic().aiWorld()->pathfinder();
	REQUIRE(pf.wallPieceCount() > 0); // tolerance: a precondition (Helm's Deep's wall pieces exist; their count is the map's, compared after the load)
	// a horde ordered onto the Deeping Wall's top (the highest walkable layer at the point, as a right click on the wall gives)
	const Coord3D onWall{ 1645.0f, 2938.0f, 0.0f };
	REQUIRE(isWallLayer(pf.getLayerAt(onWall.x, onWall.y)));
	const Coord3D from = r.freeSpot(1640.0f, 3150.0f, 60.0f);
	Object *horde = r.make("GondorFighterHorde", from.x, from.y);
	r.frame(2);
	REQUIRE(horde->getAIUpdateInterface());
	Coord3D goal = onWall;
	goal.z = r.logic().getHighestLayerHeight(goal.x, goal.y);
	horde->getAIUpdateInterface()->aiMoveToPosition(goal, CMD_FROM_PLAYER);
	r.frame(60);
	const size_t pieces = pf.wallPieceCount(), waypoints = pf.waypointCount();
	const std::vector<float> heights = pf.wallHeights();

	std::vector<std::uint8_t> snapshot;
	std::string error;
	REQUIRE_MESSAGE(r.logic().saveSnapshot(snapshot, &error), error);
	const UnsignedInt savedFrame = r.logic().getFrame();
	const std::uint32_t savedHash = r.logic().computeStateHash();
	std::vector<std::uint32_t> hashes;
	for (int i = 0; i < 100; ++i)
	{
		r.frame(1);
		hashes.push_back(r.logic().computeStateHash());
	}
	REQUIRE_MESSAGE(r.game->loadSnapshot(snapshot, &error), error);
	CHECK(r.logic().getFrame() == savedFrame);
	CHECK(r.logic().computeStateHash() == savedHash);
	Pathfinder &loaded = r.logic().aiWorld()->pathfinder();
	CHECK(loaded.wallPieceCount() == pieces);
	CHECK(loaded.wallHeights() == heights);
	CHECK(loaded.waypointCount() == waypoints);
	int same = 0;
	for (size_t i = 0; i < hashes.size(); ++i)
	{
		r.frame(1);
		same += r.logic().computeStateHash() == hashes[i] ? 1 : 0;
	}
	CHECK(same == (int)hashes.size());
}
