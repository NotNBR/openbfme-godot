## Lane DEVPORT-7: the owner's three reports (Devin branch owner-fixes-1), played in the real client. game.gd runs it with --devport7=<a,b,...>
## (with --auto for a skirmish, or with --campaign=ANGMAR_CAMPAIGN in the first Angmar mission); each scenario prints "DEVPORT7 <name>: ok" or
## "DEVPORT7 <name>: FAIL <why>" and its measured lines, "DEVPORT7 RESULT: <n> ok, <m> failed" ends the run; shots go to --screens as play1-devport7-*.png.
## Every selection, order and button press is an InputEvent pushed into the viewport (PLAY-1's helpers); the staging (units placed, a rank given, a hit)
## uses the GameWorld test hooks (the start option test_hooks, never in a network game). What a scenario judges is the world's own state.
##   veteran    (campaign) the owner's "veteran units do not auto-heal / replenish their horde": a rank-2 Angmar horde gets its banner carrier and the
##              carrier replaces a dead member (BannerCarrierUpdate RW 0x89ACE4); a rank-2 Lorien horde's banner heals its wounded member (AutoHealBehavior
##              AffectsContained, RW 0x855A32: a contained healer heals its parent horde); a rank-3 Knights of Dol Amroth horde heals and refills itself
##              (RespawnNearbyHordeMembers RW 0x855D16, KindOf all bits by default RW 0x654B36); the Witch-king heals after StartHealingDelay
##   rally      (skirmish) the owner's "no rally banner when right-clicking a troop-producing structure": a left click selects a barracks, a right click
##              on the ground sets its rally point; the HUD shows the RallyPointMarker drawable there (RW 0x71D18F), a second right click moves the same
##              drawable, a unit trained by the Palantir's button walks to it, the marker goes with the selection and returns with it
##   formation  (skirmish) the owner's "a group selection does not apply the formation command to all of them": three tower guard hordes, an archer horde
##              and a soldier, selected by a left drag box around them; the Palantir's formation button sends one MSG_HORDE_SET_FORMATION per horde with the
##              voted template (RW 0x940435 case 0x24) and every tower guard horde turns porcupine, the others keep their template; a second press turns them back
extends "res://scripts/play1_player.gd"


func _run(p_game: Node, scenarios: PackedStringArray) -> void:
	game = p_game
	hud = game._hud
	world = game._world
	shell = game._shell
	await _run_scenarios(scenarios)


# ---- helpers -------------------------------------------------------------------------------------------------------------------------------------------

func obj(id: int) -> Dictionary:
	return world.get_object(id)


func payload(horde: int) -> Array:
	var out: Array = []
	for m in obj(horde).get("members", []):
		var d := obj(int(m))
		if d.get("ok", false) and not str(d.get("template", "")).contains("Banner"):
			out.append(int(m))
	return out


func banner_of(horde: int) -> int:
	for m in obj(horde).get("members", []):
		if str(obj(int(m)).get("template", "")).contains("Banner"):
			return int(m)
	return 0


## logic frames of play (5 per second), waiting on the client clock as a player would
func frames(n: int) -> void:
	var f0: int = world.get_frame()
	var t0 := Time.get_ticks_msec()
	while world.get_frame() - f0 < n and Time.get_ticks_msec() - t0 < n * 1000:
		await game._step(1)


func place(template: String, at: Vector2) -> int:
	var id: int = world.create_object(template, game._local_index, at.x, at.y, 0.0)
	if id <= 0:
		print("DEVPORT7 note: create_object(%s) refused: %s" % [template, str(world.get_report().get("command_errors", []))])
	return id


func hit(id: int, amount: float) -> float:
	var r: Dictionary = world.debug_damage_object(id, amount, 0)
	if not r.get("ok", false):
		print("DEVPORT7 note: debug_damage_object(%d) refused: %s" % [id, str(r.get("error", ""))])
		return -1.0
	return float(r.get("health", -1.0))


func shift_click(p: Vector2) -> void:
	# as a keyboard and mouse send it (INPUT-1's key helper): Shift down, a click with the Shift flag, Shift up
	await move_to(p)
	var k := InputEventKey.new()
	k.keycode = KEY_SHIFT
	k.physical_keycode = KEY_SHIFT
	k.pressed = true
	k.shift_pressed = true # the HUD syncs its modifiers from every event's own flags (InGameHudNode::syncModifiers)
	Input.parse_input_event(k)
	await game._step(2)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = down
		b.shift_pressed = true
		b.position = p
		b.global_position = p
		b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		Input.parse_input_event(b)
		await game.get_tree().process_frame
	await game._step(2)
	var u := k.duplicate()
	u.pressed = false
	u.shift_pressed = false
	Input.parse_input_event(u)
	await game._step(4)


