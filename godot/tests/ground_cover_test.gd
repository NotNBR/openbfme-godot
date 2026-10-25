## Real-map GPU smoke, LOD, visibility and performance comparison for sprite ground cover.
extends SceneTree

var failures := 0
var viewport: SubViewport
var capture_dir := ""

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures += 1

func settle(frames := 8) -> void:
	for i in frames: await process_frame
	await RenderingServer.frame_post_draw

func capture(name: String) -> Image:
	var img := viewport.get_texture().get_image()
	if not capture_dir.is_empty():
		check(img.save_png(capture_dir.path_join(name + ".png")) == OK, "save " + name)
	return img

func bench() -> Dictionary:
	await settle(20)
	var frames: Array[float] = []
	var gpu: Array[float] = []
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	for i in 90:
		var start := Time.get_ticks_usec()
		await process_frame
		frames.append((Time.get_ticks_usec() - start) / 1000.0)
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid()))
	frames.sort()
	gpu.sort()
	return {"frame_median_ms": frames[45], "gpu_median_ms": gpu[45], "frame_p95_ms": frames[85]}

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP: GPU required")
		quit(77)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ground-captures="): capture_dir = arg.trim_prefix("--ground-captures=")
	if not capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(capture_dir)
	var fs = ClassDB.instantiate("RetailFileSystem")
	var mount: Dictionary = fs.mount_retail()
	check(mount.ok, "mount retail files")
	if not mount.ok:
		print(mount)
		quit(1)
		return
	var builder = ClassDB.instantiate("MapTerrainBuilder")
	var node = builder.build_map(fs, "map mp harlindon", {"markers": false, "fog": false, "natural_ground": true, "ground_cover": true})
	check(node != null, "build map with blade grass")
	if node == null:
		print(builder.get_report())
		quit(1)
		return
	var report: Dictionary = builder.get_report()
	print("GROUND COVER REPORT ", JSON.stringify(report.ground_cover), " build_ms=", report.timings_ms.ground_cover)
	check(report.ground_cover.instances > 1000, "map populated with real grass instances")
	check(report.ground_cover.rejected_road_water > 0, "road/water exclusion removes candidate plants")
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.far = 20000
	viewport.add_child(camera)
	var center: Vector3 = report.camera.center
	camera.position = center + Vector3(0, 95, 100)
	camera.look_at(center)
	camera.current = true
	viewport.add_child(node)
	var cover = node.get_node("GroundCover")
	for patch in cover.get_children():
		check(patch.multimesh.mesh.surface_get_array_len(0) == 5, "blade has five shared vertices") if patch == cover.get_child(0) else null
		patch.material_override.set_shader_parameter("wind_strength", 0.0)
	# Freeze cloud movement so the pixel comparison isolates grass.
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		for i in mesh.mesh.get_surface_count():
			var material = mesh.mesh.surface_get_material(i)
			if material is ShaderMaterial and material.has_meta("natural_ground"):
				material.set_shader_parameter("cloud_offset_per_second", Vector2.ZERO)
	cover.enabled = false
	await settle()
	var before := capture("grass-off")
	var original_cost := await bench()
	cover.enabled = true
	await settle()
	var after := capture("grass-on")
	var grass_cost := await bench()
	print("GROUND COVER PERFORMANCE off=", JSON.stringify(original_cost), " on=", JSON.stringify(grass_cost))
	var changed := 0
	for y in range(0, 800, 2):
		for x in range(0, 1280, 2):
			if before.get_pixel(x, y) != after.get_pixel(x, y): changed += 1
	check(changed > 200, "visible grass silhouettes change the rendered ground (%d samples)" % changed)
	var visible_near := 0
	for patch in cover.get_children():
		if patch.visible: visible_near += patch.multimesh.visible_instance_count
	check(visible_near > 100, "near camera retains visible instances")
	var distant_patches := 0
	for patch in cover.get_children():
		if patch.visible and patch.position.distance_to(center) > 600.0:
			distant_patches += 1
	check(distant_patches > 0, "grass extends beyond 600 world units")
	check(report.ground_cover.field_radius >= 880, "extended field radius includes a wide fade band")
	var controller = root.get_node("NaturalGround")
	controller.grass_enabled = true
	var key := InputEventKey.new()
	key.keycode = KEY_F7
	key.pressed = true
	controller._unhandled_key_input(key)
	check(not cover.visible, "F7 hides blades independently")
	controller._unhandled_key_input(key)
	check(cover.visible, "F7 restores blades")
	# Full shroud must hide every card, not just the underlying terrain.
	var black := Image.create_from_data(1, 1, false, Image.FORMAT_R8, PackedByteArray([0]))
	var first: MultiMeshInstance3D = cover.get_child(0)
	var material: ShaderMaterial = first.material_override
	material.set_shader_parameter("shroud_tex", ImageTexture.create_from_image(black))
	material.set_shader_parameter("shroud_enabled", true)
	await settle()
	var hidden := capture("grass-shrouded")
	material.set_shader_parameter("shroud_enabled", false)
	check(hidden.get_data() != after.get_data(), "blades receive the shroud mask")
	camera.position = center + Vector3(0, 240, 260)
	camera.look_at(center)
	await settle(20)
	capture("grass-overview")
	camera.position = center + Vector3(-32, 12, 42)
	camera.look_at(center + Vector3(-32, 0, 0))
	await settle(20)
	capture("grass-low-angle")
	var old_patch_position: Vector3 = first.position
	camera.position += Vector3(96, 0, 0)
	await settle(20)
	check(first.position != old_patch_position, "camera movement recycles patches")
	check(cover.get_child_count() == report.ground_cover.patches and first.multimesh.instance_count * cover.get_child_count() == report.ground_cover.instances, "camera movement keeps allocation bounded")
	camera.position += Vector3(0, 5000, 0)
	await settle(20)
	var visible_far := 0
	for patch in cover.get_children():
		if patch.visible: visible_far += patch.multimesh.visible_instance_count
	check(visible_far == 0, "zoomed-out camera culls all tiny grass (%d)" % visible_far)
	print("GROUND COVER TEST ", "PASS" if failures == 0 else "FAIL")
	node.free()
	viewport.queue_free()
	quit(0 if failures == 0 else 1)
