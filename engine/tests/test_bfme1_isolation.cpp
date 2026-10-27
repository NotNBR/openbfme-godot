// OpenBFME unit tests. GPL-3.0.
// community PR #36 review (docs/BFME1.md, Common/BfmeGame.h): BFME1 support is isolated. BFME1's extra INI rows and names are read only from BFME1
// data (its SubsystemLegend.ini without BFME2's SubsystemLegendExpansion1.ini); RotWK / BFME2 data still fail on them exactly as the binary does.

#include "doctest.h"

#include "IniTestUtil.h"
#include "LogicTestUtil.h"
#include "ObjectTestUtil.h"
#include "PathfindTestUtil.h"
#include "RetailTestMount.h"

#include "Common/Audio/AudioIni.h"
#include "Common/BfmeGame.h"
#include "Common/INI.h"
#include "GameLogic/Module/BloodthirstyUpdate.h"
#include "GameLogic/AI/AIWorld.h"
#include "GameLogic/ExperienceWorld.h"
#include "GameLogic/Module/PortalModules.h"
#include "GameLogic/Object/RetailObjectWorld.h"
#include "GameLogic/Object/ExperienceTracker.h"
#include "GameLogic/ObjectFilter.h"
#include "GameLogic/ObjectFilterMatch.h"
#include "GameClient/UnitVoiceResponse.h"
#include "GameEngineDevice/Win32Device/Common/Win32BIGFileSystem.h"
#include "GameLogic/Module/LogicModules.h"
#include "Libraries/WWVegas/WW3D2/assetmgr.h"
#include "Libraries/WWVegas/WW3D2/textureloader.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <cstdlib>
#include <filesystem>
#include <iterator>
#include <string>

namespace ModelCondition
{
int indexOf(const std::string &name);
}

namespace
{
const initest::FileList kBfme1Legend = { { "Data\\INI\\Default\\SubsystemLegend.ini", "; BFME1's legend\r\n" } };
const initest::FileList kRotwkLegends = { { "Data\\INI\\Default\\SubsystemLegend.ini", "; legend\r\n" },
	{ "Data\\INI\\Default\\SubsystemLegendExpansion1.ini", "; the expansion's legend\r\n" } };

struct Probe
{
	int a = 0;
	int b = 0;
};
const FieldParse kProbeTable[] = {
	{ "A", INI::parseInt, nullptr, (int)offsetof(Probe, a) },
	{ nullptr, nullptr, nullptr, 0 },
};
const FieldParse kProbeBfme1Rows[] = {
	{ "B", INI::parseInt, nullptr, (int)offsetof(Probe, b) },
	{ nullptr, nullptr, nullptr, 0 },
};
const Bfme1FieldRowsRegistration kProbeRegistration(kProbeTable, kProbeBfme1Rows);

std::string loadProbe(initest::Fixture &fx, Probe &probe, const std::string &text)
{
	fx.env.blocks.registerBlock("Probe", [&probe](INI *ini) { ini->initFromINI(&probe, kProbeTable); });
	return initest::loadError(fx.env, "probe.ini", text);
}

struct Bfme1ModuleWorld
{
	objtest::World world{ true };
	PlayerTemplateStore templates{ world.keys };
	TeamFactory teams;
	PlayerList players{ world.keys, templates, teams };
	std::unique_ptr<GameLogic> logic;
	std::unique_ptr<AIWorld> ai;

	Bfme1ModuleWorld()
	{
		LogicModules::registerAll(world.modules);
		world.fx.mount(kBfme1Legend);
		templates.registerBlock(world.fx.env.blocks);
		REQUIRE(world.load(logictest::kPlayerTemplates).empty());
		SkirmishSetup setup;
		setup.players.push_back({ "Alice", "FactionA", true, 0, 0, 0 });
		players.setupSkirmish(setup);
		logic = std::make_unique<GameLogic>(world.things, world.modules, players, RandomAlgorithm::ZH_CarryChain);
		AIWorldConfig config;
		config.pathfind = pathtest::testConfig();
		ai = std::make_unique<AIWorld>(*logic, config, world.fx.env.macros);
		ai->attach();
	}
	~Bfme1ModuleWorld()
	{
		logic->reset();
		ai.reset();
	}
	Object *make(const char *name)
	{
		const ThingTemplate *tmpl = world.get(name);
		REQUIRE(tmpl);
		return logic->newObject(tmpl, players.findPlayerWithName("Alice")->getDefaultTeam(), ObjectStatusMaskType{});
	}
};
} // namespace

