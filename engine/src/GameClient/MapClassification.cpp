// OpenBFME. GPL-3.0.
// See GameClient/MapClassification.h.

#include "Common/BfmeGame.h"
#include "GameClient/MapClassification.h"

#include <algorithm>
#include <chrono>
#include <stdexcept>

namespace
{
double secondsSince(const std::chrono::steady_clock::time_point &t0)
{
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}
} // namespace

std::string MapClassification::mapDirectory(const std::string &lowerName, const std::string &mapsFolder)
{
	return mapsFolder + "\\" + lowerName;
}

std::string MapClassification::mapPath(const std::string &lowerName, const std::string &mapsFolder)
{
	return mapDirectory(lowerName, mapsFolder) + "\\" + lowerName + ".map";
}

bool MapClassification::run(const std::vector<std::uint8_t> &bytes, const std::string &sourceName, const std::string &lowerName, RetailObjectWorld &world,
	const MapObjectOptions &options, LoadedMap &map, TerrainLogic &terrain, MapObjectDrawables &classified, MapObjectDrawables *clientOnly,
	Result &result, std::string *error, const std::string &mapsFolder, bool profilingMovementField)
{
	auto t0 = std::chrono::steady_clock::now();
	const auto worldContext = world.enterContext(); // this world's stores and audio validator for the map.ini parse and the classification
	MapReadOptions mro;
	mro.bfme1 = world.bfme1Data(); // community PR #36
	if (!MapReader::load(bytes, sourceName, mro, map, error))
	{
		return false;
	}
	result.secondsLoad = secondsSince(t0);
	// Explicit profiling fixture, never used by ordinary map loads. Preserve the
	// map's dimensions, textures, sides and start waypoints, but provide unobstructed
	// ground for a sustained marching workload. No movement rules are bypassed.
	if (profilingMovementField)
	{
		std::fill(map.heightMap.m_data.begin(), map.heightMap.m_data.end(), (std::uint16_t)256);
		for (auto *plane : { &map.heightMap.m_planeA, &map.heightMap.m_planeB, &map.heightMap.m_planeTaint,
			&map.heightMap.m_planeExtraPass, &map.heightMap.m_cellCliffState })
			std::fill(plane->begin(), plane->end(), (std::uint8_t)0);
		std::fill(map.heightMap.m_cliffInfoNdxes.begin(), map.heightMap.m_cliffInfoNdxes.end(), 0);
		map.chunks.standingWaterAreas.clear();
		map.chunks.riverAreas.clear();
		map.chunks.polygonTriggers.clear();
		auto &objects = map.chunks.objects;
		objects.erase(std::remove_if(objects.begin(), objects.end(), [](const MapObject &obj) { return !obj.isWaypoint(); }), objects.end());
	}

	t0 = std::chrono::steady_clock::now();
	terrain.init(map.heightMap, map.chunks, nullptr);
	try
	{
		result.mapIni = world.applyMapIni(mapDirectory(lowerName, mapsFolder));
	}
	catch (const std::logic_error &e) // lane MAPRESET-1: a game of this world is still live (its map would be torn out from under it)
	{
		if (error)
		{
			*error = e.what();
		}
		return false;
	}
	result.secondsMapIni = secondsSince(t0);

	t0 = std::chrono::steady_clock::now();
	MapObjectCreation::build(map, lowerName, world.things(), terrain, options, classified);
	result.secondsBuild = secondsSince(t0);
	if (clientOnly)
	{
		clientOnly->sides = classified.sides;
	}
	for (const MapObjectDrawable &d : classified.drawables)
	{
		if (d.fate == MAPOBJ_OBJECT || d.fate == MAPOBJ_OBJECT_BRIDGE)
		{
			++result.fullObjects;
		}
		else if (clientOnly && MapObjectFateDrawsAnything(d.fate))
		{
			clientOnly->drawables.push_back(d);
			++result.clientOnly;
		}
	}
	return true;
}
