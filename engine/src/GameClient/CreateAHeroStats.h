// OpenBFME. GPL-3.0.
#pragma once
#include "Common/AwardSystemManager.h"

// Client profile data, never transferred in .cah files, snapshots or lockstep.
// TARGET RW 0x80B339: Save/<uniqueID>, one "name = count" line per counter.
// New heroes legitimately have no file. Unreadable files are errors; decimal conversion follows retail atoi.
class CreateAHeroStats
{
public:
	bool load(const std::string &profileDir, const std::string &id, std::string *error);
	bool save(const std::string &profileDir, const std::string &id, std::string *error) const;
	std::uint32_t get(const std::string &name) const;
	void add(const std::string &name, std::uint32_t amount = 1) { counters[name] += amount; }
	CreateAHeroCounters counters;
};