TEST_CASE("bfme1 isolation: the data decides the game (SubsystemLegend.ini without SubsystemLegendExpansion1.ini), cached per environment")
{
	initest::Fixture none;
	CHECK_FALSE(none.env.bfme1Data());
	initest::Fixture bfme1(kBfme1Legend);
	CHECK(isBfme1Data(bfme1.fsys));
	CHECK(bfme1.env.bfme1Data());
	initest::Fixture rotwk(kRotwkLegends);
	CHECK_FALSE(isBfme1Data(rotwk.fsys));
	CHECK_FALSE(rotwk.env.bfme1Data());
	// lane SHELLFIX-1: BFME2 1.06 on its own (the BFME2 menu style's shell source): the legend alone, plus BFME2's AwardSystem.ini
	initest::Fixture bfme2({ { "Data\\INI\\Default\\SubsystemLegend.ini", "; legend\r\n" }, { "Data\\INI\\AwardSystem.ini", "; awards\r\n" } });
	CHECK_FALSE(isBfme1Data(bfme2.fsys));
	CHECK_FALSE(bfme2.env.bfme1Data());
	INIEnvironment noFs;
	CHECK_FALSE(noFs.bfme1Data());
}

TEST_CASE("bfme1 isolation: a table's BFME1 rows are found in BFME1 data only; RotWK data fails on them as retail does")
{
	const std::string text = "Probe\r\n  A = 1\r\n  B = 2\r\nEnd\r\n";
	{
		initest::Fixture rotwk(kRotwkLegends);
		Probe p;
		const std::string error = loadProbe(rotwk, p, text);
		CHECK(error.find("Unknown field 'B' in block 'Probe'") != std::string::npos);
	}
	{
		initest::Fixture bfme1(kBfme1Legend);
		Probe p;
		REQUIRE(loadProbe(bfme1, p, text).empty());
		CHECK(p.a == 1);
		CHECK(p.b == 2);
	}
	CHECK(Bfme1FieldRows(kProbeTable) == kProbeBfme1Rows);
	CHECK(Bfme1FieldRows(kProbeBfme1Rows) == nullptr);
}

TEST_CASE("bfme1 isolation: AudioEvent Control = RANDOM and the AudioSettings 3D buffer rows are BFME1's only")
{
	const std::string event = "AudioEvent DefaultSoundEffect\r\n  Volume = 100\r\nEnd\r\nAudioEvent Shout\r\n  Sounds = shout\r\n  Control = loop random\r\nEnd\r\n";
	{
		initest::Fixture rotwk(kRotwkLegends);
		AudioIniState state;
		state.registerBlocks(rotwk.env.blocks);
		// RotWK's names have no RANDOM (RW 0xD9DB70)
		CHECK(initest::loadError(rotwk.env, "events.ini", event).find("Token 'random' is not a valid member of the index list") != std::string::npos);
	}
	{
		initest::Fixture bfme1(kBfme1Legend);
		AudioIniState state;
		state.registerBlocks(bfme1.env.blocks);
		CHECK(initest::loadError(bfme1.env, "events.ini", event).empty());
	}
	const std::string settings = "AudioSettings\r\n  3DBufferLengthMS = 80\r\nEnd\r\n";
	{
		initest::Fixture rotwk(kRotwkLegends);
		AudioIniState state;
		state.registerBlocks(rotwk.env.blocks);
		CHECK(initest::loadError(rotwk.env, "settings.ini", settings).find("Unknown field '3DBufferLengthMS'") != std::string::npos);
	}
	{
		initest::Fixture bfme1(kBfme1Legend);
		AudioIniState state;
		state.registerBlocks(bfme1.env.blocks);
		CHECK(initest::loadError(bfme1.env, "settings.ini", settings).empty());
	}
}

