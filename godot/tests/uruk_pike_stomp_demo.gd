## Godot API example. Run --script res://tests/uruk_pike_stomp_demo.gd with retail installs.
## Optional -- --capture-dir=<local folder> captures one deterministic cycle, then exits.
extends SceneTree

const Rig = preload("res://scripts/animation/w3d_unit_rig.gd")
const Stomp = preload("res://scripts/animation/uruk_pike_stomp.gd")
var players: Array[AnimationPlayer] = []
var rigs: Array[Skeleton3D] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var fs = ClassDB.instantiate("RetailFileSystem")
	if not fs.mount_retail().ok:
		push_error("Set ROTWK_INSTALL and BFME2_INSTALL to your installed games")
		quit(1)
		return
	root.size = Vector2i(960, 720)
	root.msaa_3d = Viewport.MSAA_4X
	var stage := Node3D.new()
	root.add_child(stage)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.13, 0.15, 0.18)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.65
	stage.add_child(env)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(180, 150)
	floor_mesh.mesh = plane
	var ground := StandardMaterial3D.new()
	ground.albedo_color = Color(0.32, 0.34, 0.36)
	ground.roughness = 1.0
	floor_mesh.material_override = ground
	floor_mesh.position.y = -0.05
	stage.add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	stage.add_child(sun)
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 350.0
	sun.shadow_normal_bias = 0.2
	var inst = ClassDB.instantiate("W3DInstancer")
	stage.add_child(inst)
	inst.setup(fs)
	inst.set_auto_update(false)
	inst.set_playing(false)
	var model: int = inst.add_model("IUPikeman_SKN")
	for index in 3:
		var position := Vector3(0, 0, (index - 1) * 26)
		var unit: int = inst.add_instance(model, Transform3D(Basis.IDENTITY, position), "IUPikeman_IDLA", 0.0, 1.0)
		inst.set_instance_cast_shadow(unit, true)
		inst.set_instance_hidden_subobjects(unit, PackedStringArray(["Forged_Blade"]))
		inst.update_now()
		var actor := Node3D.new()
		stage.add_child(actor)
		var rig := Rig.new()
		rig.name = "Rig"
		rig.position = position
		actor.add_child(rig)
		if rig.attach(inst, unit) != OK:
			push_error(rig.last_error)
			quit(1)
			return
		var animation := Stomp.create(rig)
		if animation == null:
			quit(1)
			return
		var library := AnimationLibrary.new()
		library.add_animation("pike_stomp", animation)
		var player := AnimationPlayer.new()
		actor.add_child(player)
		player.add_animation_library("custom", library)
		player.play("custom/pike_stomp")
		player.seek(float((index * 37) % 101) / 100.0 * Stomp.PHASE_SPREAD, true)
		players.append(player)
		rigs.append(rig)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(115, 53, 105)
	camera.look_at(Vector3(0, 28, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 112
	camera.far = 500
	camera.make_current()
	var title := Label.new()
	title.text = "CUSTOM ANIMATION API  /  URUK PIKE STOMP\nSkeleton3D + AnimationPlayer → W3D instances"
	title.position = Vector2(22, 18)
	title.add_theme_font_size_override("font_size", 19)
	root.add_child(title)
	var folder := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="): folder = argument.trim_prefix("--capture-dir=")
	if not folder.is_empty():
		DirAccess.make_dir_recursive_absolute(folder)
		for player in players: player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for frame in int(Stomp.DURATION * 30):
			for i in players.size(): players[i].seek(fposmod(frame / 30.0 + float((i * 37) % 101) / 100.0 * Stomp.PHASE_SPREAD, Stomp.DURATION), true)
			for rig in rigs: rig.flush_pose()
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(folder.path_join("frame-%03d.png" % frame))
		print("PIKE STOMP CAPTURE PASS")
		quit(0)
