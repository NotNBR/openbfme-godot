// OpenBFME. GPL-3.0.
// Derived from Command & Conquer Generals Zero Hour, (c) 2001-2003 Electronic Arts Inc., GPL-3.0 (DamageModule.h), as RotWK uses it.
//
// DamageModuleInterface (lane COMBAT-2): the BehaviorModule interface with the mask bit DAMAGE (0x4): a module that reacts to the damage its object takes.
//
// TARGET FACTS (RotWK game.dat, caveat S-001): the three slots of the interface table (CastleMemberBehavior's, RW 0xC308BC): slot 0 onDamage(DamageInfo *) (RW 0x79B757 reads the output
// field + 0x70, the amount dealt, and acts only when it is above 0), slot 1 onHealing (a stub there), slot 2 onBodyDamageStateChange(info, old state, new state) (RW 0x79A0ED compares
// the third argument with 3 = RUBBLE and 2). The body calls them: onDamage after the health change of a damaging hit, onBodyDamageStateChange when the damage state changed.
// The call sites in RW's body (lane FX-4): onDamage after the health change and before the death, in module list order (RW 0x8C4351); onBodyDamageStateChange
// only from attemptDamage (RW 0x8C4389) and attemptHealing (RW 0x8C3131), not from setCorrectDamageState (RW 0x8C2A5D, where ZH makes it).

#pragma once

#include "GameLogic/Module/BehaviorModule.h"

struct DamageInfo;

class DamageModuleInterface
{
public:
	virtual ~DamageModuleInterface() = default;
	virtual void onDamage(const DamageInfo &info) = 0;
	virtual void onHealing(const DamageInfo &info) { (void)info; }
	// lane FX-4: RW passes the DamageInfo of the hit / healing (attemptDamage RW 0x8C43B7, attemptHealing RW 0x8C3139 loop; never null there)
	virtual void onBodyDamageStateChange(const DamageInfo *info, BodyDamageType oldState, BodyDamageType newState) = 0;
};