TEST_CASE("bfme1 isolation: BFME1's castle flag row is refused in RotWK data, and templates carry the factory's game")
{
	const std::string castle = "Object Flag\n  KindOf = STRUCTURE\n  Behavior = CastleBehavior ModuleTag_Castle\n"
							   "    UseTheNewCastleSystemInsteadOfTheClunkyBuildList = Yes\n  End\nEnd\n";
	objtest::World rotwk;
	LogicModules::registerAll(rotwk.modules);
	rotwk.fx.mount(kRotwkLegends);
	CHECK(rotwk.load(castle).find("UseTheNewCastleSystemInsteadOfTheClunkyBuildList") != std::string::npos);
	objtest::World bfme1(true);
	LogicModules::registerAll(bfme1.modules);
	bfme1.fx.mount(kBfme1Legend);
	const std::string bfme1Error = bfme1.load(castle);
	REQUIRE_MESSAGE(bfme1Error.empty(), bfme1Error);
	REQUIRE(bfme1.get("Flag") != nullptr);
	CHECK(bfme1.get("Flag")->bfme1Data());
	REQUIRE(rotwk.load("Object Plain\n  KindOf = STRUCTURE\nEnd\n").empty());
	CHECK_FALSE(rotwk.get("Plain")->bfme1Data());
}

TEST_CASE("bfme1 isolation: legacy portal and bloodthirsty fields load only in BFME1")
{
	const initest::FileList bfme2Legend = { { "Data\\INI\\Default\\SubsystemLegend.ini", "; legend\r\n" },
		{ "Data\\INI\\AwardSystem.ini", "; BFME2\r\n" } };
	for (const auto &entry : std::vector<std::pair<std::string, std::string>>{
		{ "DynamicPortalBehaviour", "AllowKindOf = INFANTRY" },
		{ "DynamicPortalBehaviour", "RejectKindOf = CAVALRY" },
		{ "BloodthirstyUpdate", "NumToSacrifice = 5" },
		{ "BloodthirstyUpdate", "InitiateVoice2 = TestBattleChatter" } })
	{
		CAPTURE(entry.first);
		CAPTURE(entry.second);
		const std::string text = "Object TestLegacy\n  Behavior = " + entry.first + " ModuleTag_Test\n    " + entry.second + "\n  End\nEnd\n";
		for (const auto &legend : { bfme2Legend, kRotwkLegends })
		{
			objtest::World other;
			LogicModules::registerAll(other.modules);
			other.fx.mount(legend);
			CHECK(other.load(text).find("Unknown field '" + entry.second.substr(0, entry.second.find(' ')) + "'") != std::string::npos);
		}
		objtest::World bfme1(true);
		LogicModules::registerAll(bfme1.modules);
		bfme1.fx.mount(kBfme1Legend);
		const std::string error = bfme1.load(text);
		CHECK_MESSAGE(error.empty(), error);
	}
}

