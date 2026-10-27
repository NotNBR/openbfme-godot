// OpenBFME unit tests: lane SDK-2, a mod's Luau scripts in the game: the mount's identity line, the script host's events and lockstep.
// GPL-3.0. Every mod, script and world here is written by the test.

#include "doctest.h"
#include "BigTestUtil.h"
#include "LogicTestUtil.h"

#include "Common/ModMount.h"
#include "Common/Money.h"
#include "Common/Player.h"
#include "GameEngineDevice/Win32Device/Common/Win32BIGFileSystem.h"
#include "GameLogic/Module/LogicModules.h"
#include "GameLogic/Sdk/SdkScriptHost.h"
#include "GameNetwork/ProfileIdentity.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <random>

using namespace bigtest;
using namespace logictest;
namespace fs = std::filesystem;

namespace
{

struct TempDir
{
	fs::path path;
	TempDir()
	{
		std::mt19937_64 rng((unsigned long long)std::chrono::steady_clock::now().time_since_epoch().count());
		path = fs::temp_directory_path() / ("openbfme-sdk2-" + std::to_string(rng()));
		fs::create_directories(path);
	}
	~TempDir()
	{
		std::error_code ec;
		fs::remove_all(path, ec);
	}
};

void writeFile(const fs::path &p, const std::string &bytes)
{
	fs::create_directories(p.parent_path());
	std::ofstream out(p, std::ios::binary);
	out.write(bytes.data(), (std::streamsize)bytes.size());
}

std::string joined(const std::vector<std::string> &v)
{
	std::string out;
	for (const std::string &s : v)
		out += s + "\n";
	return out;
}

const char kManifest[] = R"({"sdk": 1, "name": "Income", "sim": ["income"], "presentation": ["banner"]})";

// every 30 frames each player gets 100 + a synchronized random 1 .. 10; it counts the objects it saw created and prints at frame 60
const char kIncome[] = R"(
local created = 0
function onGameStart() print("start at frame " .. game.frame() .. ", players " .. game.playerCount()) end
function onObjectCreated(id, template, player) created += 1 end
function onFrame(frame)
	if frame % 30 == 0 then
		for i = 0, game.playerCount() - 1 do game.addMoney(i, 100 + math.random(1, 10)) end
	end
	if frame == 60 then print("frame 60: created " .. created .. ", money " .. game.money(0) .. " / " .. game.money(1)) end
end
)";

struct MountedMod
{
	TempDir tmp;
	Win32BIGFileSystem fsys;
	ModMountReport report;
	explicit MountedMod(const std::map<std::string, std::string> &files)
	{
		const fs::path mod = tmp.path / "IncomeMod";
		for (const auto &f : files)
			writeFile(mod / f.first, f.second);
		std::string error;
		auto base = fsys.openArchiveFromMemory("rotwk/INI.big",
			std::make_shared<const std::vector<std::uint8_t>>(makeBig("BIGF", { { "data\\ini\\a.ini", "retail-a" } })), &error);
		REQUIRE_MESSAGE(base, error);
		fsys.mountArchive(std::move(base), "rotwk/INI.big", false);
		ModOperand op;
		op.dir = mod.u8string() + "/";
		ModMountOptions options;
		options.rotwkInstallRoot = (tmp.path / "install").u8string();
		fs::create_directories(options.rotwkInstallRoot);
		report = MountRetailMod(fsys, op, options);
	}
	std::string sdkLine() const
	{
		for (const std::string &l : report.identity)
			if (l.rfind("sdk ", 0) == 0)
				return l;
		return "";
	}
	std::string content() const
	{
		for (const std::string &l : report.identity)
			if (l.rfind("modcontent ", 0) == 0)
				return l;
		return "";
	}
};

const char kObjects[] =
	"Object Fighter\n"
	"  Body = ActiveBody ModuleTag_Body\n"
	"    MaxHealth = 100\n"
	"  End\n"
	"End\n";

