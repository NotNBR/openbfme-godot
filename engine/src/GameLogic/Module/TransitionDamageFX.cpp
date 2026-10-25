// OpenBFME. GPL-3.0. See GameLogic/Module/TransitionDamageFX.h.

#include "GameLogic/Module/TransitionDamageFX.h"

#include "Common/AsciiString.h"
#include "Common/INIException.h"
#include "Common/Thing/ModuleFactory.h"
#include "GameLogic/Combat/CombatNames.h"
#include "GameLogic/Combat/CombatState.h"
#include "GameLogic/Combat/WeaponDelivery.h"
#include "GameLogic/Damage.h"
#include "GameLogic/FXEvents.h"
#include "GameLogic/GameLogic.h"
#include "GameLogic/Object/Object.h"
#include "GameLogic/ObjectCreationList.h"
#include "GameLogic/SnapshotXfer.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
using Data = TransitionDamageFXModuleData;

bool isWord(const char *token, const char *word)
{
	return token && AsciiStringUtil::compareNoCase(token, word) == 0;
}

// RW 0x8BDA75 parseFXLocInfo (the INI's colon separators, RW INI + 0x420)
void parseLocInfo(INI *ini, Data::LocInfo &loc)
{
	const char *kind = ini->getNextToken(ini->getSepsColon());
	if (isWord(kind, "bone"))
	{
		loc.boneName = ini->getNextToken();
		loc.type = Data::LOC_BONE;
		if (!isWord(ini->getNextToken(ini->getSepsColon()), "randombone"))
		{
			throw INIException(3, "parseFXLocInfo: Bone name not followed by RandomBone specifier.");
		}
		INI::parseBool(ini, nullptr, &loc.randomBone, nullptr); // RW 0x42E558
		return;
	}
	if (isWord(kind, "loc"))
	{
		loc.offset.x = ini->scanReal(ini->getNextSubToken("X"));
		loc.offset.y = ini->scanReal(ini->getNextSubToken("Y"));
		loc.offset.z = ini->scanReal(ini->getNextSubToken("Z"));
		loc.type = Data::LOC_OFFSET;
		return;
	}
	throw INIException(3, "'loc' or 'bone' expected");
}

// the row's kind and slot, carried in the FieldParse user data: kind * 64 + state * 16 + slot
enum RowKind
{
	ROW_FX = 0,
	ROW_OCL = 1,
	ROW_PSYS = 2
};
const void *rowData(int kind, int state, int slot)
{
	return (const void *)(std::uintptr_t)(kind * 64 + state * 16 + slot);
}

// RW 0x8BDBB5 / 0x8BDC21 / 0x8BDC8C
void parseEntry(INI *ini, void *instance, void *, const void *userData)
{
	Data *d = static_cast<Data *>(instance);
	const unsigned code = (unsigned)(std::uintptr_t)userData;
	const int kind = (int)(code / 64), state = (int)(code / 16 % 4), slot = (int)(code % 16);
	Data::Entry &e = kind == ROW_FX ? d->m_fxList[state][slot] : kind == ROW_OCL ? d->m_ocl[state][slot] : d->m_particleSystem[state][slot];
	parseLocInfo(ini, e.loc);
	static const char *const kKeyword[] = { "fxlist", "ocl", "psys" };
	static const char *const kExpected[] = { "'fxlist' expected", "'ocl' expected", "'psys' expected" };
	if (!isWord(ini->getNextToken(ini->getSepsColon()), kKeyword[kind]))
	{
		throw INIException(3, "%s", kExpected[kind]);
	}
	const std::string name = ini->getNextToken();
	if (kind == ROW_OCL)
	{
		// RW 0x73A368 -> 0x5EFFE7: the store's list, NULL when it has none of that name (no error)
		e.name = TheObjectCreationListStore && TheObjectCreationListStore->findObjectCreationList(name) ? name : std::string();
		return;
	}
	// RW 0x73A302 (FXList) / RW 0x73AECB (template): None stores NULL. The names are checked by the client's stores (S-686)
	e.name = FXEventLog::isFXName(name) ? name : std::string();
}

