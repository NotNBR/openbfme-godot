// OpenBFME. GPL-3.0. See AwardSystemManager.h for provenance.
#include "Common/AwardSystemManager.h"
#include "Common/INI.h"
#include "Common/AsciiString.h"
#include "Common/Thing/KindOfTokens.h"
#include "GameLogic/Object/Object.h"

#include <algorithm>

extern const char *const TheKindOfNames[];

namespace
{
bool missing(const std::string &s) { return s.empty() || AsciiStringUtil::compareNoCase(s, "None") == 0; }
void strings(INI *ini, void *, void *store, const void *)
{
	auto &out = *static_cast<std::vector<std::string> *>(store);
	for (const char *s = ini->getNextTokenOrNull(); s; s = ini->getNextTokenOrNull()) out.emplace_back(s);
}
void kinds(INI *ini, void *, void *store, const void *)
{
	auto &out = *static_cast<std::vector<std::string> *>(store);
	std::array<std::uint32_t, 7> mask{};
	for (const auto &s : out)
	{
		const int bit = KindOfTokens::indexOf(s);
		mask[(size_t)bit >> 5] |= 1u << (bit & 31);
	}
	RawTokens raw;
	for (const char *s = ini->getNextTokenOrNull(); s; s = ini->getNextTokenOrNull()) raw.tokens.emplace_back(s);
	std::string error;
	KindOfTokens::parse(raw, mask, error);
	if (!error.empty()) throw INIException(3, "ThingStat: %s", error.c_str());
	out.clear();
	for (int bit = 0; TheKindOfNames[bit]; ++bit)
		if (mask[(size_t)bit >> 5] & (1u << (bit & 31))) out.emplace_back(TheKindOfNames[bit]);
}

void trigger(INI *ini, void *, void *store, const void *)
{
	static const FieldParse fields[] = {
		{ "Stat", strings, nullptr, (int)offsetof(CreateAHeroAwardTrigger, stats) },
		{ "Threshold", INI::parseUnsignedInt, nullptr, (int)offsetof(CreateAHeroAwardTrigger, threshold) },
		{ nullptr, nullptr, nullptr, 0 }
	};
	CreateAHeroAwardTrigger t;
	ini->initFromINI(&t, fields);
	for (const auto &s : t.stats) if (missing(s)) throw INIException(3, "No award name specified while parsing Award.");
	if (!t.threshold) throw INIException(3, "No threshold set for tigger in AwardSystemManager::parseTrigger.");
	std::sort(t.stats.begin(), t.stats.end());
	auto &a = *static_cast<CreateAHeroAward *>(store);
	for (const auto &old : a.triggers)
		if (old.stats == t.stats) throw INIException(3, "Duplicate trigger in the %s award.", a.name.c_str());
	a.triggers.push_back(std::move(t));
}
void objectAward(INI *ini, void *, void *store, const void *)
{
	static const FieldParse fields[] = {
		{ "AwardName", INI::parseAsciiString, nullptr, (int)offsetof(CreateAHeroAward, name) },
		{ "ImageName", INI::parseAsciiString, nullptr, (int)offsetof(CreateAHeroAward, image) },
		{ "NameTag", INI::parseAsciiString, nullptr, (int)offsetof(CreateAHeroAward, nameTag) },
		{ "DescriptionTag", INI::parseAsciiString, nullptr, (int)offsetof(CreateAHeroAward, descriptionTag) },
		{ "UpgradeAwards", strings, nullptr, (int)offsetof(CreateAHeroAward, upgradeAwards) },
		{ "Trigger", trigger, nullptr, 0 },
		{ nullptr, nullptr, nullptr, 0 }
	};
	CreateAHeroAward a;
	ini->initFromINI(&a, fields);
	if (missing(a.name)) throw INIException(3, "No award name specified while parsing Award.");
	auto &system = *static_cast<AwardSystemManager *>(store);
	if (system.award(a.name)) throw INIException(3, "An Award with the name %s already exists.", a.name.c_str());
	if (missing(a.image)) throw INIException(3, "No image name specified while parsing Award.");
	if (missing(a.nameTag)) throw INIException(3, "No name tag specified while parsing Award.");
	if (missing(a.descriptionTag)) throw INIException(3, "No description tag specified while parsing Award.");
	system.awards.push_back(std::move(a));
}
void thingStat(INI *ini, void *, void *store, const void *)
{
	static const FieldParse fields[] = {
		{ "StatName", INI::parseAsciiString, nullptr, (int)offsetof(ThingStatistic, name) },
		{ "ThingTemplateNames", strings, nullptr, (int)offsetof(ThingStatistic, included) },
		{ "ExcludedThings", strings, nullptr, (int)offsetof(ThingStatistic, excluded) },
		{ "KindOf", kinds, nullptr, (int)offsetof(ThingStatistic, kindOf) },
		{ "ExcludedKindOf", kinds, nullptr, (int)offsetof(ThingStatistic, excludedKindOf) },
		{ "NameTag", INI::parseAsciiString, nullptr, (int)offsetof(ThingStatistic, nameTag) },
		{ "DescriptionTag", INI::parseAsciiString, nullptr, (int)offsetof(ThingStatistic, descriptionTag) },
		{ "PrimaryKey", INI::parseAsciiString, nullptr, (int)offsetof(ThingStatistic, primaryKey) },
		{ "SecondaryKey", INI::parseAsciiString, nullptr, (int)offsetof(ThingStatistic, secondaryKey) },
		{ "MultiPlayerOnly", INI::parseBool, nullptr, (int)offsetof(ThingStatistic, multiplayerOnly) },
		{ nullptr, nullptr, nullptr, 0 }
	};
	ThingStatistic s;
	ini->initFromINI(&s, fields);
	if (missing(s.name)) throw INIException(3, "No thingStat name specified while parsing ThingStat in thingStat system.");
	auto &system = *static_cast<AwardSystemManager *>(store);
	if (system.stat(s.name)) throw INIException(3, "An ThingStatistic with the name %s already exists.", s.name.c_str());
	system.statistics.push_back(std::move(s));
}
}

