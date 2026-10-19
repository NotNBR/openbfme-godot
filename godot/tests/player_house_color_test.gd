## Player colours must use baked variants for both units and buildings.
extends SceneTree
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty():
		quit(77);return
	create_timer(120).timeout.connect(func(): push_error("Player colour test timed out");quit(1))
	var fs = ClassDB.instantiate("RetailFileSystem")
	assert(fs.mount_retail().ok)
	var world = ClassDB.instantiate("GameWorld")
	root.add_child(world)
	assert(world.setup(fs).ok)
	var slots: Array=[]
	for i in 8: slots.append({"state":1,"name":"Closed","accepted":true,"color":-1,"start_pos":-1,"player_template":-1,"team":-1})
	for i in 2: slots[i]={"state":6,"name":"Colour%d"%i,"accepted":true,"color":i,"start_pos":i,"player_template":3,"team":i}
	assert(world.prepare_new_game({"mode":"skirmish","difficulty":1,"rank_points":0,"map":"maps/map mp evendim/map mp evendim.map",
		"map_crc":0,"map_size":0,"map_mask":0,"seed":4242,"starting_cash":10000,"slots":slots}).ok)
	assert(world.start_new_game({"logic_thread":false,"wall_rebalance":false}).ok)
	world.set_shroud_drawn(false)
	for template in ["GondorFighter","GondorBarracks"]:
		var variants: Array=[]
		for player in [3,4]:
			var id: int=world.create_object(template,player,1800+player*300,1800,0)
			assert(id>0,"Object creation failed") # tolerance: allocated object IDs must be positive.
			for i in 3: world.advance(0.2)
			var info: Dictionary=world.get_object(id)
			assert(not info.shown_models.is_empty(),str(info))
			var model: String=info.shown_models[0]
			assert(model.contains("#1&"),str(info))
			variants.append(model)
		assert(variants[0]!=variants[1],str(variants))
	# Read back a real unit's baked house texture: a pure-green primary colour
	# must leave no red/blue texels and retain nonzero shaded green texels.
	var renderer=ClassDB.instantiate("W3DInstancer")
	root.add_child(renderer)
	assert(renderer.setup(fs).ok)
	renderer.set_house_colors_enabled(true)
	var model: int=renderer.add_model_colored(world.get_template_model("GondorFighter"),1,PackedInt64Array([0xff00ff00]))
	assert(model>=0) # tolerance: model handles are nonnegative.
	var packed_note := false
	for note in renderer.get_model_report(model).notes:
		if str(note).replace("\\", "/").contains("[S-1482] house texture art/compiledtextures/hc/hc_gumanatarms04.jpg: packed PNG colour multiplication and alpha replacement are inferred; the loader merge was not read"):
			packed_note = true
	assert(packed_note, str(renderer.get_model_report(model).notes))
	assert(renderer.add_instance(model,Transform3D.IDENTITY)>=0) # tolerance: instance handles are nonnegative.
	for i in 3: await process_frame
	var textures := 0
	var green := false
	for child in renderer.get_children():
		if not child is MultiMeshInstance3D: continue
		var mesh: Mesh=child.multimesh.mesh
		for surface in mesh.get_surface_count():
			var material: ShaderMaterial=mesh.surface_get_material(surface)
			if material==null: continue
			var texture=material.get_shader_parameter("w3d_hc_tex")
			if texture==null: continue
			var pixels: Image=texture.get_image()
			assert(not pixels.is_empty())
			for y in pixels.get_height():
				for x in pixels.get_width():
					var pixel: Color=pixels.get_pixel(x,y)
					assert(pixel.r==0 and pixel.b==0,str(pixel))
					green=green or pixel.g!=0
			textures+=1
	assert(textures>0) # tolerance: this retail unit must contain at least one house texture.
	assert(green)
	print("PLAYER HOUSE COLOUR PASS")
	quit()
