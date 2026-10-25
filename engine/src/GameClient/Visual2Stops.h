// OpenBFME - lane VISUAL-2: the stop lines of the fog of war look, the effects' shroud and the tree sway (docs/STOPS.md S-4970 .. S-4973), for the
// live report (GodotGameWorld's report "stops") and the tests.
#pragma once

#include <string>
#include <vector>

inline std::vector<std::string> visual2StopLines()
{
	return {
		"[S-4970] drawable shroud look: RW 0x64849E's fully obscured flag and its 2 s / 5 s grace are ported (GameClient/DrawableShroud.h); INFERENCE: the "
		"clear frame is stored for every presented CLEAR status, in or out of the view (retail's renderOneObject stores it for drawn objects), and is dropped "
		"when the shroud's viewer changes (a caster's POV switch hides at once); a FOGGED "
		"object is drawn as its live drawable lit by the fogged light (RW 0x46DFBA, FogAlpha / ClearAlpha) standing in for retail's ghost object (S-561): "
		"it shows the current model state, not the state of its last sight, and the scene fog colour is not scaled for it",
		"[S-4971] effects in the shroud: the FX and particle code asks the shroud the presented snapshot shows the local player (RW 0xB4D990 / 0x5E2282 / "
		"0x5FA2CE on the picture's cells and records, not the logic's live ones); an object the presented snapshot does not hold yet asks its position's "
		"cell; an object without a shroud record (a contained one: no partition data) asks its position's cell (RW 0x5E22C4); r2: a system does not emit "
		"while its drawable is not drawn (the visible byte +0x441, RW 0x5FA380 / 0x5FA6E9; INFERENCE: +0x441 is what the renderer drew, the port's "
		"Drawable::presentedLook without a view frustum test), and buffs and streaks of an undrawn drawable are not shown; particles emitted while their "
		"source was seen live out their lifetime (retail draws them too: no particle shader samples the shroud)",
		"[S-4972] breeze: TheScriptEngine's breeze (RW + 0x1A5A8: reset RW 0x609685, SET_TREE_SWAY RW 0x6031A9) is client state here: not saved in a "
		"save game and not hashed; the tree buffer's script time freeze gate (RW 0x603418 / 0x441E23) is not ported (no script time freeze exists)",
		"[S-4973] tree sway: W3DTreeBuffer's vegetation sway (RW 0x4E5D2C, 0x4E61EE, vegetation.fxo) drives every rigid mesh of a W3DTreeDraw map "
		"tree's instance, advanced by the elapsed retail client frames (fractions included) instead of once per 30 Hz client frame; presentation correction: the final table interval blends back to entry 0 instead of snapping to zero; SwayClientUpdate "
		"(RW 0x8CD675, the two cinematic objects that use it) is not ported (S-140)",
		"[S-4974] structure floors: a W3DFloorDraw floor (the fortress's skirt) is lit by the objects' light set and is drawn warmer and brighter than the "
		"terrain around it on every map captured (Evendim, Tournament Udun, Withered Heath, Harlindon); how retail lights a floor draw (its shader and light "
		"environment) was not read, and no retail picture of a fortress floor was available to compare",
	};
}