struct World : LogicWorld
{
	World()
	{
		REQUIRE_MESSAGE(loadError.empty(), loadError);
		LogicModules::registerAll(w.modules);
		const std::string err = w.load(kObjects);
		REQUIRE_MESSAGE(err.empty(), err);
		logic->settings().bodyThresholdsLoaded = true;
		logic->settings().unitDamagedThreshold = 0.65f;
		logic->settings().unitReallyDamagedThreshold = 0.4f;
	}
};

} // namespace

TEST_CASE("SDK-2: a mod's sim scripts are an identity line naming the mod; its presentation scripts are not in the identity at all")
{
	const std::map<std::string, std::string> files = { { "openbfme/sdk/mod.json", kManifest }, { "openbfme/sdk/sim/income.luau", kIncome },
		{ "openbfme/sdk/presentation/banner.luau", "print('banner')" }, { "data/ini/a.ini", "mod-a" } };
	MountedMod a(files);
	REQUIRE_MESSAGE(a.report.ok, joined(a.report.errors));
	CHECK(a.report.sdkName == "Income");
	CHECK(a.sdkLine() == "sdk sim " + a.report.sdkSimFingerprint);
	CHECK(a.report.sdkSimFingerprint.size() == 64);
	CHECK(a.content().find(" 2 files ") != std::string::npos); // the sim script and a.ini: not the banner, not the manifest (its sim part is the sdk line)

	auto changed = files;
	changed["openbfme/sdk/presentation/banner.luau"] = "print('another banner')";
	changed["openbfme/sdk/presentation/more.luau"] = "x";
	MountedMod b(changed);
	REQUIRE(b.report.ok);
	CHECK(b.report.identity == a.report.identity); // presentation scripts never stop a game or a replay
	auto relisted = files;
	relisted["openbfme/sdk/mod.json"] = R"({"sdk": 1, "name": "Income", "sim": ["income"], "presentation": ["banner", "more"]})";
	relisted["openbfme/sdk/presentation/more.luau"] = "x";
	MountedMod b2(relisted);
	REQUIRE(b2.report.ok);
	CHECK(b2.report.identity == a.report.identity); // nor does the manifest's presentation list (Sol r1)

	changed = files;
	changed["openbfme/sdk/sim/income.luau"] = std::string(kIncome) + "\n-- tuned";
	MountedMod c(changed);
	REQUIRE(c.report.ok);
	CHECK(c.sdkLine() != a.sdkLine());
	const ProfileIdentity pa = ProfileIdentity::compute({}, RandomAlgorithm::ZH_CarryChain, {}, SimulationProfile::Faithful, a.report.identity);
	const ProfileIdentity pc = ProfileIdentity::compute({}, RandomAlgorithm::ZH_CarryChain, {}, SimulationProfile::Faithful, c.report.identity);
	CHECK(pa.digest != pc.digest);
	const std::string why = ProfileIdentity::difference(pa, pc);
	CHECK(why.find("ours: 'sdk sim " + a.report.sdkSimFingerprint + "'") != std::string::npos); // the lobby's / replay's refusal quotes the scripts' line

	MountedMod d({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Broken", "sim": ["missing"]})" } });
	CHECK_FALSE(d.report.ok);
	CHECK(joined(d.report.errors).find("mod: openbfme/sdk/mod.json: the sim script 'missing' is not in the mod") != std::string::npos);

	MountedMod e({ { "data/ini/a.ini", "no scripts" } });
	REQUIRE(e.report.ok);
	CHECK(e.sdkLine().empty()); // a mod without scripts: the identity of every build before SDK-2
}

