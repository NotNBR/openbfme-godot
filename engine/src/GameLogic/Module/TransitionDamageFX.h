// OpenBFME. GPL-3.0.
// Derived from Command & Conquer Generals Zero Hour, (c) 2001-2003 Electronic Arts Inc., GPL-3.0 (TransitionDamageFX.h / .cpp are the donors of the shape:
// the per-state FXList / OCL / particle system entries, getLocalEffectPos, onBodyDamageStateChange; every field and step below is RotWK's).
//
// Lane FX-4: the effects a building or a siege engine plays when its damage state gets worse (the burst of smoke, debris and the screen shake), and the
// sub objects each damage state shows or hides (gate doors, castle doors).
//
// TARGET FACTS (RotWK game.dat, caveat S-001; registry golden engine/data/rotwk-201/module-registry.json, field-tables.json):
//   * TransitionDamageFX: constructor RW 0x8BE533 (module vtable RW 0xC707A4, its DAMAGE interface table RW 0xC706D8 at module + 0x10: slot 0 / 1 the empty
//     stub RW 0x9F3A3C, slot 2 onBodyDamageStateChange RW 0x8BE077); module + 0x14: 4 x 12 particle system IDs (zeroed); module + 0xD4: the rubble neighbours.
//     xfer RW 0x8BDA2B: version, the behaviour module, then the 48 particle system IDs.
//   * TransitionDamageFXModuleData: constructor RW 0x8BE6D3 (vtable RW 0xC707D8), field table RW 0xC08D10 (120 rows, below). Per damage state s (0 PRISTINE ..
//     3 RUBBLE) and slot i (0 .. 11) three entries of 0x1C bytes: FXList (+0xC + s * 0x150 + i * 0x1C), OCL (+ 0x544 from it), ParticleSystem (+ 0xA88 from
//     it); each = { the FXList / OCL / template pointer, the location: + 4 byte type (0 bone, 1 offset; constructor 1), + 8 the bone name, + 0xC RandomBone
//     (constructor false), + 0x10 .. + 0x18 the offset (0) }. The rows name the states DAMAGED / REALLYDAMAGED / RUBBLE only (no Pristine row: state 0
//     stays empty). DamageFXTypes (+8), DamageOCLTypes (+0x54C), DamageParticleTypes (+0xA90): RW 0x73A5C9, a 32-bit mask that starts as ALL (0xFFFFFFFF);
//     each token: ALL, NONE, +NAME (set bit index - 1), -NAME (clear it), anything else throws "ALL, NONE, + or - expected"; the names are the 28 damage
//     types (RW 0xDA3960, the same pointers as RW 0xDA15A8 = TheDamageNames). Show / Hide sub object lists: Pristine / Damaged / ReallyDamaged / Rubble
//     HideSubObject (+0xFD4 + s * 0xC) and ShowSubObject (+0x1004 + s * 0xC), RW 0x42E59E (INI::parseAsciiStringVectorAppend). RubbleNeighbor (+0x1034,
//     RW 0x8BE960): tokens NeighborOffset X: Y: Z:, OCLOffset X: Y: Z:, OCL <name>, SubObject <name> (appended), any other throws "bad colon spacing, or
//     unexpected token in TransitionDamageFXModuleData::NeighborIDSubobjectNameDataAppend".
//   * The entry rows: RW 0x8BDBB5 (FXList), RW 0x8BDC21 (OCL), RW 0x8BDC8C (ParticleSystem). Each first parses the location (RW 0x8BDA75, the INI's colon
//     separators): `Bone <name> RandomBone <bool>` (a word other than RandomBone throws "parseFXLocInfo: Bone name not followed by RandomBone specifier.")
//     or `Loc X: <real> Y: <real> Z: <real>` (anything else throws "'loc' or 'bone' expected"); then the keyword FXList / OCL / PSys (else "'fxlist'
//     expected", "'ocl' expected", "'psys' expected"), then the name: parseFXList RW 0x73A302 (None stores NULL, an unknown name throws "iniParseFXList -
//     FXList %s not found!"), RW 0x73A368 (TheObjectCreationListStore lookup, NULL when unknown), RW 0x73AECB (the FXParticleSystem template; None or an
//     unknown name stores NULL, no error).
//   * onBodyDamageStateChange(info, old, new) RW 0x8BE077: nothing while the object has model condition 0x45 ACTIVELY_BEING_CONSTRUCTED (RW 0x46E918). The
//     damage source is TheGameLogic->findObjectByID(info + 8) when there is an info. The particle systems of the OLD state's 12 slots are destroyed
//     (RW 0x5F5379) and their IDs zeroed. The NEW state's sub object lists are applied (RW 0x8BDCF7, only when the object has a drawable: every Hide name
//     Drawable::showSubObject(name, false, permanent), then every Show name (name, true, permanent), RW 0x672823). When new > old, for i = 0 .. 11 in this
//     order: the FXList i, the OCL i, the particle system i of the new state, each when its pointer is set and (the body's last damage record (body
//     interface slot 0x40, ActiveBody: module + 0x40) is null, or bit (record + 0x10 damage type - 1) & 31 of its mask is set):
//       - FXList: pos = getLocalEffectPos (RW 0x8BDDAC), Object::convertBonePosToWorldPos(pos) (RW 0x70BCE7), FXList::doFXPos(fx, pos, null, 0, null) (RW
//         0x494615);
//       - OCL: the same position; ObjectCreationList::create(ocl, the object, pos, the damage source + 0x38 (its position), 0) (RW 0x5F00CA);
//       - particle system: createParticleSystem(template) (RW 0x5F526A); when made, pos = getLocalEffectPos (model space), setPosition (RW 0x5F2F2D),
//         attachToObject(the object) (RW 0x5F32D7), the ID is kept in slot [new][i].
//     Last, when old != new and one of them is RUBBLE: the rubble neighbours (RW 0x8BDF08).
//   * getLocalEffectPos RW 0x8BDDAC: a bone entry on an object with a drawable: RandomBone asks the drawable's pristine bones `name01`, `name02`, ... (RW
//     0x672A73 start index 1, at most 32); n > 0 picks GameLogicRandomValue(0, n - 1) ("TransitionDamageFX.cpp" line 0x153, RW 0x6D328E), n = 0 gives the
//     offset. Without RandomBone the bone `name` itself (start index 0, at most 1); not found gives the offset. Every other case gives the offset.
//
// THE PORT: the logic module runs RW 0x8BE077 in the logic frame, at the retail call (ActiveBody::attemptDamage / attemptHealing, lane FX-4). Its client calls
// go out as FX events (GameLogic/FXEvents.h): the FXList calls as POSITION_FX, the particle systems as ATTACH_PARTICLE_SYSTEM / DESTROY_PARTICLE_SYSTEM
// keyed by (object, slot); the client (LiveFX) keeps the system IDs, so the module has no state of its own (retail's 48 IDs live on the client side). The sub
// objects go through the object's client hooks (Drawable::showSubObject). The pristine bones are the launch bone provider's (DrawableLaunchBones, template
// data and logic state), as for the other logical bone queries.
// INFERENCE / NOT PORTED (stop S-686, reported by TransitionDamageFX::stops()):
//   * the drawable test of RW 0x8BDDAC / 0x8BDCF7 (RW 0x70E013) is taken as true for the bones (every retail logic object has a drawable; a peer without a
//     client must draw the same random numbers); the sub objects need the client hooks;
//   * FXList and particle system names are not checked against their stores at parse time (those stores are the client's: S-181 / S-190 practice); an
//     unknown particle system name, NULL in retail, still asks its location here (a RandomBone entry would draw where retail does not; no retail data has one);
//   * the OCL's secondary position (the damage source's position) is not handed to the CreateObject port (S-530); a call without a damage source, which
//     retail would make with an invalid pointer, is counted and not made;
//   * the rubble neighbours (RW 0x8BDF08: the neighbours' sub objects, their OCLs) need the wall Bookend machinery (S-342): parsed, counted when they would run.

