// OpenBFME. GPL-3.0. Artistic, client-only instanced ground cover.
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include "GameClient/MapChunks.h"
#include "GameClient/TerrainRoads.h"
#include "GameEngineDevice/W3DDevice/GameClient/WorldHeightMap.h"
#include "GameLogic/Map/TerrainLogic.h"

namespace godot {
// Uses its own coordinate hashes, never simulation RNG. Returns null on a missing asset.
Node3D *buildGroundCover(const WorldHeightMap &map, const MapChunks &chunks,
	const TerrainLogic &terrain, const TerrainUvOptions &uvOptions, const Ref<Image> &meadowMask,
	const Ref<ShaderMaterial> &terrainMaterial, const std::vector<RoadStrip> &roads,
	bool enabled, Dictionary &report, String &error);
}