TEST_CASE("bfme1 isolation: legacy portal masks preserve ANY inclusion, rejection, empty masks and inheritance")
{
	Bfme1ModuleWorld fixture;
	REQUIRE(fixture.world.load(
		"Object Portal\n Behavior = DynamicPortalBehaviour ModuleTag_Portal\n"
		"  AllowKindOf = INFANTRY CAVALRY\n  RejectKindOf = MONSTER\n End\nEnd\n"
		"ChildObject EmptyPortal Portal\n ReplaceModule ModuleTag_Portal\n"
		" Behavior = DynamicPortalBehaviour ModuleTag_Empty\n  AllowKindOf = NONE\n End\n End\nEnd\n"
		"Object RejectPortal\n Behavior = DynamicPortalBehaviour ModuleTag_Portal\n RejectKindOf = CAVALRY\n End\nEnd\n"
		"Object DefaultPortal\n Behavior = DynamicPortalBehaviour ModuleTag_Portal\n End\nEnd\n"
		"Object NoKind\nEnd\n"
		"Object Foot\n KindOf = INFANTRY\nEnd\n"
		"Object Rider\n KindOf = CAVALRY\nEnd\n"
		"Object Beast\n KindOf = INFANTRY MONSTER\nEnd\n"
		"Object Building\n KindOf = STRUCTURE\nEnd\n").empty());
	const auto *parent = dynamic_cast<const DynamicPortalBehaviourModuleData *>(fixture.world.get("Portal")->behaviorModules().find("ModuleTag_Portal")->data.get());
	const auto *child = dynamic_cast<const DynamicPortalBehaviourModuleData *>(fixture.world.get("EmptyPortal")->behaviorModules().find("ModuleTag_Empty")->data.get());
	REQUIRE(parent);
	REQUIRE(child);
	REQUIRE(parent->m_objectFilter);
	REQUIRE(child->m_objectFilter);
	CHECK(ObjectFilterMatch::allows(*fixture.logic, *parent->m_objectFilter, *fixture.make("Foot"), nullptr));
	CHECK(ObjectFilterMatch::allows(*fixture.logic, *parent->m_objectFilter, *fixture.make("Rider"), nullptr));
	CHECK_FALSE(ObjectFilterMatch::allows(*fixture.logic, *parent->m_objectFilter, *fixture.make("Beast"), nullptr));
	CHECK_FALSE(ObjectFilterMatch::allows(*fixture.logic, *parent->m_objectFilter, *fixture.make("Building"), nullptr));
	CHECK_FALSE(ObjectFilterMatch::allows(*fixture.logic, *child->m_objectFilter, *fixture.make("Foot"), nullptr));
	Object *foot = fixture.make("Foot");
	ObjectPathfindAdapter footAdapter(*fixture.ai, *foot);
	ObjectPathfindAdapter riderAdapter(*fixture.ai, *fixture.make("Rider"));
	ObjectPathfindAdapter noKindAdapter(*fixture.ai, *fixture.make("NoKind"));
	auto *rejectPortal = DynamicPortalBehaviour::of(*fixture.make("RejectPortal"));
	auto *defaultPortal = DynamicPortalBehaviour::of(*fixture.make("DefaultPortal"));
	REQUIRE(rejectPortal);
	REQUIRE(defaultPortal);
	const auto rejectFilter = rejectPortal->waypointFilter();
	const auto defaultFilter = defaultPortal->waypointFilter();
	CHECK(rejectFilter(footAdapter));
	CHECK_FALSE(rejectFilter(riderAdapter));
	CHECK(defaultFilter(footAdapter));
	CHECK_FALSE(defaultFilter(noKindAdapter));
	const int mounted = ModelCondition::indexOf("MOUNTED");
	REQUIRE(mounted != -1);
	foot->setModelConditionState(mounted, true);
	CHECK_FALSE(rejectFilter(footAdapter));
	CHECK(defaultFilter(footAdapter));
	foot->setModelConditionState(mounted, false);
	CHECK(rejectFilter(footAdapter));
}

TEST_CASE("bfme1 isolation: bloodthirsty retains the legacy count and plays both initiation voices")
{
	Bfme1ModuleWorld fixture;
	REQUIRE(fixture.world.load(
		"Object Singer\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" SacrificeFilter = ALL\n NumToSacrifice = 5\n InitiateVoice = TestJoin\n InitiateVoice2 = TestChatter\n End\nEnd\n"
		"Object SecondOnly\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice2 = TestChatter\n End\nEnd\n").empty());
	const auto *data = dynamic_cast<const BloodthirstyUpdateModuleData *>(fixture.world.get("Singer")->behaviorModules().find("ModuleTag_Blood")->data.get());
	REQUIRE(data);
	CHECK(data->m_numToSacrifice == 5);
	const auto *defaults = dynamic_cast<const BloodthirstyUpdateModuleData *>(fixture.world.get("SecondOnly")->behaviorModules().find("ModuleTag_Blood")->data.get());
	REQUIRE(defaults);
	CHECK(defaults->m_numToSacrifice == 1);
	struct Sink : UnitVoiceResponse::Sink
	{
		std::vector<std::string> sounds;
		bool soundExists(const std::string &) override { return true; }
		void playSound(const std::string &name, ObjectID, int) override { sounds.push_back(name); }
		void reportEva(const std::string &, const Coord3D *) override {}
	} sink;
	UnitVoiceResponse voices(*fixture.logic, sink);
	Object *singer = fixture.make("Singer");
	REQUIRE(BloodthirstyUpdate::find(*singer));
	CHECK(voices.pickAndPlay({ singer->getID() }, UnitVoiceResponse::VOICE_EVENT_BLOODTHIRSTY));
	CHECK(sink.sounds == std::vector<std::string>{ "TestJoin", "TestChatter" });
	sink.sounds.clear();
	CHECK(voices.pickAndPlay({ fixture.make("SecondOnly")->getID() }, UnitVoiceResponse::VOICE_EVENT_BLOODTHIRSTY));
	CHECK(sink.sounds == std::vector<std::string>{ "TestChatter" });
}