TEST_CASE("SDK-2: the sim scripts run in lockstep: two identical games hash alike every frame, and the scripts changed them")
{
	MountedMod mod({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Income", "sim": ["income"]})" }, { "openbfme/sdk/sim/income.luau", kIncome } });
	REQUIRE_MESSAGE(mod.report.ok, joined(mod.report.errors));
	MountedMod noBanner({ { "openbfme/sdk/mod.json", kManifest }, { "openbfme/sdk/sim/income.luau", kIncome } });
	CHECK_FALSE(noBanner.report.ok); // the manifest lists a presentation script the mod does not have
	CHECK(joined(noBanner.report.errors).find("the presentation script 'banner' is not in the mod") != std::string::npos);
	World a, b, plain;
	SdkScriptHost ha(*a.logic), hb(*b.logic);
	std::string error;
	REQUIRE_MESSAGE(ha.start(mod.fsys.modLooseLayer(), error), error);
	REQUIRE_MESSAGE(hb.start(mod.fsys.modLooseLayer(), error), error);
	CHECK(ha.active());
	for (World *w : { &a, &b, &plain })
	{
		w->make("Fighter", w->teamOf("Alice"));
		w->make("Fighter", w->teamOf("Bob"));
	}
	const std::uint32_t moneyBefore = a.players.findPlayerWithName("Alice")->getMoney()->countMoney();
	for (int frame = 1; frame <= 90; ++frame)
	{
		a.logic->runLogicFrame();
		b.logic->runLogicFrame();
		plain.logic->runLogicFrame();
		REQUIRE(a.logic->computeStateHash() == b.logic->computeStateHash());
		if (frame == 45)
		{
			a.make("Fighter", a.teamOf("Alice")); // the same input on both peers
			b.make("Fighter", b.teamOf("Alice"));
		}
	}
	CHECK(a.logic->computeStateHash() != plain.logic->computeStateHash()); // the scripts did change the game
	CHECK(ha.reports() == hb.reports());
	REQUIRE(ha.reports().size() == 3);
	CHECK(ha.reports()[0] == "SDK Income: this game cannot be saved: a mod's sim scripts are not saved yet");
	CHECK(ha.reports()[1] == "SDK Income: start at frame 1, players " + std::to_string(a.players.getPlayerCount()));
	const std::uint32_t alice = a.players.findPlayerWithName("Alice")->getMoney()->countMoney();
	// the three Fighters were all created by frame 60 (two before the first frame, one at frame 45)
	CHECK(ha.reports()[2].rfind("SDK Income: frame 60: created 3, money ", 0) == 0);
	CHECK(alice > moneyBefore + 300); // tolerance: three paydays of 100 + 1 .. 10 (frames 30, 60, 90)
	CHECK(alice <= moneyBefore + 330); // tolerance: as above
	CHECK(ha.calls() == hb.calls());
	CHECK(ha.steps() == hb.steps());
	CHECK_FALSE(ha.stopped());
	// Sol r1: a running script VM is not saved yet: the save is refused naming the mod's scripts, and the players were told at the start
	std::vector<std::uint8_t> snapshot;
	std::string why;
	CHECK_FALSE(a.logic->saveSnapshot(snapshot, &why));
	CHECK(why.find("obfme:SdkScripts (the sim scripts of the mod Income)") != std::string::npos);
	std::vector<std::uint8_t> plainSnapshot;
	CHECK_MESSAGE(plain.logic->saveSnapshot(plainSnapshot, &why), why); // the same game without the mod saves
}

TEST_CASE("SDK-2: a sim script error stops that mod's scripts at the same frame on every peer, reported with the mod's name")
{
	const char kBoom[] = "function onFrame(f) if f == 20 then error('boom at ' .. f) end end";
	MountedMod mod({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Boom", "sim": ["boom"]})" }, { "openbfme/sdk/sim/boom.luau", kBoom } });
	REQUIRE_MESSAGE(mod.report.ok, joined(mod.report.errors));
	World a, b;
	SdkScriptHost ha(*a.logic), hb(*b.logic);
	std::string error;
	REQUIRE(ha.start(mod.fsys.modLooseLayer(), error));
	REQUIRE(hb.start(mod.fsys.modLooseLayer(), error));
	for (int frame = 1; frame <= 30; ++frame)
	{
		a.logic->runLogicFrame();
		b.logic->runLogicFrame();
		REQUIRE(a.logic->computeStateHash() == b.logic->computeStateHash());
	}
	CHECK(ha.stopped());
	CHECK(ha.reports() == std::vector<std::string>{ "SDK Boom: this game cannot be saved: a mod's sim scripts are not saved yet",
							  "SDK Boom: openbfme/sdk/sim/boom.luau:1: boom at 20 (frame 20; the mod's scripts are stopped)" });
	CHECK(ha.reports() == hb.reports());

	MountedMod bad({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Bad", "sim": ["bad"]})" }, { "openbfme/sdk/sim/bad.luau", "this is not luau" } });
	REQUIRE(bad.report.ok);
	World c;
	SdkScriptHost hc(*c.logic);
	CHECK_FALSE(hc.start(bad.fsys.modLooseLayer(), error)); // a script that does not load stops the start
	CHECK(error.rfind("SDK Bad: openbfme/sdk/sim/bad.luau:1:", 0) == 0);
}

