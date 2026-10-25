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

# Same slow subpixel pan with the former screen-door fade and the new sample coverage.
func pan_variation(camera: Camera3D, center: Vector3) -> float:
	var previous: Image
	var variation := 0.0
	for frame in 12:
		camera.position = center + Vector3(frame*0.08,160,180)
		camera.look_at(center + Vector3(frame*0.08,0,0))
		await settle(2)
		var current := viewport.get_texture().get_image()
		if previous != null:
			for y in range(120,720,3):
				for x in range(80,1200,3):
					var a := previous.get_pixel(x,y)
					var b := current.get_pixel(x,y)
					variation += absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b)
		previous = current
	return variation

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
	viewport.msaa_3d = Viewport.MSAA_8X
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
	check(report.ground_cover.screen_size_lod and report.ground_cover.shared_instance_slots == 8192, "frustum coverage uses shared buffers and screen-size LOD")
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
	check(cover._near_batch.instance_count + cover._far_batch.instance_count == 8192, "all visible tiles share two fixed instance buffers")
	camera.position += Vector3(0, 5000, 0)
	await settle(20)
	var visible_far := 0
	for patch in cover.get_children():
		if patch.visible: visible_far += patch.multimesh.visible_instance_count
	check(visible_far == 0, "zoomed-out camera culls all tiny grass (%d)" % visible_far)
	# At RTS overview scale there must still be grass coverage after every blade is culled.
	camera.position = center + Vector3(0,3500,3500)
	camera.look_at(center)
	await settle(20)
	var far_on := capture("grass-far-surface")
	check(cover.terrain_material.get_shader_parameter("grass_surface_enabled"), "far turf follows the grass toggle")
	cover.enabled = false
	await settle()
	var far_off := capture("grass-far-off")
	var distant_changed := 0
	for y in range(0,800,4):
		for x in range(0,1280,4):
			if far_on.get_pixel(x,y) != far_off.get_pixel(x,y): distant_changed += 1
	check(distant_changed > 50, "terrain retains grass coverage without blades (%d samples)" % distant_changed)
	check(not cover.terrain_material.get_shader_parameter("grass_surface_enabled"), "off restores unmodified terrain")
	cover.enabled = true
	# A repeatable zoom and pan sweep also exercises the boundaries between streamed tiles.
	for distance in [160.0,320.0,640.0,1200.0,2200.0]:
		camera.position = center + Vector3(0,distance*0.7,distance*0.7)
		camera.look_at(center)
		await settle(12)
		capture("grass-zoom-%d" % int(distance))
	for i in 180:
		var t := float(i) / 179.0
		var distance := lerpf(160.0,2200.0,t)
		var target := center + Vector3(t*320.0,0,0)
		camera.position = target + Vector3(0,distance*0.7,distance*0.7)
		camera.look_at(target)
		await process_frame
		if i % 30 == 0: capture("grass-motion-%03d" % i)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 180.0
	await settle()
	check(cover.terrain_material.get_shader_parameter("grass_orthographic"), "orthographic LOD uses screen size")
	check(cover.get_child(0).visible, "orthographic close view retains blades regardless of camera distance")
	camera.size = 6000.0
	await settle()
	check(not first.visible and cover.terrain_material.get_shader_parameter("grass_surface_enabled"), "orthographic overview keeps turf after blade culling")
	capture("grass-orthographic-overview")
	check(cover._near_batch.instance_count + cover._far_batch.instance_count == 8192, "continuous zoom/pan keeps instance storage bounded")
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	for angle in [5.0,10.0,20.0]:
		camera.position = center + Vector3(0,12,0)
		camera.rotation = Vector3(-deg_to_rad(angle),0,0)
		await settle(12)
		capture("grass-low-pan-%d" % int(angle))
		for frame in 60:
			camera.position.x += 2.1
			await process_frame
		capture("grass-low-pan-%d-end" % int(angle))
	var coverage_shader: Shader = material.shader
	var noisy_shader := Shader.new()
	noisy_shader.code = coverage_shader.code.replace("alpha_to_coverage_and_one, depth_draw_always", "depth_draw_opaque").replace("ALPHA=plant_alive;", "if(hash21(FRAGCOORD.xy)>plant_alive) discard;")
	material.shader = noisy_shader
	material.set_shader_parameter("output_gamma",2.2)
	await settle()
	var noisy_variation := await pan_variation(camera,center)
	material.shader = coverage_shader
	material.set_shader_parameter("output_gamma",1.0)
	await settle()
	var coverage_variation := await pan_variation(camera,center)
	print("GRASS PAN VARIATION screen_noise=",noisy_variation," sample_coverage=",coverage_variation)
	check(coverage_variation < noisy_variation, "sample coverage reduces subpixel-pan pixel variation")
	print("GROUND COVER TEST ", "PASS" if failures == 0 else "FAIL")
	node.free()
	viewport.queue_free()
	quit(0 if failures == 0 else 1)