#pragma once

#include "Common/INI.h"
#include "GameLogic/Module/DamageModule.h"

#include <cstdint>
#include <string>
#include <vector>

class TransitionDamageFXModuleData : public ModuleData
{
public:
	static constexpr int MAX_FX = 12; ///< DAMAGE_MODULE_MAX_FX

	enum LocType : std::uint8_t
	{
		LOC_BONE = 0,  ///< RW location + 0 = 0 (`Bone`)
		LOC_OFFSET = 1 ///< RW location + 0 = 1 (`Loc`, the constructor's value)
	};
	struct LocInfo
	{
		LocType type = LOC_OFFSET;
		std::string boneName;
		bool randomBone = false;
		Coord3D offset{ 0.0f, 0.0f, 0.0f };
	};
	// one FXList / OCL / particle system entry: the name as written ("" = none; parseFXList's and the template parser's None stores none; an OCL the store
	// does not hold stores none, RW 0x73A368)
	struct Entry
	{
		std::string name;
		LocInfo loc;
	};
	struct RubbleNeighbor
	{
		Coord3D neighborOffset{ 0.0f, 0.0f, 0.0f };
		Coord3D oclOffset{ 0.0f, 0.0f, 0.0f };
		std::string ocl;
		std::vector<std::string> subObjects;
	};

