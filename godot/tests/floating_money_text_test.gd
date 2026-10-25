extends SceneTree
# Paying buildings show the retail GUI:AddCash floating text: a farm (TerrainResourceBehavior) and a fortress citadel (AutoDepositUpdate).
# Needs ROTWK_INSTALL / BFME2_INSTALL. Option: -- --shot=<png>
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	root.size = Vector2i(1280, 720)
	var fs = ClassDB.instantiate("RetailFileSystem")
	assert(fs.mount_retail().ok)
	var world = ClassDB.instantiate("GameWorld")
	root.add_child(world)
	assert(world.setup(fs).ok)
	var report: Dictionary = world.load_map("map mp fall back 4p", {"slots":[{"player":"Player_1","faction":"FactionMen","human":true}]})
	assert(report.ok, str(report))
	var owner := -1
	for i in report.players.size():
		if String(report.players[i]).contains("'Player_1'"): owner = i
	assert(owner != -1, str(report.players))
	# the farm is built by a porter (a farm claims its ground when its construction completes); the citadel pays from creation
	var porter = world.create_object("MenPorter", owner, 1700, 1700, 0)
	var citadel = world.create_object("MenFortressCitadel", owner, 2150, 1800, 0)
	# tolerance: Object IDs are allocated dynamically; zero is the invalid ID.
	assert(porter > 0 and citadel > 0)
	var camera := Camera3D.new()
	root.add_child(camera)
	var hud = ClassDB.instantiate("InGameHudNode")
	root.add_child(hud)
	assert(hud.setup(fs, world, camera, "Player_1", {"camera_start":Vector3(1975,0,-1800)}).ok)
	world.set_shroud_drawn(false)
	hud.select_object_with_message(porter) # the logic sees the selection: its build order is taken
	world.advance(0.2)
	for i in 4: await process_frame
	assert(hud.press_command_button("GondorFarm"), str(hud.get_command_buttons()))
	# the first legal site on screen (the placement's legality code 0), searched over window pixels clear of the HUD
	var site := Vector2.ZERO
	var farm_at := Vector2.ZERO
	for py in [200, 300, 150, 400]:
		for px in [420, 560, 700, 840, 980, 1120]:
			hud.inject_mouse_move(Vector2(px, py))
			for i in 6: await process_frame
			if hud.get_placement().legal == 0 and not hud.get_state().get("over_gui", false):
				site = Vector2(px, py)
				farm_at = Vector2(hud.get_placement().x, hud.get_placement().y)
				break
		if site != Vector2.ZERO: break
	assert(site != Vector2.ZERO, "no legal farm site: " + str(hud.get_placement()))
	hud.inject_mouse_button(1, true, site, false)
	hud.inject_mouse_button(1, false, site, false)
	for i in 4: await process_frame
	var seen := {}
	var shot := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="): shot = arg.trim_prefix("--shot=")
	var saved := false
	for step in 3600:
		world.advance(1.0 / 30.0)
		await process_frame
		if step == 30: assert(not hud.get_placement().placing, "the farm was not placed: " + str(hud.get_placement()))
		var texts: Array = hud.get_state().get("floating_texts", [])
		for t in texts:
			var key := "farm" if Vector2(t.x, t.y).distance_to(farm_at) < 1 else ("citadel" if absf(t.x - 2150) < 1 and absf(t.y - 1800) < 1 else "other")
			seen[key] = t
		if not saved and not shot.is_empty() and seen.has("farm") and seen.has("citadel") and texts.size() >= 2:
			root.get_viewport().get_texture().get_image().save_png(shot)
			saved = true
		if seen.has("farm") and seen.has("citadel") and (saved or shot.is_empty()):
			break
	assert(seen.has("farm"), str(seen))
	assert(seen.has("citadel"), str(seen))
	for key in ["farm", "citadel"]:
		var t: Dictionary = seen[key]
		# tolerance: the farm's amount depends on how much ground it claims; every amount is GUI:AddCash's "+N" (no MISSING label)
		assert(str(t.text).begins_with("+") and str(t.text).find("MISSING") < 0, str(t))
		# tolerance: the text height is the terrain height plus 10 (citadel) or the geometry's top (farm); both are above the ground's 0
		assert(t.z > 0, str(t))
	print("FLOATING MONEY TEXT PASS: ", seen)
	hud.queue_free()
	world.queue_free()
	camera.queue_free()
	await process_frame
	quit()
