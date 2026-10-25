## Lane DEVPORT-8 (FALSEDEF-1): the under-attack warnings of an attacked structure, driven through the real game. game.gd runs it with
## --auto --faction=FactionMen --devport8=attack. Prints "DEVPORT8 <name>: ok" or "DEVPORT8 <name>: FAIL <why>", then "DEVPORT8 RESULT: <n> ok, <m> failed".
##   attack  an enemy hero created beside our fortress is ordered (AI attack) onto it: the fortress loses health; the radar gets the UNDER_ATTACK event
##           (RW 0x6D9BF3) and its first draw asks for MiscAudio GenericRadarEvent (RW 0x44DE58), which plays RadarEvent; the branch's MiscAudio slot
##           (RadarNotifyStructureUnderAttackSound, NoSound in RotWK's miscaudio.ini) is asked for and gives no sound; the control bar's blink (RW 0x71C7E4 /
##           0x71C81A) starts on ControlBar.wnd:WinUAttack, toggles every 15 client frames and ends enabled; the window has no image (nothing is drawn)
extends "res://scripts/scenario_player.gd"

var game: Node
var hud: Node
var world: Node


func _run(p_game: Node, scenarios: PackedStringArray) -> void:
	game = p_game
	hud = game._hud
	world = game._world
	await _run_scenarios(scenarios)


func player_index(name: String) -> int:
	for p in world.get_economy().players:
		if p.name == name:
			return int(p.index)
	return -1


func enemy_name() -> String:
	for p in world.get_economy().players:
		if p.playable and p.name != game._local_name:
			return p.name
	return ""


func _scenario_attack() -> String:
	var fortress := {}
	for o in world.get_player_objects(game._local_name):
		if str(o.template).find("Fortress") >= 0 and (fortress.is_empty() or str(o.template).find("Citadel") >= 0):
			fortress = o
	if fortress.is_empty():
		return "no fortress of the local player"
	var fid := int(fortress.id)
	var hp0 := float(world.get_object(fid).get("health", 0.0))
	print("DEVPORT8 attack: target %s %d health %.1f at (%.0f, %.0f)" % [fortress.template, fid, hp0, fortress.x, fortress.y])
	var flash0: Dictionary = hud.get_hud6_state().get("attack_flash", {})
	if not bool(flash0.get("window", false)):
		return "the control bar has no ControlBar.wnd:WinUAttack window: %s" % JSON.stringify(flash0)
	if int(flash0.get("starts", -1)) != 0:
		return "a blink before the attack: %s" % JSON.stringify(flash0)
	print("DEVPORT8 attack: blink window %s at %s / %s, enabled image '%s', disabled image '%s'" % [
		flash0.get("window"), flash0.get("rect"), flash0.get("resolution"), flash0.get("enabled_image"), flash0.get("disabled_image")])
	var enemy := player_index(enemy_name())
	if enemy < 0:
		return "no enemy player"
	var foe: int = world.create_object("GondorBoromir", enemy, float(fortress.x) + 160.0, float(fortress.y), PI)
	if foe <= 0:
		return "no enemy hero could be created"
	world.debug_ai_attack(foe, fid)
	var sounds_seen := 0
	game._misc_sounds_played.clear()
	var attack_event := {}
	var last_enabled := true
	var changes: Array = []
	var hp := hp0
	var start_frame := -1
	var start_client := -1
	var end_frame := -1
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000:
		await game.get_tree().process_frame
		hp = float(world.get_object(fid).get("health", hp))
		var f: Dictionary = hud.get_hud6_state().get("attack_flash", {})
		if start_frame < 0 and int(f.get("starts", 0)) > 0:
			start_frame = game._frames
			print("DEVPORT8 attack: blink started at render frame %d (health %.1f -> %.1f), count %d, window enabled %s" % [game._frames, hp0, hp, int(f.count), f.window_enabled])
		if start_frame >= 0 and bool(f.get("window_enabled", true)) != last_enabled:
			last_enabled = bool(f.window_enabled)
			changes.append([int(f.count), last_enabled])
			print("DEVPORT8 attack: blink count %d window %s (render frame %d)" % [int(f.count), "enabled" if last_enabled else "disabled", game._frames])
		if attack_event.is_empty():
			for e in hud.get_radar_state().get("events", []):
				if int(e.type) == 3:
					attack_event = e
					print("DEVPORT8 attack: radar UNDER_ATTACK event at %s, client frames %d .. %d" % [e.world, int(e.created), int(e.dies)])
		if start_frame >= 0 and not bool(f.get("on", true)) and end_frame < 0:
			end_frame = game._frames
			print("DEVPORT8 attack: blink over at render frame %d: %s" % [game._frames, JSON.stringify(f)])
		if end_frame >= 0 and not attack_event.is_empty() and game._misc_sounds_played.size() >= 2:
			break
	var played: Array = game._misc_sounds_played.duplicate()
	for m in played:
		print("DEVPORT8 attack: MiscAudio %s -> handle %d (render frame %d)" % [m.field, int(m.handle), int(m.frame)])
	if hp >= hp0:
		return "the fortress lost no health (%.1f -> %.1f)" % [hp0, hp]
	if attack_event.is_empty():
		return "no UNDER_ATTACK radar event"
	if start_frame < 0:
		return "the control bar's blink never started"
	if end_frame < 0:
		return "the blink did not end within the run"
	var expected := [[135, true], [120, false], [105, true], [90, false], [75, true], [60, false], [45, true], [30, false], [15, true]]
	# the start disables the window (the first change seen), then the 9 toggles of RW 0x71C81A at counts 135 .. 15
	if changes.size() < 1 or bool(changes[0][1]) != false or changes.slice(1) != expected:
		return "the blink's window changes %s, expected a disable then %s" % [JSON.stringify(changes), JSON.stringify(expected)]
	var flash: Dictionary = hud.get_hud6_state().get("attack_flash", {})
	if str(flash.get("drawn_image", "x")) != "" or int(flash.get("image_draws", -1)) != 0:
		return "the blink drew an image though the window has none: %s" % JSON.stringify(flash)
	var generic := {}
	var notify := {}
	for m in played:
		if m.field == "GenericRadarEvent" and generic.is_empty():
			generic = m
		if m.field == "RadarNotifyStructureUnderAttackSound" and notify.is_empty():
			notify = m
	if notify.is_empty() or int(notify.handle) != 1:
		return "RadarNotifyStructureUnderAttackSound was not asked for, or did not give AHSV_NoSound (1): %s" % JSON.stringify(played)
	if generic.is_empty() or int(generic.handle) < 5:
		return "GenericRadarEvent was not asked for, or gave no sound handle: %s" % JSON.stringify(played)
	var info: Dictionary = game._audio.get_event_info("RadarEvent")
	print("DEVPORT8 attack: RadarEvent %s" % JSON.stringify(info))
	return ""