// RW 0x73A5C9: user data 0 / 1 / 2 = DamageFXTypes / DamageOCLTypes / DamageParticleTypes
void parseTypeMask(INI *ini, void *instance, void *, const void *userData)
{
	Data *d = static_cast<Data *>(instance);
	const int which = (int)(std::uintptr_t)userData;
	std::uint32_t mask = 0xFFFFFFFFu;
	for (const char *t = ini->getNextToken(); t; t = ini->getNextTokenOrNull())
	{
		if (isWord(t, "ALL"))
		{
			mask = 0xFFFFFFFFu;
		}
		else if (isWord(t, "NONE"))
		{
			mask = 0;
		}
		else if (t[0] == '+')
		{
			mask |= 1u << ((unsigned)(INI::scanIndexList(t + 1, TheDamageNames) - 1) & 31u); // RW 0x42B999
		}
		else if (t[0] == '-')
		{
			mask &= ~(1u << ((unsigned)(INI::scanIndexList(t + 1, TheDamageNames) - 1) & 31u));
		}
		else
		{
			throw INIException(5, "ALL, NONE, + or - expected");
		}
	}
	(which == 0 ? d->m_damageFXTypes : which == 1 ? d->m_damageOCLTypes : d->m_damageParticleTypes) = mask;
}

// RW 0x42E59E into the state's Hide (user data state) or Show (user data 4 + state) list
void parseSubObjects(INI *ini, void *instance, void *, const void *userData)
{
	Data *d = static_cast<Data *>(instance);
	const int code = (int)(std::uintptr_t)userData;
	std::vector<std::string> &list = code < 4 ? d->m_hideSubObjects[code] : d->m_showSubObjects[code - 4];
	INI::parseAsciiStringVectorAppend(ini, nullptr, &list, nullptr);
}

// RW 0x8BE960
void parseRubbleNeighbor(INI *ini, void *instance, void *, const void *)
{
	Data *d = static_cast<Data *>(instance);
	Data::RubbleNeighbor n;
	for (const char *t = ini->getNextTokenOrNull(ini->getSepsColon()); t; t = ini->getNextTokenOrNull(ini->getSepsColon()))
	{
		if (isWord(t, "NeighborOffset") || isWord(t, "OCLOffset"))
		{
			Coord3D &c = isWord(t, "NeighborOffset") ? n.neighborOffset : n.oclOffset;
			c.x = ini->scanReal(ini->getNextSubToken("X"));
			c.y = ini->scanReal(ini->getNextSubToken("Y"));
			c.z = ini->scanReal(ini->getNextSubToken("Z"));
		}
		else if (isWord(t, "OCL"))
		{
			const std::string name = ini->getNextToken();
			n.ocl = TheObjectCreationListStore && TheObjectCreationListStore->findObjectCreationList(name) ? name : std::string();
		}
		else if (isWord(t, "SubObject"))
		{
			n.subObjects.push_back(ini->getNextToken());
		}
		else
		{
			throw INIException(3, "bad colon spacing, or unexpected token in TransitionDamageFXModuleData::NeighborIDSubobjectNameDataAppend");
		}
	}
	d->m_rubbleNeighbors.push_back(std::move(n));
}

// RW 0xC08D10 in the binary's row order (120 rows: the earlier S-686 text said 117)
std::vector<FieldParse> buildTable()
{
	static std::vector<std::string> names; // the generated row names (stable storage for the FieldParse tokens)
	static const char *const kStates[] = { "Damaged", "ReallyDamaged", "Rubble" };
	static const char *const kKinds[] = { "FXList", "OCL", "ParticleSystem" };
	names.reserve(108);
	std::vector<FieldParse> rows;
	rows.push_back({ "DamageFXTypes", parseTypeMask, (const void *)0, 0 });
	rows.push_back({ "DamageOCLTypes", parseTypeMask, (const void *)1, 0 });
	rows.push_back({ "DamageParticleTypes", parseTypeMask, (const void *)2, 0 });
	for (int kind = 0; kind < 3; ++kind)
	{
		for (int s = 0; s < 3; ++s)
		{
			for (int i = 0; i < Data::MAX_FX; ++i)
			{
				names.push_back(std::string(kStates[s]) + kKinds[kind] + std::to_string(i + 1));
				rows.push_back({ names.back().c_str(), parseEntry, rowData(kind, s + 1, i), 0 });
			}
		}
	}
	rows.push_back({ "RubbleNeighbor", parseRubbleNeighbor, nullptr, 0 });
	static const char *const kSub[] = { "PristineShowSubObject", "PristineHideSubObject", "DamagedShowSubObject", "DamagedHideSubObject",
		"ReallyDamagedShowSubObject", "ReallyDamagedHideSubObject", "RubbleShowSubObject", "RubbleHideSubObject" };
	for (int k = 0; k < 8; ++k)
	{
		const int state = k / 2;
		const bool show = k % 2 == 0;
		rows.push_back({ kSub[k], parseSubObjects, (const void *)(std::uintptr_t)(show ? 4 + state : state), 0 });
	}
	rows.push_back({ nullptr, nullptr, nullptr, 0 });
	return rows;
}
} // namespace

