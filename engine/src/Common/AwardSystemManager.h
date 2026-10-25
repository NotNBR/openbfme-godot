// OpenBFME. GPL-3.0.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

class INI;
class Object;
using CreateAHeroCounters = std::map<std::string, std::uint32_t>;

// TARGET: RotWK AwardSystem.ini, IsContributor RW 0x80DA4B and hero kill
// statistics RW 0x80B1D4 (binary provenance caveat S-001).
// DONOR: BFME2 AwardSystemManagerParseThingStat.cpp / Rva0040AA27.cpp.
struct ThingStatistic
{
	std::string name, nameTag, descriptionTag, primaryKey, secondaryKey;
	std::vector<std::string> included, excluded, kindOf, excludedKindOf;
	bool multiplayerOnly = false;
	bool isContributor(const Object &object, bool multiplayer) const;
};

struct CreateAHeroAwardTrigger
{
	std::vector<std::string> stats;
	std::uint32_t threshold = 0;
};

struct CreateAHeroAward
{
	std::string name, nameTag, descriptionTag, image;
	std::vector<std::string> upgradeAwards;
	std::vector<CreateAHeroAwardTrigger> triggers;
	bool earned(const CreateAHeroCounters &counters) const;
};

class AwardSystemManager
{
public:
	void parse(INI *ini);
	const ThingStatistic *stat(const std::string &name) const;
	const CreateAHeroAward *award(const std::string &name) const;
	std::vector<ThingStatistic> statistics;
	std::vector<CreateAHeroAward> awards;
};