TEST_CASE("bfme1 isolation: bloodthirsty voice buckets count ordered initiation sound pairs without case")
{
	Bfme1ModuleWorld fixture;
	REQUIRE(fixture.world.load(
		"Object Singer\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = TestJoin\n InitiateVoice2 = TestChatter\n End\nEnd\n"
		"Object OtherSecond\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = TestJoin\n InitiateVoice2 = OtherChatter\n End\nEnd\n"
		"Object CasePair\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = testjoin\n InitiateVoice2 = testchatter\n End\nEnd\n"
		"Object OtherFirst\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = OtherJoin\n InitiateVoice2 = TestChatter\n End\nEnd\n"
		"Object Reversed\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = TestChatter\n InitiateVoice2 = TestJoin\n End\nEnd\n"
		"Object FirstOnly\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice = TestJoin\n End\nEnd\n"
		"Object SecondOnly\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice2 = TestChatter\n End\nEnd\n"
		"Object OtherSecondOnly\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice2 = OtherChatter\n End\nEnd\n"
		"Object CaseSecondOnly\n KindOf = INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n"
		" InitiateVoice2 = testchatter\n End\nEnd\n").empty());
	struct Sink : UnitVoiceResponse::Sink
	{
		std::vector<std::string> sounds;
		bool soundExists(const std::string &) override { return true; }
		void playSound(const std::string &name, ObjectID, int) override { sounds.push_back(name); }
		void reportEva(const std::string &, const Coord3D *) override {}
	} sink;
	UnitVoiceResponse voices(*fixture.logic, sink);
	Object *speaker = fixture.make("Singer");
	std::vector<ObjectID> selected;
	std::vector<std::string> expected = { "TestJoin", "TestChatter" };
	SUBCASE("same first voice, different second voices")
	{
		selected = { fixture.make("OtherSecond")->getID(), speaker->getID(), fixture.make("Singer")->getID() };
	}
	SUBCASE("both sound names compare without case")
	{
		selected = { fixture.make("OtherSecond")->getID(), speaker->getID(), fixture.make("CasePair")->getID() };
	}
	SUBCASE("same second voice, different first voices")
	{
		selected = { fixture.make("OtherFirst")->getID(), speaker->getID(), fixture.make("Singer")->getID() };
	}
	SUBCASE("slot order matters")
	{
		selected = { fixture.make("Reversed")->getID(), speaker->getID(), fixture.make("Singer")->getID() };
	}
	SUBCASE("a missing second voice stays separate")
	{
		selected = { fixture.make("FirstOnly")->getID(), speaker->getID(), fixture.make("Singer")->getID() };
	}
	SUBCASE("second-only voices stay separate and compare without case")
	{
		speaker = fixture.make("SecondOnly");
		selected = { fixture.make("OtherSecondOnly")->getID(), speaker->getID(), fixture.make("CaseSecondOnly")->getID() };
		expected = { "TestChatter" };
	}
	REQUIRE(voices.pickAndPlay(selected, UnitVoiceResponse::VOICE_EVENT_BLOODTHIRSTY));
	CHECK(voices.last().count == 2);
	CHECK(voices.last().object == speaker->getID());
	CHECK(sink.sounds == expected);
}

