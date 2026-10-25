## Lane VISUAL-2: the owner's playtest bugs (2026-10-17), checked and captured in the real client. game.gd runs it after the start with
## --visual2=<scenario>[,...] (with --auto); screenshots go to --screens as visual2-<name>.png; every scenario prints "VISUAL2 <scenario>: ok" or
## "VISUAL2 <scenario>: FAIL <why>" and "VISUAL2 RESULT: <n> ok, <m> failed" ends the run.
##   fog    the enemy as the local player sees it: every enemy object whose status for the local player is SHROUDED in two samples 3 s apart must not
##          be drawn at the second (VIS-1 with RW 0x64849E's 2 s grace); the particles live around the enemy objects the shroud hides (retail: their
##          systems emit nothing, RW 0x5FA2CE / 0x5E2282: only what was emitted while seen is left, and it dies); the camera on the enemy builder (or
##          unit, or structure) in the fog: visual2-fog-<n>.png. FAIL: a hidden enemy object drawn
##   trees  the camera close over the trees nearest the local base, two shots 0.6 s apart (visual2-trees-a / -b.png) and the SwayOffsets globals moving
##          (W3DVegetationSway: zero when nothing sways). FAIL: the globals do not move
##   ghost  a structure of another player (neutral) that is FOGGED and drawn (RW 0x68EDD0: a neutral IMMOBILE object is not hidden in the fog): the
##          camera on it, lit by the fogged light (RW 0x46F48E: visual2-ghost-fogged.png). FAIL: no such structure
##   look   the local base and the map's middle at the default camera (visual2-look-base / -middle.png) for the colour comparison
extends "res://scripts/scenario_player.gd"

var game: Node
var hud: Node
var world: Node


func _run(p_game: Node, scenarios: PackedStringArray) -> void:
	game = p_game
	hud = game._hud
	world = game._world
	await _run_scenarios(scenarios)


func _frames(n: int) -> void:
	for i in n:
		await game.get_tree().process_frame


func _seconds(s: float) -> void:
	await game.get_tree().create_timer(s).timeout


func _enemy_names() -> Array:
	var out := []
	for p in world.get_economy().players:
		if p.playable and p.name != game._local_name:
			out.append(p.name)
	return out


func _local_base() -> Vector2:
	var sum := Vector2()
	var n := 0
	for o in world.get_player_objects(game._local_name):
		if o.get("structure", false):
			sum += Vector2(o.x, o.y)
			n += 1
	return sum / n if n > 0 else Vector2()


## the enemy objects with their status for the local player (3 FOGGED, 4 SHROUDED) and the render view's hiding
func _enemy_sample() -> Array:
	var out := []
	for name in _enemy_names():
		for o in world.get_player_objects(name):
			var id: int = o.id
			var full: Dictionary = world.get_object(id)
			if not full.get("ok", false) or full.get("destroyed", false) or full.get("contained_by", 0) != 0:
				continue
			var pose: Dictionary = world.get_render_pose(id)
			if not pose.get("ok", false) or not pose.get("view_valid", false):
				continue
			out.append({"id": id, "template": full.template, "x": full.x, "y": full.y, "structure": full.get("structure", false),
				"dozer": full.has("dozer_task"), "status": world.get_object_shroud_status(id), "hidden": pose.get("view_hidden", false),
				"obscured": pose.get("fully_obscured", null)})
	return out