TEST_CASE("SDK-2: presentation scripts show banners, may differ between peers, and never change the game")
{
	const char kSim[] = "function onFrame(f) if f % 10 == 0 then game.addMoney(0, 5) end end";
	const char kQuiet[] = "function onGameStart() ui.banner('hello ' .. game.playerName(game.localPlayer())) end";
	// a busy one: its own random draws, work every frame, a banner every 10 frames, and no addMoney (it has none)
	const char kBusy[] = R"(
local t = {}
function onFrame(f)
	for i = 1, 200 do t[i] = math.random() * i end
	if f % 10 == 0 then ui.banner(string.format('frame %d, you have %d', f, game.money(game.localPlayer()))) end
	if f == 25 then print(type(game.addMoney)) end
end)";
	auto mod = [&](const char *presentation) {
		return std::map<std::string, std::string>{ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Look", "sim": ["s"], "presentation": ["p"]})" },
			{ "openbfme/sdk/sim/s.luau", kSim }, { "openbfme/sdk/presentation/p.luau", presentation } };
	};
	MountedMod quiet(mod(kQuiet)), busy(mod(kBusy));
	REQUIRE_MESSAGE(quiet.report.ok, joined(quiet.report.errors));
	REQUIRE(busy.report.ok);
	CHECK(quiet.report.identity == busy.report.identity); // the same game for the lobby
	World a, b;
	a.players.setLocalPlayer(a.players.findPlayerWithName("Alice"));
	b.players.setLocalPlayer(b.players.findPlayerWithName("Bob"));
	SdkScriptHost ha(*a.logic), hb(*b.logic);
	std::string error;
	REQUIRE_MESSAGE(ha.start(quiet.fsys.modLooseLayer(), error), error);
	REQUIRE_MESSAGE(hb.start(busy.fsys.modLooseLayer(), error), error);
	CHECK(ha.presentationActive());
	std::vector<std::string> bannersA, bannersB;
	for (int frame = 1; frame <= 30; ++frame)
	{
		a.logic->runLogicFrame();
		b.logic->runLogicFrame();
		REQUIRE(a.logic->computeStateHash() == b.logic->computeStateHash());
		for (const std::string &s : ha.takeBanners())
			bannersA.push_back(s);
		for (const std::string &s : hb.takeBanners())
			bannersB.push_back(s);
	}
	const std::string unsaved = "Look: this game cannot be saved (its scripts are not saved yet)";
	CHECK(bannersA == std::vector<std::string>{ unsaved, "hello Alice" });
	const std::uint32_t bobMoney = b.players.findPlayerWithName("Bob")->getMoney()->countMoney();
	CHECK(bannersB == std::vector<std::string>{ unsaved, "frame 10, you have " + std::to_string(bobMoney), "frame 20, you have " + std::to_string(bobMoney),
						  "frame 30, you have " + std::to_string(bobMoney) });
	CHECK(hb.takeNewReports() == std::vector<std::string>{ "SDK Look: this game cannot be saved: a mod's sim scripts are not saved yet",
								 "SDK presentation Look: nil" }); // a presentation script cannot pay anyone
	CHECK(ha.calls() == hb.calls()); // only the sim script's calls count
}