TEST_CASE("bfme1 isolation: bloodthirsty awards experience on each sacrifice, not at the legacy count")
{
	struct Levels
	{
		ExperienceLevelSystem levels;
		ExperienceLevelSystem *saved = TheExperienceLevelSystem;
		Levels() { TheExperienceLevelSystem = &levels; }
		~Levels() { TheExperienceLevelSystem = saved; }
	} experience;
	Bfme1ModuleWorld fixture;
	experience.levels.registerBlocks(fixture.world.fx.env.blocks);
	REQUIRE(fixture.world.load(
		"ExperienceLevel TestLevel\n TargetNames = Sacrificer Victim\n RequiredExperience = 1\n ExperienceAward = 10\n Rank = 1\nEnd\n"
		"ExperienceLevel TestLevel2\n TargetNames = Sacrificer Victim\n RequiredExperience = 1000\n Rank = 2\nEnd\n"
		"Object Sacrificer\n KindOf = HORDE INFANTRY\n Behavior = AIUpdateInterface ModuleTag_AI\n End\n"
		" Behavior = BloodthirstyUpdate ModuleTag_Blood\n SacrificeFilter = ALL\n NumToSacrifice = 5\n End\nEnd\n"
		"Object Victim\n KindOf = HORDE INFANTRY\n Behavior = BloodthirstyUpdate ModuleTag_Blood\n End\nEnd\n").empty());
	Object *source = fixture.make("Sacrificer");
	Object *victim = fixture.make("Victim");
	fixture.logic->experience().update();
	BloodthirstyUpdate *module = BloodthirstyUpdate::find(*source);
	REQUIRE(module);
	REQUIRE(source->getExperienceTracker());
	module->sacrificeHorde(victim, CMD_FROM_PLAYER);
	REQUIRE(module->isValidSacrifice(victim));
	const float before = source->getExperienceTracker()->getExperience();
	module->addSacrifice(victim);
	CHECK(module->kills() == 1);
	const float first = source->getExperienceTracker()->getExperience();
	CHECK(first == before + 10.0f);
	module->addSacrifice(victim);
	CHECK(module->kills() == 2);
	CHECK(source->getExperienceTracker()->getExperience() == first + 10.0f);
	module->cancelSacrifice();
	CHECK(module->kills() == 0);
	CHECK(module->bestTargetID() == INVALID_ID);
}

TEST_CASE("bfme1 isolation retail: installed BFME1 object world loads without aborted files")
{
	const char *install = std::getenv("BFME1_INSTALL");
	if (!install || !*install)
	{
		retailtest::printSkip("BFME1 object loading (BFME1_INSTALL unset)");
		return;
	}
	const std::filesystem::path root = std::filesystem::u8path(install);
	std::vector<std::string> names;
	for (const auto &entry : std::filesystem::recursive_directory_iterator(root))
	{
		if (!entry.is_regular_file() || entry.path().filename().u8string().rfind("!!!", 0) == 0)
		{
			continue;
		}
		std::string extension = entry.path().extension().u8string();
		std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char value) { return std::tolower(value); });
		if (extension == ".big") names.push_back(entry.path().lexically_relative(root).u8string());
	}
	Win32BIGFileSystem fs;
	std::string error;
	for (const auto &name : BFMEArchiveLoadOrder(names))
	{
		auto archive = fs.openArchiveFile((root / std::filesystem::u8path(name)).u8string(), &error);
		REQUIRE_MESSAGE(archive, error);
		fs.mountArchive(std::move(archive), name, false);
	}
	REQUIRE(isBfme1Data(fs));
	RetailObjectWorld world(fs);
	REQUIRE_MESSAGE(world.load(&error), error);
	for (const auto &failure : world.report().errors)
	{
		INFO(failure.file);
		CHECK_MESSAGE(false, failure.message);
	}
	CHECK(world.things().findTemplate("GondorCastleUpgrade") != nullptr);
	CHECK(world.things().findTemplate("MinisWallAUpgrade") != nullptr);
	std::printf("BFME1 object loading: %zu templates, %zu errors\n", world.things().templateCount(), world.report().errors.size());
}