func _scenario_fog() -> String:
	var shroud: Dictionary = world.get_shroud_report()
	print("VISUAL2 fog shroud: %s" % JSON.stringify(shroud))
	if not shroud.get("ok", false) or int(shroud.get("fogged", 0)) + int(shroud.get("shrouded", 0)) == 0:
		return "the local player has no fogged or shrouded cell (the shroud is not displayed)"
	var first := _enemy_sample()
	await _seconds(3.0)
	var second := _enemy_sample()
	var shrouded_then := {}
	for e in first:
		if e.status == 4:
			shrouded_then[e.id] = true
	var leaks := []
	var hidden_enemies := 0
	var drawn_in_fog := 0
	var particles_near_hidden := 0
	var systems_near_hidden := 0
	var shot_target = null
	for e in second:
		if e.status == 4:
			hidden_enemies += 1
			if shrouded_then.has(e.id) and not e.hidden:
				leaks.append("%s #%d" % [e.template, e.id])
			var pn: Dictionary = world.get_particles_near(e.x, e.y, 40.0)
			particles_near_hidden += int(pn.particles)
			systems_near_hidden += int(pn.systems)
		elif e.status == 3 and not e.hidden:
			drawn_in_fog += 1 # a fogged structure the local player saw: drawn as its last sight (the ghost, S-561)
		if e.status >= 3 and not e.structure:
			if shot_target == null or (e.dozer and not shot_target.dozer):
				shot_target = e
	if shot_target == null:
		for e in second:
			if e.status >= 3:
				shot_target = e
				break
	print("VISUAL2 fog: %d enemy objects, %d hidden by the shroud, %d leaks (drawn while shrouded 3 s: %s), %d fogged drawn as last seen, particles near hidden enemies %d in %d systems" %
		[second.size(), hidden_enemies, leaks.size(), ", ".join(leaks.slice(0, 12)), drawn_in_fog, particles_near_hidden, systems_near_hidden])
	if shot_target != null:
		hud.camera_look_at(Vector2(shot_target.x, shot_target.y))
		await _frames(20)
		game._save_named("visual2-fog-1")
		print("VISUAL2 fog shot: %s #%d at (%d, %d) status %d hidden %s" % [shot_target.template, shot_target.id, shot_target.x, shot_target.y, shot_target.status, shot_target.hidden])
		# a second spot: the most crowded hidden enemy area (an expansion being built)
		var best = null
		var best_n := 0
		for e in second:
			if e.status != 4:
				continue
			var n := 0
			for f in second:
				if f.status == 4 and Vector2(f.x, f.y).distance_to(Vector2(e.x, e.y)) < 300.0:
					n += 1
			if n > best_n:
				best_n = n
				best = e
		if best != null:
			hud.camera_look_at(Vector2(best.x, best.y))
			await _frames(20)
			game._save_named("visual2-fog-2")
			print("VISUAL2 fog shot 2: around %s #%d at (%d, %d), %d hidden enemy objects within 300" % [best.template, best.id, best.x, best.y, best_n])
	if not leaks.is_empty():
		return "%d enemy objects drawn while the shroud hides them: %s" % [leaks.size(), ", ".join(leaks.slice(0, 12))]
	# r2: the claims are measured, not printed: an enemy hidden by the shroud exists, and no particle is drawn near any (RW 0x5FA2CE, 0x5E2282)
	if hidden_enemies == 0:
		return "no enemy object is hidden by the shroud: nothing measured"
	if particles_near_hidden > 0:
		return "%d particles in %d systems near enemy objects the shroud hides" % [particles_near_hidden, systems_near_hidden]
	return ""


func _sway_globals() -> Array:
	if not world.has_method("get_tree_sway"):
		return []
	return world.get_tree_sway().get("offsets", [])


