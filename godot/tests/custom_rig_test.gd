## The custom unit rig API (NOT RETAIL, docs/CUSTOM_ANIMATION.md): W3DInstancer's model rig, clip and instance rig poses, the pose override and
## its errors, and the W3DUnitRig Skeleton3D bridge (scripts/animation/w3d_unit_rig.gd) driven by a standard AnimationPlayer.
## Needs the user's own RotWK 2.01 / BFME2 1.06 installs (ROTWK_INSTALL, BFME2_INSTALL); prints SKIP and exits 77 without them.
##   godot --headless --path godot --script res://tests/custom_rig_test.gd
## Expected numbers are measured on the retail IUPikeman_SKN (19 pivots, 382 drawn vertices) and GUAragorn_SKN; no game data is embedded.
extends SceneTree

const UnitRig = preload("res://scripts/animation/w3d_unit_rig.gd")
const PIKEMAN := "IUPikeman_SKN"
const IDLE := "IUPIKEMAN_SKL.IUPIKEMAN_IDLA" # 60 frames at 30 per second
const PIVOTS := 19
const DRAWN := 382
const WEAPON := 17 # B_WEAPON, the pike, child of the root
const WEAPON_VERTICES := 58
const WEAPON_BOUNDS := "AABB(-0.28799963, -12.682265, -0.30566698, 2.367608, 66.27498, 0.6236506)"

var failed := 0
var inst: Node
var model := -1


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, what: String) -> void:
	print("RIG ", "PASS " if ok else "FAIL ", what)
	if not ok:
		failed += 1


func near(a: Transform3D, b: Transform3D) -> bool:
	# tolerance: single-precision Transform3D composition and inversion down the 19-pivot hierarchy; 0.0001 model units (rigs span ~70 units).
	return a.origin.distance_to(b.origin) < 0.0001 and (a.basis.x - b.basis.x).length() < 0.0001 and (a.basis.y - b.basis.y).length() < 0.0001 \
		and (a.basis.z - b.basis.z).length() < 0.0001