## a pixel of one of the horde's soldiers where it is drawn
func horde_pixel(id: int) -> Vector2:
	var members: Array = obj(id).get("members", [])
	var target := int(members[0]) if not members.is_empty() else id
	var pose: Dictionary = world.get_render_pose(target)
	var o := obj(target)
	var at := Vector2(pose.x, pose.y) if pose.get("ok", false) else Vector2(o.get("x", 0.0), o.get("y", 0.0))
	return to_pixel(at.x, at.y)


func own_named(part: String) -> Dictionary:
	for o in own_objects():
		if str(o.template).contains(part):
			return o
	return {}


## the candidate point (rings around `center`) farthest from every non-structure object of the other players
func quiet_spot(center: Vector2) -> Vector2:
	var enemies: Array = []
	for pl in world.get_economy().players:
		if str(pl.name) == game._local_name:
			continue
		for o in world.get_player_objects(str(pl.name)):
			if not o.structure and o.get("has_ai", true):
				enemies.append(Vector2(o.x, o.y))
	var best := center
	var best_d := -1.0
	for ring in range(1, 7):
		for k in 16:
			var p := center + Vector2(cos(TAU * k / 16.0), sin(TAU * k / 16.0)) * 250.0 * ring
			if p.x < 200 or p.y < 200:
				continue
			var d := 1e9
			for e in enemies:
				d = minf(d, p.distance_to(e))
			if d > best_d:
				best_d = d
				best = p
	print("DEVPORT7 note: quiet spot (%.0f, %.0f), %.0f from the nearest of %d units of the other players" % [best.x, best.y, best_d, enemies.size()])
	return best


# ---- veteran (campaign) ---------------------------------------------------------------------------------------------------------------------------------