func _scenario_trees() -> String:
	var base := _local_base()
	var trees: Array = world.get_logic_trees(base.x, base.y, 3000.0)
	if trees.is_empty():
		return "no tree within 3000 of the local base"
	trees.sort_custom(func(a, b): return Vector2(a.x, a.y).distance_to(base) < Vector2(b.x, b.y).distance_to(base))
	var t: Dictionary = trees[0]
	var at := Vector2(t.x, t.y)
	hud.camera_look_at(at)
	hud.camera_set_height(180.0)
	hud.camera_look_at(at)
	await _seconds(3.0) # the camera settles
	if world.has_method("get_tree_sway"):
		print("VISUAL2 trees sway: %s" % JSON.stringify(world.get_tree_sway()).left(400))
	var a := _sway_globals()
	game._save_named("visual2-trees-a")
	await _seconds(0.6)
	var b := _sway_globals()
	game._save_named("visual2-trees-b")
	await _seconds(2.4)
	var c := _sway_globals()
	game._save_named("visual2-trees-c")
	if a.is_empty() or b.is_empty():
		return "no tree sway in this build (get_tree_sway)"
	print("VISUAL2 trees: tree #%d at (%d, %d); SwayOffsets[1] %s -> %s -> %s" % [t.id, t.x, t.y, str(a[0]), str(b[0]), str(c[0])])
	var moved := false
	for i in 10:
		if (a[i] as Vector3).distance_to(b[i]) > 1e-6: # tolerance: any movement of the sway vector over 0.6 s is the claim
			moved = true
	if not moved:
		return "the SwayOffsets did not move in 0.6 s (%s)" % str(a[0])
	return ""


func _scenario_look() -> String:
	var base := _local_base()
	hud.camera_look_at(base)
	await _frames(30)
	game._save_named("visual2-look-base")
	var shroud: Dictionary = world.get_shroud_report()
	var mid := Vector2(float(shroud.get("cells_x", 0)), float(shroud.get("cells_y", 0))) * float(shroud.get("cell_size", 0.0)) * 0.5
	if mid != Vector2():
		hud.camera_look_at(mid)
		await _frames(30)
		game._save_named("visual2-look-middle")
	return ""


func _scenario_ghost() -> String:
	# a structure that is not the local player's or an enemy's (a neutral camp / ruin) and is FOGGED and drawn: retail lights it by the fogged light
	var mine: String = game._local_name
	var enemies := _enemy_names()
	var pick = null
	var count := 0
	for id in world.get_object_ids():
		var o: Dictionary = world.get_object(id)
		if not o.get("ok", false) or not o.get("structure", false) or o.get("owner", "") == mine or enemies.has(o.get("owner", "")):
			continue
		if int(world.get_object_shroud_status(id)) != 3:
			continue
		var pose: Dictionary = world.get_render_pose(id)
		if not pose.get("ok", false) or pose.get("view_hidden", true):
			continue
		count += 1
		if pick == null:
			pick = o
	print("VISUAL2 ghost: %d fogged structures of other players drawn" % count)
	if pick == null:
		return "no fogged structure of another player is drawn"
	hud.camera_look_at(Vector2(pick.x, pick.y))
	await _seconds(3.0)
	var pose_now: Dictionary = world.get_render_pose(pick.id)
	game._save_named("visual2-ghost-fogged")
	print("VISUAL2 ghost: %s #%d (%s) at (%d, %d) status %d hidden %s fully obscured %s instances %s fog lit %s" % [pick.template, pick.id, pick.get("owner", ""), pick.x, pick.y,
		int(world.get_object_shroud_status(pick.id)), pose_now.get("view_hidden"), str(pose_now.get("fully_obscured")), str(pose_now.get("instances")),
		str(pose_now.get("fog_lit_instances"))])
	# r2: the claim is measured: the fogged structure is drawn fully obscured, and every drawn instance of it carries the fogged light (RW 0x46F48E)
	if not pose_now.get("ok", false) or int(world.get_object_shroud_status(pick.id)) != 3:
		return "the fogged structure #%d is no longer fogged / presented" % pick.id
	if pose_now.get("fully_obscured") != true:
		return "the fogged structure #%d is not fully obscured" % pick.id
	if int(pose_now.get("instances", 0)) == 0:
		return "the fogged structure #%d draws no instance: nothing measured" % pick.id
	if int(pose_now.get("fog_lit_instances", 0)) != int(pose_now.get("instances", 0)):
		return "the fogged structure #%d: %d of %d instances have the fogged light" % [pick.id, int(pose_now.get("fog_lit_instances", 0)), int(pose_now.get("instances", 0))]
	return ""