	std::uint32_t m_damageFXTypes = 0xFFFFFFFFu;       ///< +8
	Entry m_fxList[BODYDAMAGETYPE_COUNT][MAX_FX];      ///< +0xC
	std::uint32_t m_damageOCLTypes = 0xFFFFFFFFu;      ///< +0x54C
	Entry m_ocl[BODYDAMAGETYPE_COUNT][MAX_FX];         ///< +0x550
	std::uint32_t m_damageParticleTypes = 0xFFFFFFFFu; ///< +0xA90
	Entry m_particleSystem[BODYDAMAGETYPE_COUNT][MAX_FX]; ///< +0xA94
	std::vector<std::string> m_hideSubObjects[BODYDAMAGETYPE_COUNT]; ///< +0xFD4
	std::vector<std::string> m_showSubObjects[BODYDAMAGETYPE_COUNT]; ///< +0x1004
	std::vector<RubbleNeighbor> m_rubbleNeighbors;     ///< +0x1034

	static void buildFieldParse(MultiIniFieldParse &p);
	// RW 0x73A5C9's test as RW 0x8BE077 makes it: bit (type - 1) & 31 of the mask
	static bool damageTypeAllowed(std::uint32_t mask, int damageType) { return (mask >> ((unsigned)(damageType - 1) & 31u) & 1u) != 0; }
};

class TransitionDamageFX : public BehaviorModule, public DamageModuleInterface
{
public:
	OBFME_MODULE_XFER(TransitionDamageFX) // lane FX-4: BehaviorModule's (the particle system IDs are the client's)
	TransitionDamageFX(Thing *thing, const TransitionDamageFXModuleData *data) : BehaviorModule(thing, data), m_data(data) {}
	DamageModuleInterface *getDamage() override { return this; }
	void onDamage(const DamageInfo &) override {}  // RW 0x9F3A3C
	void onHealing(const DamageInfo &) override {} // RW 0x9F3A3C
	void onBodyDamageStateChange(const DamageInfo *info, BodyDamageType oldState, BodyDamageType newState) override; // RW 0x8BE077

	// the client key of slot (state, i) of this module: unique per object (the module's index among the object's modules)
	std::uint32_t particleSlot(int state, int i) const;

	struct Stats
	{
		unsigned long long transitions = 0;        ///< onBodyDamageStateChange calls that ran (not under construction)
		unsigned long long fxCalls = 0, oclCalls = 0, particleCalls = 0;
		unsigned long long oclWithoutSource = 0;   ///< an OCL call without a damage source (retail reads an invalid pointer; not made here)
		unsigned long long oclSecondaryDropped = 0; ///< OCL calls made without the source's position as the secondary position (S-530)
		unsigned long long rubbleNeighborsNotRun = 0; ///< RW 0x8BDF08 calls of a module with rubble neighbours (S-342)
		unsigned long long randomBoneDraws = 0;    ///< GameLogicRandomValue draws of RandomBone entries
	};
	static Stats &stats();
	static std::vector<std::string> stops();

private:
	// RW 0x8BDDAC getLocalEffectPos then (when `world`) RW 0x70BCE7
	Coord3D effectPos(const TransitionDamageFXModuleData::LocInfo &loc, bool world);
	const TransitionDamageFXModuleData *m_data;
};

class ModuleFactory;

namespace TransitionDamageFXModule
{
void registerClass(ModuleFactory &modules);
}
