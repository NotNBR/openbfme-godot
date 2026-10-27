// OpenBFME. GPL-3.0.
#pragma once

#include "Common/Thing/ThingTemplate.h"
#include "GameEngineDevice/W3DDevice/GameClient/Drawable/Draw/W3DModelDraw.h"

namespace ObjectShadow
{
// RW 0xD99EB0's volume bits (W3DModelDrawNameLists.inc). Godot shadow maps stand in for these geometries;
// Ordinary SHADOW_DECAL objects (infantry and optimized trees) also cast silhouettes in this shadow-map
// substitute. This is not their retail blob decal. Effect/aura decals and projections remain excluded.
// Non-self variants remain S-3304.
constexpr int MapMask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 14) | (1 << 15);

inline bool castsMap(const ThingTemplate *object, const W3DModelDrawModuleData *module, const ModelConditionInfo *state)
{
	if (module && module->m_shadowForceDisable) return false;
	if (state && state->hasShadow) return (state->shadow.type & MapMask) != 0;
	if (!object) return false;
	const FieldValue *field = object->findField("Shadow");
	const long long *bits = field ? std::get_if<long long>(field) : nullptr;
	return bits && (*bits & MapMask) != 0;
}
}