void AwardSystemManager::parse(INI *ini)
{
	static const FieldParse fields[] = {
		{ "ObjectAward", objectAward, nullptr, 0 }, { "ThingStat", thingStat, nullptr, 0 }, { nullptr, nullptr, nullptr, 0 }
	};
	ini->initFromINI(this, fields);
}
const ThingStatistic *AwardSystemManager::stat(const std::string &name) const
{
	for (const auto &s : statistics) if (s.name == name) return &s;
	return nullptr;
}
const CreateAHeroAward *AwardSystemManager::award(const std::string &name) const
{
	for (const auto &a : awards) if (a.name == name) return &a;
	return nullptr;
}
bool CreateAHeroAward::earned(const CreateAHeroCounters &counters) const
{
	if (triggers.empty()) return false;
	for (const auto &t : triggers)
	{
		std::uint32_t total = 0;
		for (const auto &s : t.stats)
		{
			auto it = counters.find(s);
			if (it != counters.end()) total += it->second;
		}
		// DONOR RVA 0x40A99A uses a signed 32-bit comparison.
		if ((std::int32_t)total < (std::int32_t)t.threshold) return false;
	}
	return true;
}
bool ThingStatistic::isContributor(const Object &object, bool multiplayer) const
{
	(void)multiplayer; // RW 0x80DA4B has no MultiPlayerOnly gate in IsContributor.
	for (const auto &k : excludedKindOf) if (object.isKindOfName(k.c_str())) return false;
	const auto &name = object.getTemplate()->getName();
	for (const auto &s : excluded) if (AsciiStringUtil::compareNoCase(name, s) == 0) return false;
	for (const auto &k : kindOf) if (object.isKindOfName(k.c_str())) return true;
	for (const auto &s : included) if (AsciiStringUtil::compareNoCase(name, s) == 0) return true;
	return false;
}