void TransitionDamageFXModuleData::buildFieldParse(MultiIniFieldParse &p)
{
	static const std::vector<FieldParse> table = buildTable();
	p.add(table.data());
}

TransitionDamageFX::Stats &TransitionDamageFX::stats()
{
	static Stats s;
	return s;
}

std::uint32_t TransitionDamageFX::particleSlot(int state, int i) const
{
	const std::vector<std::unique_ptr<BehaviorModule>> &mods = getObject()->modules();
	std::uint32_t index = 0;
	for (; index < (std::uint32_t)mods.size() && mods[index].get() != this; ++index)
	{
	}
	return index * (std::uint32_t)(BODYDAMAGETYPE_COUNT * TransitionDamageFXModuleData::MAX_FX) + (std::uint32_t)(state * TransitionDamageFXModuleData::MAX_FX + i);
}

Coord3D TransitionDamageFX::effectPos(const TransitionDamageFXModuleData::LocInfo &loc, bool world)
{
	Object &obj = *getObject();
	Coord3D pos = loc.offset;
	// RW 0x8BDDAC: a bone entry on an object with a drawable (taken as present, S-686)
	if (loc.type == TransitionDamageFXModuleData::LOC_BONE)
	{
		ProjectileLaunchOffsets *provider = obj.logic().combat().launchOffsets();
		if (loc.randomBone)
		{
			float bones[32][12];
			const int n = provider ? provider->multiLogicalBones(obj, loc.boneName, obj.getModelConditionBits(), 32, bones) : 0; // RW 0x672A73(name, 1, .., 32)
			if (n > 0)
			{
				const int pick = obj.logic().random().getValue(0, n - 1, "TransitionDamageFX.cpp", 0x153); // RW 0x6D328E
				++stats().randomBoneDraws;
				pos = Coord3D{ bones[pick][3], bones[pick][7], bones[pick][11] };
			}
		}
		else
		{
			float bone[12];
			if (provider && provider->singleLogicalBone(obj, loc.boneName, bone)) // RW 0x672A73(name, 0, .., 1)
			{
				pos = Coord3D{ bone[3], bone[7], bone[11] };
			}
		}
	}
	return world ? ConvertBonePosToWorldPos(obj, pos) : pos; // RW 0x70BCE7
}