TEST_CASE("SDK-2 (Anti-cheat pin 3): a presentation script reaches no logic state: no writes, not the logic's generator, not the state hash")
{
	// every way in it might try: the sim API's write, a write into the read-only game table, a new global named like the sim one, its own
	// math.random (heavily) and a failed script: each is refused or stays in its own state, and the game is the one without it
	const std::vector<std::string> attempts = { "function onFrame(f) game.addMoney(0, 1000) end", "function onFrame(f) game.addMoney = 1 end",
		"function onFrame(f) rawset(game, 'addMoney', print) end", "function onFrame(f) for i = 1, 500 do math.random() end end",
		"function onFrame(f) error('presentation boom') end" };
	for (const std::string &attempt : attempts)
	{
		CAPTURE(attempt);
		MountedMod mod({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Sneaky", "presentation": ["p"]})" }, { "openbfme/sdk/presentation/p.luau", attempt } });
		REQUIRE_MESSAGE(mod.report.ok, joined(mod.report.errors));
		CHECK(mod.report.sdkSimFingerprint.empty()); // presentation only: the identity of a mod without scripts
		World a, plain;
		SdkScriptHost ha(*a.logic);
		std::string error;
		REQUIRE_MESSAGE(ha.start(mod.fsys.modLooseLayer(), error), error);
		CHECK(ha.presentationActive());
		for (int frame = 1; frame <= 20; ++frame)
		{
			a.logic->runLogicFrame();
			plain.logic->runLogicFrame();
			REQUIRE(a.logic->computeStateHash() == plain.logic->computeStateHash()); // the logic RNG and money included
		}
		CHECK(a.players.findPlayerWithName("Alice")->getMoney()->countMoney() == plain.players.findPlayerWithName("Alice")->getMoney()->countMoney());
		CHECK(ha.calls() == 0); // only sim calls are counted (and hashed)
	}
}

TEST_CASE("SDK-2 (Sol r4): mods that differ only in their manifest name are the same game, and their sim scripts cannot tell them apart")
{
	const char kSim[] = "function onFrame(f) game.addMoney(0, sdk.mod == nil and 100 or 200) end";
	MountedMod a({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "A", "sim": ["s"]})" }, { "openbfme/sdk/sim/s.luau", kSim } });
	MountedMod b({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "B", "sim": ["s"]})" }, { "openbfme/sdk/sim/s.luau", kSim } });
	REQUIRE(a.report.ok);
	REQUIRE(b.report.ok);
	CHECK(a.report.identity == b.report.identity);
	World wa, wb;
	SdkScriptHost ha(*wa.logic), hb(*wb.logic);
	std::string error;
	REQUIRE(ha.start(a.fsys.modLooseLayer(), error));
	REQUIRE(hb.start(b.fsys.modLooseLayer(), error));
	for (int frame = 1; frame <= 10; ++frame)
	{
		wa.logic->runLogicFrame();
		wb.logic->runLogicFrame();
		REQUIRE(wa.logic->computeStateHash() == wb.logic->computeStateHash());
	}
}

TEST_CASE("SDK-2 (Sol r4 follow-up): a presentation script that defines the sim script's globals changes nothing of the sim script")
{
	const char kSim[] = "local n = 0 function onFrame(f) n += 1 if n % 5 == 0 then game.addMoney(0, 10) end end";
	const char kClash[] = "n = 1000 function onFrame(f) n = -1; onFrame = nil end function addMoney() end";
	MountedMod with({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Clash", "sim": ["s"], "presentation": ["p"]})" },
		{ "openbfme/sdk/sim/s.luau", kSim }, { "openbfme/sdk/presentation/p.luau", kClash } });
	MountedMod without({ { "openbfme/sdk/mod.json", R"({"sdk": 1, "name": "Clash", "sim": ["s"]})" }, { "openbfme/sdk/sim/s.luau", kSim } });
	REQUIRE(with.report.ok);
	REQUIRE(without.report.ok);
	CHECK(with.report.identity == without.report.identity);
	World wa, wb;
	SdkScriptHost ha(*wa.logic), hb(*wb.logic);
	std::string error;
	REQUIRE(ha.start(with.fsys.modLooseLayer(), error));
	REQUIRE(hb.start(without.fsys.modLooseLayer(), error));
	for (int frame = 1; frame <= 20; ++frame)
	{
		wa.logic->runLogicFrame();
		wb.logic->runLogicFrame();
		REQUIRE(wa.logic->computeStateHash() == wb.logic->computeStateHash());
	}
	CHECK(ha.calls() == hb.calls());
}
