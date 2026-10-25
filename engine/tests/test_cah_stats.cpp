// OpenBFME. GPL-3.0. Synthetic boundary cases plus retail gates in test_cah1.cpp.
#include "doctest.h"
#include "Common/AwardSystemManager.h"
#include "Common/INI.h"
#include "GameClient/CreateAHeroStats.h"
#include "GameClient/CreateAHeroHeroList.h"
#include <filesystem>
#include <fstream>

TEST_CASE("cah statistics: awards sum each trigger's counters and require every trigger at its exact threshold")
{
	CreateAHeroAward a;
	a.triggers = { { { "wins", "losses" }, 20 }, { { "kills" }, 3 } };
	CreateAHeroCounters counts{ { "wins", 10 }, { "losses", 9 }, { "kills", 3 } };
	CHECK_FALSE(a.earned(counts));
	counts["losses"] = 10;
	CHECK(a.earned(counts));
	counts["kills"] = 2;
	CHECK_FALSE(a.earned(counts));
	CHECK_FALSE(a.earned({}));
	a.triggers.clear();
	CHECK_FALSE(a.earned(counts));
}

TEST_CASE("cah statistics: INI awards are data driven and duplicate trigger lists are rejected independent of order")
{
	INIEnvironment env;
	AwardSystemManager manager;
	env.blocks.registerBlock("AwardSystem", [&](INI *ini) { manager.parse(ini); });
	INI ini(env);
	auto load = [&](const std::string &body) {
		const std::string text = "AwardSystem\n" + body + "\nEnd\n";
		ini.loadMemory("synthetic.ini", { text.begin(), text.end() }, INI_LOAD_OVERWRITE);
	};
	load("ThingStat\n StatName = wins\n NameTag = Custom:Wins\nEnd\nObjectAward\n AwardName = Medal\n ImageName = MedalIcon\n NameTag = Custom:Medal\n DescriptionTag = Custom:Description\n Trigger\n Stat = wins losses\n Threshold = 20\n End\nEnd");
	REQUIRE(manager.award("Medal"));
	CHECK(manager.award("Medal")->image == "MedalIcon");
	CHECK(manager.award("Medal")->earned({ { "wins", 19 }, { "losses", 1 } }));
	CHECK_THROWS_AS(load("ObjectAward\n AwardName = Duplicate\n Trigger\n Stat = wins losses\n Threshold = 1\n End\n Trigger\n Stat = losses wins\n Threshold = 2\n End\nEnd"), INIException);
	CHECK_THROWS_AS(load("ThingStat\n StatName = wins\nEnd"), INIException);
	CHECK_THROWS_AS(load("ObjectAward\n AwardName = EmptyThreshold\n Trigger\n Stat = wins\n End\nEnd"), INIException);
	CHECK_THROWS_AS(load("ThingStat\n StatName = Broken\n KindOf = MADE_UP_KIND\nEnd"), INIException);
}

TEST_CASE("cah statistics: separate files retain counters across replacement writes and follow retail decimal prefix conversion")
{
	const auto dir = std::filesystem::temp_directory_path() / ("openbfme-cah-stats-" + CreateAHeroHeroList::newUniqueID());
	struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code ec; std::filesystem::remove_all(path, ec); } } cleanup{ dir };
	CreateAHeroStats stats;
	std::string error;
	REQUIRE(stats.load(dir.u8string(), "ABC123", &error));
	CHECK(stats.get("wins") == 0);
	stats.add("wins", 19);
	REQUIRE(stats.save(dir.u8string(), "ABC123", &error));
	stats.add("wins");
	stats.add("mod_counter", 7);
	REQUIRE(stats.save(dir.u8string(), "ABC123", &error));
	CreateAHeroStats loaded;
	REQUIRE(loaded.load(dir.u8string(), "ABC123", &error));
	CHECK(loaded.get("wins") == 20);
	CHECK(loaded.get("mod_counter") == 7);
	std::ofstream(dir / "ABC123") << "wins = 12suffix\nnegative = -1\nempty = \ninvalid = broken\n";
	REQUIRE(loaded.load(dir.u8string(), "ABC123", &error));
	CHECK(loaded.get("wins") == 12);
	CHECK(loaded.get("negative") == 0xFFFFFFFFu);
	CHECK(loaded.get("empty") == 0);
	CHECK(loaded.get("invalid") == 0);
	std::filesystem::create_directories(dir / "blocked");
	CHECK_FALSE(loaded.load(dir.u8string(), "blocked", &error));
	CHECK(loaded.get("wins") == 12);
	CHECK_FALSE(stats.save(dir.u8string(), "../outside", &error));
	CHECK_FALSE(stats.load("", "ABC123", &error));
}