// RW 0x8BE077
void TransitionDamageFX::onBodyDamageStateChange(const DamageInfo *info, BodyDamageType oldState, BodyDamageType newState)
{
	Object &obj = *getObject();
	static const int kActivelyBeingConstructed = CombatNames::modelCondition("ACTIVELY_BEING_CONSTRUCTED"); // 0x45
	if (obj.testModelCondition(kActivelyBeingConstructed))
	{
		return;
	}
	GameLogic &logic = obj.logic();
	Stats &st = stats();
	++st.transitions;
	const Object *source = info ? logic.findObjectByID(info->m_input.m_sourceID) : nullptr;
	const TransitionDamageFXModuleData &d = *m_data;
	// the old state's particle systems (RW 0x5F5379)
	for (int i = 0; i < TransitionDamageFXModuleData::MAX_FX; ++i)
	{
		const TransitionDamageFXModuleData::Entry &e = d.m_particleSystem[oldState][i];
		if (!e.name.empty())
		{
			FXEvent ev = FXEventLog::objectEvent(FXEvent::DESTROY_PARTICLE_SYSTEM, "TransitionDamageFX", logic.getFrame(), e.name, obj);
			ev.slot = particleSlot((int)oldState, i);
			logic.fxEvents().emit(ev);
		}
	}
	// RW 0x8BDCF7: the new state's sub objects (permanent), Hide then Show
	if (ObjectClientHooks *hooks = obj.clientHooks())
	{
		for (const std::string &n : d.m_hideSubObjects[newState])
		{
			hooks->showSubObject(obj, n, false, true);
		}
		for (const std::string &n : d.m_showSubObjects[newState])
		{
			hooks->showSubObject(obj, n, true, true);
		}
	}
	if (oldState < newState)
	{
		// body interface slot 0x40: the last damage record (ActiveBody + 0x40; its damage type at + 0x10); null for a body without one
		int lastType = 0;
		const BodyModuleInterface *body = obj.getBodyModule();
		const bool haveRecord = body && body->lastDamageRecordType(lastType);
		auto allowed = [&](std::uint32_t mask) { return !haveRecord || TransitionDamageFXModuleData::damageTypeAllowed(mask, lastType); };
		for (int i = 0; i < TransitionDamageFXModuleData::MAX_FX; ++i)
		{
			const TransitionDamageFXModuleData::Entry &fx = d.m_fxList[newState][i];
			if (!fx.name.empty() && allowed(d.m_damageFXTypes))
			{
				FXEvent ev;
				ev.kind = FXEvent::POSITION_FX; // RW 0x494615(fx, pos, null, 0, null)
				ev.site = "TransitionDamageFX";
				ev.frame = logic.getFrame();
				ev.fxList = &fx.name;
				ev.primary = obj.getID();
				ev.position = effectPos(fx.loc, true);
				ev.conditions = obj.getModelConditionBits();
				logic.fxEvents().emit(ev);
				++st.fxCalls;
			}
			const TransitionDamageFXModuleData::Entry &ocl = d.m_ocl[newState][i];
			if (!ocl.name.empty() && allowed(d.m_damageOCLTypes))
			{
				const Coord3D pos = effectPos(ocl.loc, true);
				const ObjectCreationList *list = TheObjectCreationListStore ? TheObjectCreationListStore->findObjectCreationList(ocl.name) : nullptr;
				if (!source)
				{
					++st.oclWithoutSource; // retail hands RW 0x5F00CA the address 0x38 (a null source + 0x38): not made (S-686)
				}
				else if (list)
				{
					list->create(logic, &obj, pos); // RW 0x5F00CA; the secondary position (the source's) is not handed over (S-530)
					++st.oclSecondaryDropped;
					++st.oclCalls;
				}
			}
			const TransitionDamageFXModuleData::Entry &ps = d.m_particleSystem[newState][i];
			if (!ps.name.empty() && allowed(d.m_damageParticleTypes))
			{
				FXEvent ev = FXEventLog::objectEvent(FXEvent::ATTACH_PARTICLE_SYSTEM, "TransitionDamageFX", logic.getFrame(), ps.name, obj);
				ev.position = effectPos(ps.loc, false); // model space: the attachment places it (RW 0x5F2F2D / 0x5F32D7)
				ev.hasTransform = false;
				ev.slot = particleSlot((int)newState, i);
				logic.fxEvents().emit(ev);
				++st.particleCalls;
			}
		}
	}
	if (oldState != newState && (oldState == BODY_RUBBLE || newState == BODY_RUBBLE) && !d.m_rubbleNeighbors.empty())
	{
		++st.rubbleNeighborsNotRun; // RW 0x8BDF08 (S-342)
	}
}

std::vector<std::string> TransitionDamageFX::stops()
{
	const Stats &s = stats();
	return { "[S-686] TransitionDamageFX: RW 0x8BE077 ran " + std::to_string(s.transitions) + " transitions, " + std::to_string(s.fxCalls) + " FXList, " +
			 std::to_string(s.particleCalls) + " particle system, " + std::to_string(s.oclCalls) + " OCL calls; not ported: the rubble neighbours (RW 0x8BDF08, " +
			 std::to_string(s.rubbleNeighborsNotRun) + " calls, S-342), the OCL's secondary position (" + std::to_string(s.oclSecondaryDropped) +
			 " calls, S-530), an OCL call without a damage source (" + std::to_string(s.oclWithoutSource) +
			 " not made); the drawable of RW 0x8BDDAC is taken as present; FXList / particle system names are not checked at parse time" };
}

void TransitionDamageFX::xfer(Xfer &x)
{
	SnapshotXfer::version(x, 1, 1);
	xferBehaviorModule(x);
}

void TransitionDamageFXModule::registerClass(ModuleFactory &modules)
{
	modules.bindTypedData<TransitionDamageFXModuleData>("TransitionDamageFX", MODULETYPE_BEHAVIOR);
	modules.bindModuleProc("TransitionDamageFX", MODULETYPE_BEHAVIOR, [](Thing *thing, const ModuleData *data, const ModuleFactory::ModuleTemplate &) -> std::unique_ptr<Module> {
		const TransitionDamageFXModuleData *typed = dynamic_cast<const TransitionDamageFXModuleData *>(data);
		if (!typed)
		{
			throw std::logic_error("TransitionDamageFX: the module data is not typed");
		}
		return std::make_unique<TransitionDamageFX>(thing, typed);
	});
}