func _scenario_veteran() -> String:
	await _headless_window()
	var fails: Array = []
	var wk := own_named("Witchking")
	if wk.is_empty():
		return "no Witch-king of the local player (%s) in this mission" % game._local_name
	# the mission's opening battle is fought around the Witch-king: the scene goes where no unit of another player is near (a fight stops the heals:
	# HealOnlyIfNotInCombat / HealOnlyIfNotUnderAttack, and drags the hordes away)
	var base := quiet_spot(Vector2(wk.x, wk.y))
	await look_by_radar(base)
	print("DEVPORT7 veteran: %s, frame %d, the Witch-king %d at (%.0f, %.0f)" % [game._cli_campaign, world.get_frame(), wk.id, wk.x, wk.y])
	# 1. a rank-2 Angmar horde: its banner carrier joins and replaces a dead member (no AutoHealBehavior: it does not heal)
	var angmar := place("AngmarDarkDunedainHorde", base)
	if angmar <= 0:
		return "AngmarDarkDunedainHorde could not be placed"
	await frames(5)
	print("DEVPORT7 veteran: Angmar horde rank -> %d" % world.debug_set_object_rank(angmar, 2))
	var t := 0
	while banner_of(angmar) == 0 and t < 150:
		await frames(1)
		t += 1
	if banner_of(angmar) == 0:
		fails.append("the rank-2 Angmar horde got no banner carrier in 150 frames")
	else:
		var full := payload(angmar).size()
		var dead: int = payload(angmar)[0]
		hit(dead, 100000.0)
		await frames(3)
		var after_loss := payload(angmar).size()
		var f0: int = world.get_frame()
		while payload(angmar).size() < full and world.get_frame() - f0 < 450:
			await frames(5)
		var back := payload(angmar).size()
		print("DEVPORT7 veteran: Angmar banner %d: members %d -> %d after a loss -> %d after %d frames" % [banner_of(angmar), full, after_loss, back, world.get_frame() - f0])
		if after_loss != full - 1 or back != full:
			fails.append("the Angmar banner did not replace the dead member (%d -> %d -> %d)" % [full, after_loss, back])
		shot("devport7-veteran-angmar")
	# 2. a rank-2 Lorien horde: the banner heals its wounded member
	var lorien := place("ElvenLorienWarriorHorde", base + Vector2(0, 120))
	if lorien > 0:
		await frames(5)
		world.debug_set_object_rank(lorien, 2)
		t = 0
		while banner_of(lorien) == 0 and t < 150:
			await frames(1)
			t += 1
		var wounded: int = payload(lorien)[0] if not payload(lorien).is_empty() else 0
		if banner_of(lorien) == 0 or wounded == 0:
			fails.append("the rank-2 Lorien horde got no banner carrier")
		else:
			var maxh: float = obj(wounded).max_health
			var h1 := hit(wounded, 50.0)
			await frames(60)
			var h2: float = obj(wounded).health
			print("DEVPORT7 veteran: Lorien banner %d heals member %d: %.1f -> %.1f -> %.1f of %.1f (horde %s)" % [banner_of(lorien), wounded, maxh, h1, h2, maxh, str(obj(lorien).get("ai_state", "?")) + " melee " + str(obj(lorien).get("horde_melee", "?"))])
			if h1 != maxh - 50.0 or h2 != maxh:
				fails.append("the Lorien banner did not heal its member (%.1f -> %.1f of %.1f)" % [h1, h2, maxh])
	else:
		fails.append("ElvenLorienWarriorHorde could not be placed")
	# 3. a rank-3 Knights of Dol Amroth horde heals and refills itself
	var knights := place("GondorKnightsofDolHorde", base + Vector2(0, -140))
	if knights > 0:
		await frames(5)
		var full := payload(knights).size()
		hit(payload(knights)[0], 100000.0)
		hit(payload(knights)[1], 100000.0)
		await frames(3)
		var wounded: int = payload(knights)[0]
		var maxh: float = obj(wounded).max_health
		hit(wounded, 100.0)
		await frames(100)
		var rank1 := [payload(knights).size(), obj(wounded).health]
		print("DEVPORT7 veteran: Knights rank -> %d" % world.debug_set_object_rank(knights, 3))
		var f0: int = world.get_frame()
		while (payload(knights).size() < full or obj(wounded).health < maxh) and world.get_frame() - f0 < 600:
			await frames(5)
		print("DEVPORT7 veteran: Knights rank 1 after 100 frames: %d of %d members, member %d health %.1f of %.1f; rank 3 after %d frames: %d members, health %.1f" % [rank1[0], full, wounded, rank1[1], maxh, world.get_frame() - f0, payload(knights).size(), obj(wounded).health])
		if rank1[0] != full - 2 or rank1[1] != maxh - 100.0:
			fails.append("the rank-1 knights recovered before their rank (%d members, %.1f)" % [rank1[0], rank1[1]])
		if payload(knights).size() != full or obj(wounded).health != maxh:
			fails.append("the rank-3 knights did not heal and refill (%d of %d, %.1f of %.1f)" % [payload(knights).size(), full, obj(wounded).health, maxh])
		shot("devport7-veteran-knights")
	else:
		fails.append("GondorKnightsofDolHorde could not be placed")
	# 4. a Witch-king heals after StartHealingDelay (15 s): one placed at the quiet spot (the mission's own stands in its opening battle, where
	# HealOnlyIfNotInCombat holds his heal, as in retail)
	var hero := place("AngmarWitchking", base + Vector2(150, 0))
	if hero <= 0:
		fails.append("AngmarWitchking could not be placed")
	else:
		await frames(100) # the full-health self healer goes to sleep before the hit wakes it (test_veteran_heal_retail.cpp)
		var wmax: float = obj(hero).max_health
		var w1 := hit(hero, 100.0)
		await frames(74)
		var w_early: float = obj(hero).health
		await frames(30)
		var w2: float = obj(hero).health
		print("DEVPORT7 veteran: a Witch-king %.1f -> %.1f, %.1f after 74 frames, %.1f after 104 of %.1f" % [wmax, w1, w_early, w2, wmax])
		if w1 != wmax - 100.0 or w_early != w1 or w2 != wmax:
			fails.append("the Witch-king did not heal after StartHealingDelay (%.1f, %.1f, %.1f of %.1f)" % [w1, w_early, w2, wmax])
	return "; ".join(fails)


# ---- rally (skirmish) -----------------------------------------------------------------------------------------------------------------------------------

func rally() -> Dictionary:
	return hud.get_state().get("rally_marker", {})


