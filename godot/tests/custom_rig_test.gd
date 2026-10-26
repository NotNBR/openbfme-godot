## Run on a real or headless backend with retail installs. Does not embed retail data.
extends SceneTree

const Rig = preload("res://scripts/animation/w3d_unit_rig.gd")
const Stomp = preload("res://scripts/animation/uruk_pike_stomp.gd")
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print("RIG ", "PASS " if ok else "FAIL ", message)
	if not ok: failed += 1

func near(a: Transform3D, b: Transform3D) -> bool:
	# tolerance: single-precision parent inversion and recomposition across a 19-bone hierarchy; 0.0001 model units.
	return a.origin.distance_to(b.origin) < 0.0001 and (a.basis.x - b.basis.x).length() < 0.0001 and (a.basis.y - b.basis.y).length() < 0.0001 and (a.basis.z - b.basis.z).length() < 0.0001

func run() -> void:
	var fs = ClassDB.instantiate("RetailFileSystem")
	if not fs.mount_retail().ok:
		print("SKIP: retail installs required")
		quit(77)
		return
	var inst = ClassDB.instantiate("W3DInstancer")
	root.add_child(inst)
	inst.setup(fs)
	inst.set_auto_update(false)
	var model: int = inst.add_model("IUPikeman_SKN")
	var a: int = inst.add_instance(model, Transform3D.IDENTITY, "IUPikeman_IDLA", 0.0, 1.0)
	var b: int = inst.add_instance(model, Transform3D.IDENTITY, "IUPikeman_IDLA", 0.0, 1.0)
	inst.set_global_time(0.0)
	inst.update_now()
	check(inst.find_model_instances("iupikeman_skn") == PackedInt64Array([a, b]), "find placed model instances case-insensitively")
	var before: Array = inst.get_instance_rig(a)
	check(not before.is_empty(), "pikeman hierarchy exposed")
	if before.is_empty():
		quit(1)
		return
	var batch: Array[Transform3D] = []
	for bone in before:
		var pose: Transform3D = bone.pose
		pose.origin.y += 2.0
		batch.append(pose)
	check(inst.set_instances_rig_pose(PackedInt64Array([a, b]), batch), "batch applies to both units")
	inst.update_now()
	var batched: Array = inst.get_instance_rig(a)
	check(batched == inst.get_instance_rig(b), "batch poses match")
	check(not inst.set_instances_rig_pose(PackedInt64Array([a, 999999]), []), "invalid batch rejected atomically")
	check(inst.get_instance_rig(a) == batched, "failed batch preserves first unit")
	check(inst.set_instances_rig_pose(PackedInt64Array([a, b]), []), "batch clear")
	inst.update_now()
	check(inst.get_instance_rig(a) == before and inst.get_instance_rig(b) == before, "batch clear restores both units")
	var rig = Rig.new()
	root.add_child(rig)
	check(rig.attach(inst, a) == OK, "attach")
	var duplicate = Rig.new()
	check(duplicate.attach(inst, a) == ERR_ALREADY_IN_USE, "second owner rejected")
	duplicate.free()
	check(rig.flush_pose(), "round trip accepted")
	var after: Array = inst.get_instance_rig(a)
	for i in before.size():
		check(near(before[i].pose, after[i].pose), "round trip " + before[i].name)
		print("BONE ", i, " ", before[i].name, " parent=", before[i].parent, " pos=", (before[i].pose as Transform3D).origin)
	var original: Transform3D = rig.get_bone_pose(0)
	rig.set_bone_pose_position(0, original.origin + Vector3(0, 5, 0))
	check(rig.flush_pose(), "translated pose accepted")
	after = inst.get_instance_rig(a)
	for i in before.size():
		var translated: Transform3D = before[i].pose
		translated.origin += Vector3(0, 5, 0)
		check(near(after[i].pose, translated), "parent motion propagates " + before[i].name)
	check(inst.get_instance_rig(b) == before, "other instance unchanged")
	var bad: Array[Transform3D] = [Transform3D.IDENTITY]
	check(not inst.set_instance_rig_pose(a, bad), "wrong count rejected")
	check(inst.get_instance_rig(a) == after, "invalid input is atomic")
	var nonfinite: Array[Transform3D] = []
	for bone in after: nonfinite.append(bone.pose)
	nonfinite[0].origin.x = NAN
	check(not inst.set_instance_rig_pose(a, nonfinite), "non-finite pose rejected")
	rig.set_bone_pose_scale(0, Vector3(2, 1, 1))
	check(not rig.flush_pose(), "non-rigid scale rejected")
	rig.detach()
	check(inst.get_instance_rig(a) == before, "detach restores original animation")
	check(rig.attach(inst, a) == OK, "reattach")
	rig.name = "Rig"
	var animation: Animation = Stomp.create(rig)
	check(animation != null, "create stomp resource")
	var library := AnimationLibrary.new()
	library.add_animation("stomp", animation)
	var path := "user://custom-rig-test.tres"
	check(ResourceSaver.save(library, path) == OK, "save standard AnimationLibrary")
	var loaded = ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	check(loaded is AnimationLibrary and loaded.has_animation("stomp"), "reload standard AnimationLibrary")
	var player := AnimationPlayer.new()
	root.add_child(player)
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.add_animation_library("custom", loaded)
	player.play("custom/stomp")
	player.seek(0.0, true)
	rig.flush_pose()
	var neutral: Array = inst.get_instance_rig(a)
	player.seek(0.5, true)
	await process_frame
	await process_frame
	var automatic: Array = inst.get_instance_rig(a)
	rig.flush_pose()
	var lifted: Array = inst.get_instance_rig(a)
	check(automatic == lifted, "skeleton_updated uploads without an explicit flush")
	var weapon: int = rig.find_bone("B_WEAPON")
	# tolerance: Skeleton3D's float recomposition should preserve a three-unit authoring offset to 0.0001 model units.
	check(absf((lifted[weapon].pose as Transform3D).origin.y - (neutral[weapon].pose as Transform3D).origin.y - 3.0) < 0.0001, "pike raises three units")
	for name in ["B_TOEL", "B_TOER"]:
		var foot: int = rig.find_bone(name)
		check(near(lifted[foot].pose, neutral[foot].pose), "foot stays planted during lift " + name)
	player.seek(animation.get_marker_time("impact"), true)
	rig.flush_pose()
	var planted: Array = inst.get_instance_rig(a)
	check(near(planted[weapon].pose, neutral[weapon].pose), "pike returns to ground at impact")
	for name in ["B_TOEL", "B_TOER"]:
		var foot: int = rig.find_bone(name)
		check(near(planted[foot].pose, neutral[foot].pose), "foot planted at impact " + name)
	player.seek(animation.length, true)
	rig.flush_pose()
	after = inst.get_instance_rig(a)
	for i in neutral.size(): check(near(after[i].pose, neutral[i].pose), "loop closes " + neutral[i].name)
	player.free()
	DirAccess.remove_absolute(path)
	rig.detach()
	inst.remove_instance(a)
	check(inst.find_model_instances("IUPikeman_SKN") == PackedInt64Array([b]), "removed instances excluded from lookup")
	check(rig.attach(inst, a) != OK, "removed instance rejected")
	rig.free()
	inst.free()
	print("CUSTOM RIG RESULT ", failed)
	quit(0 if failed == 0 else 1)
