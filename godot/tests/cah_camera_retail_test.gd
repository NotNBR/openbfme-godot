extends SceneTree

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty():
		print("SKIP: cah camera retail requires ROTWK_INSTALL and BFME2_INSTALL")
		quit(77)
		return
	var fs = ClassDB.instantiate("RetailFileSystem")
	assert(fs.mount_retail().ok)
	var world = ClassDB.instantiate("GameWorld")
	root.add_child(world)
	assert(world.setup(fs).ok)
	assert(not world.cah_view_info(-1, 0).ok)
	assert(not world.cah_preview_set_orientation(1, 0).ok)
	assert(world.load_map("createahero", {"seed": 1, "terrain": false}).ok)
	assert(world.cah_builder(true))
	var info: Dictionary = world.cah_view_info(0, 1) # Hero of the West / Shield Maiden.
	assert(info.ok, str(info))
	assert(info.normal_cam == 0.5)
	assert(info.camera_offset.x == 0.0)
	assert(info.camera_offset.z == 300.0)
	assert(is_equal_approx(info.camera_offset.y, -300.0 / tan(deg_to_rad(37.5))))
	var locations: Array = world.cah_preview_locations()
	assert(not locations.is_empty())
	var loc: Dictionary = locations[info.map_location]
	assert(not loc.is_empty())
	var view = load("res://scripts/create_a_hero_view.gd").new()
	root.add_child(view)
	view._info = info
	view._hero_sage = Vector3(loc.x, loc.y, loc.z)
	view._facing = loc.angle
	view._t = info.normal_cam
	var normal: Dictionary = view.camera_pose("A")
	assert(not normal.has("error"), str(normal))
	assert(normal.fov == 0.83)
	assert(view.camera_pose("C") == normal)
	for i in 5: assert(is_equal_approx(normal.row[i], (info.near[i] + info.far[i]) * 0.5))
	assert(view.camera_pose("P").row == info.close_up)
	assert(view.camera_pose("M").row == info.portrait)
	view._advance_controls({"zoom_in": true}, false)
	assert(is_equal_approx(view._t, 0.45))
	for i in 40: view._advance_controls({"zoom_out": true}, true)
	assert(view._t == 1.0)
	assert(world.cah_preview_set_orientation(loc.id, loc.angle + 0.1).ok)
	var rotated: Array = world.cah_preview_locations()
	assert(is_equal_approx(rotated[info.map_location].angle, loc.angle + 0.1))
	assert(not world.cah_preview_set_orientation(-1, 0).ok)
	assert(not world.cah_preview_set_orientation(loc.id, NAN).ok)
	assert(not world.cah_view_info(0, 4294967296).ok)
	assert(world.cah_builder(false))
	assert(not world.cah_preview_set_orientation(loc.id, 0).ok)
	world.clear_game_data(false)
	print("CAH CAMERA RETAIL PASS")
	quit()
