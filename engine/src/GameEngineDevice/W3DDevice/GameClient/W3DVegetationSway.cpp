// OpenBFME - lane VISUAL-2. See W3DVegetationSway.h for the sources.

#include "GameEngineDevice/W3DDevice/GameClient/W3DVegetationSway.h"

#include "GameEngineDevice/W3DDevice/GameClient/Drawable/Draw/W3DDrawServices.h"

#include <cmath>

void W3DVegetationSway::update(const Breeze &info, W3DDrawRandom &random, double clientFrames)
{
	// RW 0x4E5D2C
	if (info.breezeVersion != m_curSwayVersion)
	{
		for (int i = 0; i < NUM_SWAY_ENTRIES; ++i)
		{
			const float factor = std::cos((float)i * 0.06220976f);
			const float angle = info.lean + info.intensity * factor;
			const float s = std::sin(angle);
			const float c = std::cos(angle);
			m_swayOffsets[i].x = info.directionX * s;
			m_swayOffsets[i].y = info.directionY * s;
			m_swayOffsets[i].z = c - 1.0f;
		}
		const float delta = info.randomness * 0.5f;
		const float high = 1.0f + delta;
		const float low = 1.0f - delta;
		for (int i = 0; i < MAX_SWAY_TYPES; ++i)
		{
			m_curSwayStep[i] = 100.0f / ((float)info.breezePeriod * m_swayRate);
			m_curSwayStep[i] *= random.real(low, high); // W3DVegetationBufferBase.cpp line 0x1B5
			if (m_curSwayStep[i] < 0.0f)
			{
				m_curSwayStep[i] = 0.0f;
			}
			m_curSwayOffset[i] = 0.0f;
			m_curSwayFactor[i] = random.real(low, high); // line 0x1BA
		}
		m_curSwayVersion = info.breezeVersion;
	}
	// the retail call advances once; the device layer passes the elapsed client frames (whole calls, then the remaining fraction)
	double left = clientFrames;
	while (left > 0.0)
	{
		const float part = left >= 1.0 ? 1.0f : (float)left;
		left -= 1.0;
		for (int i = 0; i < MAX_SWAY_TYPES; ++i)
		{
			m_curSwayOffset[i] += part == 1.0f ? m_curSwayStep[i] : m_curSwayStep[i] * part;
			if (m_curSwayOffset[i] > 100.0f)
			{
				m_curSwayOffset[i] -= 100.0f;
			}
		}
	}
}

void W3DVegetationSway::advanceSeconds(const Breeze &breeze, W3DDrawRandom &random, double seconds)
{
	update(breeze, random, seconds * (double)kClientFramesPerSecond);
}

void W3DVegetationSway::swayOffsets(Vec3 out[MAX_SWAY_TYPES + 1], bool smoothLoop) const
{
	// RW 0x4E61EE
	out[0] = Vec3();
	for (int i = 0; i < MAX_SWAY_TYPES; ++i)
	{
		Vec3 &o = out[1 + i];
		o = Vec3();
		// Presentation correction: the retail setter leaves phases 99..100
		// at zero. Interpolate across the seam rather than snapping upright.
		const float phase = smoothLoop ? std::fmod(m_curSwayOffset[i], (float)NUM_SWAY_ENTRIES) : m_curSwayOffset[i];
		const int minOffset = (int)std::floor(phase);
		if (minOffset < 0 || (!smoothLoop && minOffset + 1 >= NUM_SWAY_ENTRIES) || minOffset >= NUM_SWAY_ENTRIES)
		{
			continue;
		}
		const float f2 = phase - (float)minOffset;
		const float f1 = 1.0f - f2;
		const Vec3 &a = m_swayOffsets[minOffset];
		const Vec3 &b = m_swayOffsets[(minOffset + 1) % NUM_SWAY_ENTRIES];
		o.x = (a.x * f1 + b.x * f2) * m_curSwayFactor[i];
		o.y = (a.y * f1 + b.y * f2) * m_curSwayFactor[i];
		o.z = (a.z * f1 + b.z * f2) * m_curSwayFactor[i];
	}
}

int W3DVegetationSway::treeSwayType(bool taintedTree, W3DDrawRandom &random)
{
	// RW 0x4EC93A
	return taintedTree ? 0 : random.value(1, 10);
}