func all_near(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not near(a[i], b[i]):
			return false
	return true


func raised(pose: Array, by: Vector3) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for t in pose:
		out.append((t as Transform3D).translated(by))
	return out


## The call fails, records exactly one error with this text, and changes nothing the caller can see.
func refused(ok, message: String, what: String) -> void:
	var errors: PackedStringArray = inst.get_errors()
	check(ok == false and errors.size() > 0 and errors[-1] == message, "%s: %s" % [what, errors[-1] if errors.size() > 0 else "(no error)"])


func run() -> void:
	var fs = ClassDB.instantiate("RetailFileSystem")
	if not fs.mount_retail().ok:
		print("SKIP: retail installs required (ROTWK_INSTALL, BFME2_INSTALL)")
		quit(77)
		return
	inst = ClassDB.instantiate("W3DInstancer")
	root.add_child(inst)
	inst.setup(fs)
	inst.set_auto_update(false)
	model = inst.add_model(PIKEMAN)
	check_model_rig()
	var a: int = inst.add_instance(model, Transform3D.IDENTITY, IDLE, 0.0, 1.0)
	var b: int = inst.add_instance(model, Transform3D.IDENTITY, IDLE, 0.0, 1.0)
	inst.set_global_time(0.0)
	inst.update_now()
	check_clip_pose(a)
	check_lookup(a, b)
	check_override(a, b)
	check_batch(a, b)
	check_refusals(a, b)
	await check_bridge(a)
	check_removal(a, b)
	check(inst.get_errors().size() == 16, "exactly the 16 refusals above were recorded (%d)" % inst.get_errors().size())
	inst.free()
	print("CUSTOM RIG RESULT ", failed)
	quit(0 if failed == 0 else 1)


func check_model_rig() -> void:
	var rig: Array = inst.get_model_rig(model)
	check(rig.size() == PIVOTS, "pikeman hierarchy has %d pivots" % rig.size())
	var names := {}
	var parents_first := true
	var carried := 0
	for i in rig.size():
		names[rig[i].name] = true
		parents_first = parents_first and rig[i].parent < i
		carried += int(rig[i].vertices)
	check(names.size() == PIVOTS and rig[0].parent == -1 and parents_first, "unique names, one root, parents listed first")
	check(carried == DRAWN, "every drawn vertex counts for one pivot (%d)" % carried)
	check(rig[WEAPON].name == "B_WEAPON" and rig[WEAPON].vertices == WEAPON_VERTICES, "B_WEAPON carries the pike's %d vertices" % rig[WEAPON].vertices)
	check(rig[WEAPON].bounds == str_to_var(WEAPON_BOUNDS), "the pike's box in its pivot's frame: " + var_to_str(rig[WEAPON].bounds))
	check(rig[0].vertices == 0 and rig[0].bounds == AABB(), "the root carries nothing")
	check(inst.get_model_rig(model) == rig, "the rig is the same on a second call")
	# rests are relative to the parent: composed down the hierarchy they are the bind pose of an instance without a clip
	var bind: int = inst.add_instance(model, Transform3D.IDENTITY, "", 0.0, 1.0)
	inst.update_now()
	var composed: Array[Transform3D] = []
	for i in rig.size():
		composed.append(rig[i].rest if rig[i].parent < 0 else composed[rig[i].parent] * (rig[i].rest as Transform3D))
	check(all_near(composed, inst.get_instance_rig_pose(bind)), "rests composed give the bind pose")
	inst.remove_instance(bind)


func check_clip_pose(a: int) -> void:
	var at_zero: Array = inst.get_clip_rig_pose(model, IDLE, 0.0)
	check(at_zero.size() == PIVOTS and at_zero == inst.get_instance_rig_pose(a), "a clip sampled without an instance is the instance's pose at frame 0")
	check(inst.get_clip_rig_pose(model, IDLE, 59.0).size() == PIVOTS, "the last frame samples")
	check(inst.get_clip_rig_pose(model, IDLE, 12.5) != inst.get_clip_rig_pose(model, IDLE, 12.0), "a fractional frame interpolates")


func check_lookup(a: int, b: int) -> void:
	check(inst.find_model_instances("iupikeman_skn") == PackedInt64Array([a, b]), "instances found by model name, case-insensitively")
	check(inst.find_model_instances("NoSuchModel_SKN").is_empty(), "an unknown name finds none")
	check(inst.get_instance_model(a) == model, "the instance's model")
	var placed := Transform3D(Basis(Vector3.UP, 0.5), Vector3(12.5, 3.0, -7.25))
	inst.set_instance_transform(b, placed)
	check(inst.get_instance_transform(b) == placed, "the placement reads back")
	inst.set_instance_transform(b, Transform3D.IDENTITY)


func check_override(a: int, b: int) -> void:
	var clip: Array = inst.get_instance_rig_pose(a)
	var up := raised(clip, Vector3(0, 2, 0))
	check(inst.set_instance_rig_pose(a, up), "a rigid pose is accepted")
	check(inst.get_instance_rig_pose(a) == clip, "until the next update the pose is the last update's")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == up, "after the update the pose reads back exactly")
	check(inst.get_instance_rig_pose(b) == clip, "the other instance keeps its clip")
	# the override holds over a clip change and the clock; only the clip-driven instance is evaluated again
	check(inst.set_instance_clip(a, IDLE, 0.25, 1.0), "the clip underneath changes")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == up, "a clip change does not replace the override")
	inst.set_global_time(1.0)
	inst.update_now()
	check(inst.get_stats().pose_evaluations == 1, "a held pose is not evaluated as the clock runs (%d evaluated)" % inst.get_stats().pose_evaluations)
	check(inst.get_instance_rig_pose(a) == up, "the override holds over the clock")
	check(inst.set_instance_clip(a, IDLE, 0.0, 1.0) and inst.set_instance_rig_pose(a, []), "the override is cleared")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == inst.get_instance_rig_pose(b), "clearing returns to the clip at the clock's time")
	inst.set_global_time(0.0)
	inst.update_now()