TEST_CASE("bfme1 isolation: S-5017 names BFME1 mode's inferences and is registered")
{
	const std::vector<std::string> lines = bfme1StopLines();
	REQUIRE(lines.size() == 1);
	CHECK(lines[0].rfind("[S-5017] ", 0) == 0);
	CHECK(lines[0].find("victory rule") != std::string::npos);
	std::ifstream in(std::string(OPENBFME_DOCS_DIR) + "/STOPS.md", std::ios::binary);
	REQUIRE(in);
	const std::string doc((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	CHECK(doc.find("| S-5017 | code |") != std::string::npos);
}

TEST_CASE("bfme1 isolation: the W3D model layout is the file system's, whatever the process flag says (Sol review r2)")
{
	// the simulation's asset manager (launch bones) reads through an ArchiveW3DFileSource: its layout must follow its own files
	struct Flag
	{
		bool was = bfme1Mounted();
		~Flag() { setBfme1Mounted(was); }
	} restore;
	CHECK(W3D_Asset_Path("FooBar", false) == "art\\w3d\\fo\\foobar.w3d");
	CHECK(W3D_Asset_Path("FooBar", true) == "art\\w3d\\foobar.w3d");
	{
		setBfme1Mounted(true);
		initest::Fixture rotwk(kRotwkLegends);
		ArchiveW3DFileSource source(rotwk.fsys);
		CHECK_FALSE(source.FlatAssetLayout());
		WW3DAssetManager assets(source);
		std::string error;
		CHECK(assets.Get_HTree("FooBar", &error) == nullptr);
		CHECK(error.find("art\\w3d\\fo\\foobar.w3d") != std::string::npos);
	}
	{
		setBfme1Mounted(false);
		initest::Fixture bfme1(kBfme1Legend);
		ArchiveW3DFileSource source(bfme1.fsys);
		CHECK(source.FlatAssetLayout());
		WW3DAssetManager assets(source);
		std::string error;
		CHECK(assets.Get_HTree("FooBar", &error) == nullptr);
		CHECK(error.find("art\\w3d\\foobar.w3d") != std::string::npos);
	}
	CHECK(Resolve_W3D_Texture("Grass.tga", [](const std::string &p) { return p == "art\\textures\\grass.dds"; }, true).Found);
	CHECK_FALSE(Resolve_W3D_Texture("Grass.tga", [](const std::string &p) { return p == "art\\textures\\grass.jpg"; }, false).Found);
}

// lane SHELLFIX-1: the BFME2 main menu style's shell source is BFME2 1.06's archives alone. Read as BFME1 data, its menu models (Options.apt's and the
// main menu's View3D SFE_MenuFrame ...) were looked for in BFME1's flat art\w3d\ and never drew ("render object SFE_MenuFrame is not registered")
TEST_CASE("bfme1 isolation retail: BFME2 1.06's archives alone are BFME2 data; their menu models are found in its two-letter folders")
{
	retailtest::Mount *bfme2 = retailtest::bfme2Mount();
	if (!bfme2)
	{
		retailtest::printSkip("bfme1 isolation retail (BFME2_INSTALL unset)");
		return;
	}
	REQUIRE_MESSAGE(bfme2->fs, bfme2->error);
	CHECK_FALSE(isBfme1Data(*bfme2->fs));
	ArchiveW3DFileSource source(*bfme2->fs);
	CHECK_FALSE(source.FlatAssetLayout());
	CHECK(W3D_Asset_Path("sfe_menuframe", source.FlatAssetLayout()) == "art\\w3d\\sf\\sfe_menuframe.w3d");
	CHECK(source.Exists(W3D_Asset_Path("sfe_menuframe", source.FlatAssetLayout())));
	retailtest::Mount *pure = retailtest::pureMount();
	REQUIRE(pure);
	REQUIRE_MESSAGE(pure->fs, pure->error);
	CHECK_FALSE(isBfme1Data(*pure->fs));
}
