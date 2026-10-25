## GPU integration check and repeatable before/after captures for the visual ground mod.
## godot --path godot --script res://tests/natural_ground_test.gd -- --ground-captures=DIR
## Add --ground-map="map mp harlindon" for a real-map capture using mounted retail files.
extends SceneTree

var failures := 0
var captures := ""
var map_name := ""
var viewport: SubViewport

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures += 1

func _render() -> Image:
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _save(image: Image, name: String) -> void:
	if not captures.is_empty():
		_check(image.save_png(captures.path_join(name + ".png")) == OK, "save " + name)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP: natural ground needs a GPU renderer")
		quit(77)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ground-captures="):
			captures = arg.trim_prefix("--ground-captures=")
		elif arg.begins_with("--ground-map="):
			map_name = arg.trim_prefix("--ground-map=")
	if not captures.is_empty():
		DirAccess.make_dir_recursive_absolute(captures)
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 11
	camera.position = Vector3(5, 30, -5)
	viewport.add_child(camera)
	camera.look_at(Vector3(5, 0, -5), Vector3.FORWARD)
	camera.current = true
	var builder = ClassDB.instantiate("MapTerrainBuilder")
	var atlas := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.24, 0.34, 0.12))
	atlas.fill_rect(Rect2i(32, 0, 32, 64), Color(0.30, 0.29, 0.26))
	var mask := Image.create(64, 64, false, Image.FORMAT_R8)
	mask.fill(Color.BLACK)
	mask.fill_rect(Rect2i(0, 0, 32, 64), Color.WHITE)
	var neutral := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	neutral.fill(Color(0.5, 0.5, 0))
	var patch = builder.build_test_patch({"base_atlas": atlas,
		"uv0": PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]), "layers": []})
	_check(patch != null, "build production terrain patch")
	if patch == null:
		quit(1)
		return
	viewport.add_child(patch)
	var mesh = patch
	var material: ShaderMaterial = mesh.mesh.surface_get_material(0)
	material.set_shader_parameter("normal_atlas", ImageTexture.create_from_image(neutral))
	material.set_shader_parameter("meadow_mask", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("turf_detail", load("res://assets/natural_ground/turf_detail.png"))
	material.set_shader_parameter("debug_mode", 0)
	material.set_shader_parameter("sun_dir_sage", Vector3(0.6, 0.3, 0.8).normalized())
	material.set_shader_parameter("sun_color", Vector3(0.2, 0.2, 0.2))
	material.set_shader_parameter("overbright", false)
	var before := await _render()
	material.set_shader_parameter("natural_ground_enabled", true)
	var after := await _render()
	_save(before, "patch-original")
	_save(after, "patch-natural")
	var changed := 0
	var stone_changed := 0
	for y in range(40, 470, 3):
		for x in range(40, 230, 3):
			if before.get_pixel(x, y) != after.get_pixel(x, y): changed += 1
		for x in range(290, 470, 3):
			if before.get_pixel(x, y) != after.get_pixel(x, y): stone_changed += 1
	_check(changed > 100, "eligible turf gains visible detail (%d changed samples)" % changed)
	_check(stone_changed == 0, "excluded stone is pixel identical (%d changed samples)" % stone_changed)
	material.set_shader_parameter("natural_ground_strength", 0.0)
	var zero_strength := await _render()
	_check(zero_strength.get_data() == before.get_data(), "zero strength restores original pixels")
	material.set_shader_parameter("natural_ground_strength", 1.0)
	material.set_shader_parameter("natural_ground_enabled", false)
	var restored := await _render()
	_check(restored.get_data() == before.get_data(), "switching off restores original pixels")
	material.set_shader_parameter("debug_mode", 7)
	var debug_before := await _render()
	material.set_shader_parameter("natural_ground_enabled", true)
	var debug_after := await _render()
	_check(debug_before.get_data() == debug_after.get_data(), "retail numeric debug output is unchanged")
	material.set_shader_parameter("debug_mode", 0)
	material.set_meta("natural_ground", true)
	var controller = root.get_node("NaturalGround")
	controller.enabled = true
	var toggle := InputEventKey.new()
	toggle.keycode = KEY_F8
	toggle.pressed = true
	controller._unhandled_key_input(toggle)
	_check(not bool(material.get_shader_parameter("natural_ground_enabled")), "F8 updates existing terrain materials")
	controller._unhandled_key_input(toggle)
	_check(bool(material.get_shader_parameter("natural_ground_enabled")), "F8 enables existing terrain materials again")
	material.set_shader_parameter("shroud_enabled", true)
	material.set_shader_parameter("shroud_tex", ImageTexture.create_from_image(Image.create_from_data(1, 1, false, Image.FORMAT_R8, PackedByteArray([0]))))
	var hidden := await _render()
	_check(hidden.get_pixel(128, 128).r < 0.01, "ground detail respects shroud")
	patch.free()
	if not map_name.is_empty():
		await _map_capture(builder, camera)
	viewport.queue_free()
	print("NATURAL GROUND: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(0 if failures == 0 else 1)

func _map_capture(builder: RefCounted, camera: Camera3D) -> void:
	var fs = ClassDB.instantiate("RetailFileSystem")
	var mount: Dictionary = fs.mount_retail()
	_check(mount.ok, "mount retail map assets")
	if not mount.ok:
		print(mount)
		return
	var map = builder.build_map(fs, map_name, {"markers": false, "fog": false, "natural_ground": false})
	_check(map != null, "build " + map_name)
	if map == null:
		print(builder.get_report())
		return
	var report: Dictionary = builder.get_report()
	print("Meadow classes: ", report.natural_ground.meadow_classes)
	_check(not report.natural_ground.meadow_classes.is_empty(), "map contains eligible meadow classes")
	viewport.size = Vector2i(1280, 800)
	viewport.add_child(map)
	var center: Vector3 = report.camera.center
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.far = 20000
	camera.position = center + Vector3(0, 180, 170)
	camera.look_at(center)
	_save(await _render(), "map-original")
	for mesh in map.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var material = mesh.mesh.surface_get_material(surface)
			if material is ShaderMaterial and material.has_meta("natural_ground"):
				material.set_shader_parameter("natural_ground_enabled", true)
	_save(await _render(), "map-natural")
	map.free()