func check_batch(a: int, b: int) -> void:
	var up := raised(inst.get_instance_rig_pose(a), Vector3(0, 4, 0))
	check(inst.set_instances_rig_pose(PackedInt64Array([a, b]), up), "one pose for a batch")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == up and inst.get_instance_rig_pose(b) == up, "both instances take it")
	check(inst.set_instances_rig_pose(PackedInt64Array(), up), "an empty batch is a no-op")
	check(inst.set_instances_rig_pose(PackedInt64Array([a, b]), []), "a batch clears")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == inst.get_clip_rig_pose(model, IDLE, 0.0), "cleared batch is back on its clip")


func check_refusals(a: int, b: int) -> void:
	var clip: Array = inst.get_instance_rig_pose(a)
	var hierarchy: String = inst.get_model_report(model).hierarchy
	var first: String = inst.get_model_rig(model)[0].name
	refused(inst.set_instances_rig_pose(PackedInt64Array([a, 999999]), clip), "set_instance_rig_pose: no instance 999999", "an unknown instance")
	var one: Array[Transform3D] = [Transform3D.IDENTITY]
	refused(inst.set_instance_rig_pose(a, one), "set_instance_rig_pose: hierarchy %s has %d pivots, the pose has 1" % [hierarchy, PIVOTS], "a short pose")
	var scaled: Array[Transform3D] = []
	scaled.assign(clip)
	scaled[0] = scaled[0].scaled_local(Vector3(2, 1, 1))
	refused(inst.set_instance_rig_pose(a, scaled), "set_instance_rig_pose: pose[0] (%s) is scaled or sheared" % first, "a scaled pivot")
	var mirrored: Array[Transform3D] = []
	mirrored.assign(clip)
	mirrored[0] = Transform3D(Basis.FLIP_X, Vector3.ZERO)
	refused(inst.set_instance_rig_pose(a, mirrored), "set_instance_rig_pose: pose[0] (%s) is a reflection" % first, "a reflected pivot")
	var broken: Array[Transform3D] = []
	broken.assign(clip)
	broken[3].origin.x = NAN
	refused(inst.set_instance_rig_pose(a, broken), "set_instance_rig_pose: pose[3] (BAT_CALFL) is not finite", "a NaN")
	var other_model: int = inst.add_model("GUAragorn_SKN")
	var other: int = inst.add_instance(other_model, Transform3D.IDENTITY, "", 0.0, 1.0)
	var other_hierarchy: String = inst.get_model_report(other_model).hierarchy
	refused(inst.set_instances_rig_pose(PackedInt64Array([a, other]), clip),
		"set_instance_rig_pose: instances %d and %d have different hierarchies (%s, %s)" % [a, other, hierarchy, other_hierarchy], "two hierarchies")
	refused(inst.get_clip_rig_pose(model, IDLE, 59.5).is_empty() == false, "get_clip_rig_pose: frame 59.500000 is outside IUPIKEMAN_SKL.IUPIKEMAN_IDLA (0 .. 59)",
		"a frame past the clip")
	refused(inst.get_clip_rig_pose(model, IDLE, -1.0).is_empty() == false, "get_clip_rig_pose: frame -1.000000 is outside IUPIKEMAN_SKL.IUPIKEMAN_IDLA (0 .. 59)",
		"a negative frame")
	refused(inst.get_clip_rig_pose(model, "NO_SUCH_CLIP", 0.0).is_empty() == false, "clip NO_SUCH_CLIP is not registered for hierarchy " + hierarchy, "an unknown clip")
	refused(inst.get_model_rig(99).is_empty() == false, "get_model_rig: no model 99", "an unknown model")
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == clip and inst.get_instance_rig_pose(b) == clip, "refused calls changed no pose")
	inst.remove_instance(other)