func _scenario_rally() -> String:
	await _headless_window()
	var fortress := own_named("Fortress")
	if fortress.is_empty():
		fortress = own_named("Citadel")
	if fortress.is_empty():
		return "no fortress of the local player"
	var faction_barracks := {"Men": "GondorBarracks", "Mordor": "MordorOrcPit", "Isengard": "IsengardUrukPit", "Elves": "ElvenBarracks",
		"Dwarves": "DwarvenBarracks", "Angmar": "AngmarFortressOfAngmar", "Wild": "WildGoblinCaveFissure"}
	var at := Vector2(fortress.x, fortress.y) + Vector2(300, -300)
	var barracks := place("GondorBarracks", at)
	if barracks <= 0:
		return "a barracks could not be placed (%s)" % str(faction_barracks)
	await frames(10)
	await look_by_radar(at)
	await game._wait_seconds(1.0)
	var b := obj(barracks)
	if not await select_object(b):
		return "a left click did not select the barracks"
	var before := rally()
	if int(before.get("drawable", 0)) != 0:
		return "a marker before any rally point: " + str(before)
	var p1 := Vector2(b.x, b.y) + Vector2(-180, 160)
	var px1 := to_pixel(p1.x, p1.y)
	await click(px1, MOUSE_BUTTON_RIGHT)
	await frames(3)
	await game._step(4)
	var r1 := rally()
	var d1 := Vector2(float(r1.get("x", 1e9)), float(r1.get("y", 1e9))).distance_to(p1)
	print("DEVPORT7 rally: right click at (%.0f, %.0f) -> %s (%.1f from the click)" % [p1.x, p1.y, str(r1), d1])
	if str(r1.get("template", "")) != "RallyPointMarker" or not bool(r1.get("animated", false)) or d1 > 25.0:
		return "no animated RallyPointMarker at the right click: " + str(r1)
	shot("devport7-rally-set")
	var p2 := p1 + Vector2(120, 60)
	await click(to_pixel(p2.x, p2.y), MOUSE_BUTTON_RIGHT)
	await frames(3)
	await game._step(4)
	var r2 := rally()
	var d2 := Vector2(float(r2.get("x", 1e9)), float(r2.get("y", 1e9))).distance_to(p2)
	print("DEVPORT7 rally: second right click -> %s (%.1f from it)" % [str(r2), d2])
	if int(r2.get("drawable", 0)) != int(r1.drawable) or d2 > 25.0:
		return "the second right click did not move the same marker: %s then %s" % [str(r1), str(r2)]
	shot("devport7-rally-moved")
	# a unit trained by the Palantir's first enabled unit button walks to the flag
	var known := {}
	for o in own_objects():
		known[int(o.id)] = true
	var unit := command_button(func(x): return str(x.command) == "UNIT_BUILD" and int(x.state) == 1)
	if unit.is_empty():
		var me: Dictionary = {}
		for pl in world.get_economy().players:
			if str(pl.name) == game._local_name:
				me = pl
		return "no enabled unit button on the barracks (economy %s, barracks %s): %s" % [str(me), str(obj(barracks)), button_list()]
	await click(palantir_button(unit.frame))
	var made := {}
	var f0: int = world.get_frame()
	var best := 1e9
	while world.get_frame() - f0 < 900:
		await frames(10)
		for o in own_objects():
			if not known.has(int(o.id)) and not o.structure and made.is_empty():
				made = o
		if not made.is_empty():
			var m := obj(int(made.id))
			best = minf(best, Vector2(m.x, m.y).distance_to(p2))
			if best < 80.0 and not bool(m.get("moving", true)):
				break
	print("DEVPORT7 rally: trained %s, closest %.1f from the flag after %d frames" % [str(made.get("template", "none")), best, world.get_frame() - f0])
	if made.is_empty() or best > 80.0:
		return "the trained unit did not walk to the flag (%s, %.1f)" % [str(made.get("template", "none")), best]
	shot("devport7-rally-arrived")
	# the marker goes with the selection (a left click on empty ground) and returns with it
	var empty_px := to_pixel(p2.x - 250.0, p2.y - 250.0)
	await click(empty_px)
	await game._step(6)
	var gone := rally()
	if not hud.get_selection().is_empty() or int(gone.get("drawable", 0)) != 0:
		return "the marker stayed after the deselection: %s (selection %s)" % [str(gone), str(hud.get_selection())]
	if not await select_object(obj(barracks)):
		return "the barracks could not be selected again"
	await game._step(4)
	var again := rally()
	if str(again.get("template", "")) != "RallyPointMarker" or Vector2(float(again.get("x", 1e9)), float(again.get("y", 1e9))).distance_to(p2) > 25.0:
		return "the marker did not return with the selection: " + str(again)
	shot("devport7-rally-reselected")
	return ""


# ---- formation (skirmish) -------------------------------------------------------------------------------------------------------------------------------