func check_bridge(a: int) -> void:
	var clip: Array = inst.get_instance_rig_pose(a)
	var actor := Node3D.new()
	root.add_child(actor)
	var rig: Skeleton3D = UnitRig.new()
	rig.name = "Rig"
	actor.add_child(rig)
	check(rig.attach(inst, a) == OK and rig.get_bone_count() == PIVOTS, "attach builds the pivots as bones")
	check(rig.get_bone_name(WEAPON) == "B_WEAPON" and rig.get_bone_parent(WEAPON) == 0, "bone names and parents")
	var second: Skeleton3D = UnitRig.new()
	check(second.attach(inst, a) == ERR_ALREADY_IN_USE and second.last_error == "instance %d already has a rig" % a, "one rig per instance")
	second.free()
	check(rig.flush_pose(), "the attached pose is accepted")
	inst.update_now()
	var round_trip: Array = inst.get_instance_rig_pose(a)
	check(all_near(round_trip, clip), "local bone poses compose back to the instance's pose")
	rig.set_bone_pose_position(0, rig.get_bone_pose_position(0) + Vector3(0, 5, 0))
	check(rig.flush_pose(), "a moved root is accepted")
	inst.update_now()
	check(all_near(inst.get_instance_rig_pose(a), raised(clip, Vector3(0, 5, 0))), "every pivot follows the root")
	rig.set_bone_pose_scale(0, Vector3(2, 1, 1))
	check(not rig.flush_pose(), "a scaled bone is refused")
	check(rig.last_error == "set_instance_rig_pose: pose[0] (%s) is scaled or sheared" % rig.get_bone_name(0), "the instancer's reason: " + rig.last_error)
	rig.set_bone_pose_scale(0, Vector3.ONE)
	rig.set_bone_pose_position(0, rig.get_bone_pose_position(0) - Vector3(0, 5, 0))
	# a standard AnimationPlayer track on "Rig:<pivot>" drives the unit; uploads follow skeleton_updated without an explicit flush
	var start: Vector3 = rig.get_bone_pose_position(0)
	var animation := Animation.new()
	animation.length = 1.0
	var track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(track, NodePath("Rig:" + rig.get_bone_name(0)))
	animation.position_track_insert_key(track, 0.0, start)
	animation.position_track_insert_key(track, 1.0, start + Vector3(0, 3, 0))
	var library := AnimationLibrary.new()
	library.add_animation("lift", animation)
	var player := AnimationPlayer.new()
	actor.add_child(player)
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.add_animation_library("custom", library)
	player.play("custom/lift")
	player.seek(0.5, true)
	await process_frame
	await process_frame
	check(all_near(inst.get_instance_rig_pose(a), raised(clip, Vector3(0, 1.5, 0))), "the player's track reaches the instance at 0.5 s")
	player.free()
	rig.detach()
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == clip, "detach returns the instance to its clip")
	var third: Skeleton3D = UnitRig.new()
	check(third.attach(inst, a) == OK, "a detached instance takes a new rig")
	third.set_bone_pose_position(0, third.get_bone_pose_position(0) + Vector3(0, 1, 0))
	check(third.flush_pose(), "the new rig poses it")
	third.free()
	inst.update_now()
	check(inst.get_instance_rig_pose(a) == clip, "freeing a rig releases its instance")
	actor.free()


func check_removal(a: int, b: int) -> void:
	check(inst.set_instance_rig_pose(a, raised(inst.get_instance_rig_pose(a), Vector3(0, 1, 0))), "a pose before removal")
	inst.remove_instance(a)
	check(inst.set_instance_rig_pose(a, []), "clearing a removed instance succeeds")
	refused(inst.set_instance_rig_pose(a, inst.get_instance_rig_pose(b)), "set_instance_rig_pose: instance %d was removed" % a, "posing a removed instance")
	refused(inst.get_instance_rig_pose(a).is_empty() == false, "get_instance_rig_pose: instance %d was removed" % a, "reading a removed instance")
	refused(inst.get_instance_model(a) >= 0, "get_instance_model: instance %d was removed" % a, "the model of a removed instance")
	refused(inst.get_instance_transform(a) != Transform3D.IDENTITY, "get_instance_transform: instance %d was removed" % a, "the placement of a removed instance")
	check(inst.find_model_instances(PIKEMAN) == PackedInt64Array([b]), "a removed instance is not found")
	var rig: Skeleton3D = UnitRig.new()
	check(rig.attach(inst, a) == ERR_INVALID_PARAMETER and rig.last_error == "get_instance_model: instance %d was removed" % a, "a rig refuses a removed instance")
	rig.free()