func _scenario_formation() -> String:
	await _headless_window()
	var fortress := own_named("Fortress")
	if fortress.is_empty():
		fortress = own_named("Citadel")
	if fortress.is_empty():
		return "no fortress of the local player"
	var c := Vector2(fortress.x, fortress.y) + Vector2(-350, 350)
	# the archers and the soldier first: the control bar shows the newest selected object's command set (the port's single-source context, S-1202),
	# so a tower guard horde is the one whose buttons the player sees, as with a selection of guard hordes
	var archers := place("GondorArcherHorde", c + Vector2(0, 130))
	var soldier := place("GondorFighter", c + Vector2(130, 130))
	var guards: Array = []
	for i in 3:
		guards.append(place("GondorTowerShieldGuardHorde", c + Vector2(110 * i, 0)))
	if guards.has(-1) or archers <= 0 or soldier <= 0:
		return "the group could not be placed"
	await frames(10)
	await look_by_radar(c + Vector2(110, 60))
	await game._wait_seconds(1.0)
	var group: Array = guards + [archers, soldier]
	var names := {}
	for id in group:
		names[id] = str(obj(id).template)
	# a left drag box around the five (the box selects the local units inside it, PLAY-3's dragbox scenario)
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for id in group:
		var px: Vector2 = horde_pixel(id) if id != soldier else to_pixel(obj(id).x, obj(id).y)
		for m in obj(id).get("members", []):
			var mo := obj(int(m))
			var mp := to_pixel(mo.x, mo.y)
			lo = Vector2(minf(lo.x, mp.x), minf(lo.y, mp.y))
			hi = Vector2(maxf(hi.x, mp.x), maxf(hi.y, mp.y))
		lo = Vector2(minf(lo.x, px.x), minf(lo.y, px.y))
		hi = Vector2(maxf(hi.x, px.x), maxf(hi.y, px.y))
	lo -= Vector2(40, 40)
	hi += Vector2(40, 40)
	var log_sel: int = hud.get_message_log().size()
	await move_to(lo)
	press(lo, MOUSE_BUTTON_LEFT, true)
	for t in 8:
		await move_to(lo.lerp(hi, float(t + 1) / 8.0))
	press(hi, MOUSE_BUTTON_LEFT, false)
	await game._step(8)
	print("DEVPORT7 formation: drag box %s - %s sent %s" % [str(lo), str(hi), str(messages_since(log_sel))])
	var sel: Array = hud.get_selection()
	print("DEVPORT7 formation: selection %s (%s), bar %s" % [str(sel), str(sel.map(func(i): return names.get(i, str(obj(int(i)).template)))), button_list()])
	for id in group:
		if not sel.has(id):
			return "the drag box did not select %s (%d); selection %s" % [names[id], id, str(sel)]
	shot("devport7-formation-selected")
	var log0: int = hud.get_message_log().size()
	var b := command_button(func(x): return str(x.command) == "HORDE_TOGGLE_FORMATION" and int(x.state) == 1)
	if b.is_empty():
		return "no enabled formation button for the group: " + button_list()
	await click(palantir_button(b.frame))
	await frames(5)
	var sent := messages_since(log0).filter(func(l): return str(l).contains("FORMATION"))
	print("DEVPORT7 formation: the button sent %s" % str(sent))
	var wrong: Array = []
	for id in group:
		var o := obj(id)
		print("DEVPORT7 formation: %d %s porcupine %s, next %s" % [id, names[id], str(o.get("horde_porcupine", "-")), str(o.get("horde_next_formation", "-"))])
		if guards.has(id) and not bool(o.get("horde_porcupine", false)):
			wrong.append("%s %d is not in its porcupine formation" % [names[id], id])
		if not guards.has(id) and bool(o.get("horde_porcupine", false)):
			wrong.append("%s %d changed formation" % [names[id], id])
	if not wrong.is_empty():
		return "after the press: " + "; ".join(wrong)
	shot("devport7-formation-porcupine")
	var log1: int = hud.get_message_log().size()
	var again := command_button(func(x): return str(x.command) == "HORDE_TOGGLE_FORMATION" and int(x.state) == 1)
	if again.is_empty():
		return "no enabled formation button after the change: " + button_list()
	await click(palantir_button(again.frame))
	await frames(5)
	print("DEVPORT7 formation: the second press sent %s" % str(messages_since(log1).filter(func(l): return str(l).contains("FORMATION"))))
	for id in guards:
		if bool(obj(id).get("horde_porcupine", true)):
			wrong.append("%s %d stayed porcupine after the second press" % [names[id], id])
	if not wrong.is_empty():
		return "; ".join(wrong)
	return ""
