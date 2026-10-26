## Original procedural example: raise the pike butt, stamp it down, recoil and settle.
## Builds a standard Godot Animation from the currently captured upright pikeman pose.
## No baked retail animation or geometry is distributed. See CUSTOM_ANIMATION.md.
extends RefCounted

const IMPACT_TIME := 0.66
const DURATION := 1.4
const PHASE_SPREAD := 0.12
const TIMES := [0.0, 0.28, 0.48, 0.57, IMPACT_TIME, 0.74, 1.0, DURATION]
const LIFT := [0.0, 1.0, 3.0, 3.0, 0.0, 0.25, 0.0, 0.0]
const HIP := [0.0, 0.0, 0.0, 0.0, -0.4, -0.18, 0.0, 0.0]
const REQUIRED := ["BAT_PELVIS", "BAT_SPINE2", "BAT_UARML", "BAT_FARML", "B_HANDL",
	"BAT_UARMR", "BAT_FARMR", "B_HANDR", "BAT_THIGHL", "BAT_CALFL", "B_TOEL",
	"BAT_THIGHR", "BAT_CALFR", "B_TOER", "B_WEAPON"]

static func curve(values: Array, time: float) -> float:
	for i in TIMES.size() - 1:
		if time <= TIMES[i + 1]:
			var u: float = clampf((time - TIMES[i]) / (TIMES[i + 1] - TIMES[i]), 0.0, 1.0)
			return lerpf(values[i], values[i + 1], u * u * (3.0 - 2.0 * u))
	return values[-1]

## Rotate a two-segment chain onto an endpoint, retaining its sampled bend direction.
## Used only to author the example; the resulting Animation needs no IK solver at playback.
static func solve_limb(rig: Skeleton3D, names: Array, goal: Vector3, end_basis: Basis) -> void:
	var a := rig.find_bone(names[0])
	var b := rig.find_bone(names[1])
	var c := rig.find_bone(names[2])
	var upper := rig.get_bone_global_pose(a)
	var lower := rig.get_bone_global_pose(b)
	var end := rig.get_bone_global_pose(c)
	var first := lower.origin.distance_to(upper.origin)
	var second := end.origin.distance_to(lower.origin)
	var direction := (goal - upper.origin).normalized()
	var distance := clampf(goal.distance_to(upper.origin), absf(first - second) + 0.001, first + second - 0.001)
	var pole := lower.origin - upper.origin
	pole = (pole - direction * pole.dot(direction)).normalized()
	if pole.is_zero_approx():
		pole = direction.cross(Vector3.FORWARD).normalized()
	var along := (first * first - second * second + distance * distance) / (2.0 * distance)
	var elbow := upper.origin + direction * along + pole * sqrt(maxf(0.0, first * first - along * along))
	upper.basis = Basis(Quaternion((lower.origin - upper.origin).normalized(), (elbow - upper.origin).normalized())) * upper.basis
	rig.set_bone_global_pose(a, upper)
	lower = rig.get_bone_global_pose(b)
	end = rig.get_bone_global_pose(c)
	lower.basis = Basis(Quaternion((end.origin - lower.origin).normalized(), (goal - lower.origin).normalized())) * lower.basis
	rig.set_bone_global_pose(b, lower)
	end = rig.get_bone_global_pose(c)
	end.basis = end_basis
	rig.set_bone_global_pose(c, end)

static func create(rig: Skeleton3D, settings: Dictionary = {}) -> Animation:
	for bone in REQUIRED:
		if rig.find_bone(bone) < 0:
			push_error("Pike stomp requires bone " + bone)
			return null
	var original: Array[Transform3D] = []
	var globals: Array[Transform3D] = []
	for i in rig.get_bone_count():
		original.append(rig.get_bone_pose(i))
		globals.append(rig.get_bone_global_pose(i))
	var animation := Animation.new()
	animation.resource_name = "Uruk pike stomp"
	animation.length = DURATION
	animation.loop_mode = Animation.LOOP_LINEAR
	animation.add_marker("impact", IMPACT_TIME)
	for i in rig.get_bone_count():
		for type in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D]:
			var track := animation.add_track(type)
			animation.track_set_path(track, NodePath(str(rig.name) + ":" + rig.get_bone_name(i)))
	var samples: Array[float] = []
	for frame in int(DURATION * 30) + 1: samples.append(frame / 30.0)
	# Preserve contact/anticipation keys even when they fall between 30 Hz samples.
	for time in TIMES:
		if not samples.has(time): samples.append(time)
	samples.sort()
	for time in samples:
		for i in original.size(): rig.set_bone_pose(i, original[i])
		var lift := curve(LIFT, time)
		var hip := rig.find_bone("BAT_PELVIS")
		var hips := globals[hip]
		hips.origin.y += curve(HIP, time) * clampf(float(settings.get("knee_dip", 0.4)), 0.0, 1.0) / 0.4
		rig.set_bone_global_pose(hip, hips)
		var weapon := rig.find_bone("B_WEAPON")
		var pike := globals[weapon]
		pike.origin.y += lift
		rig.set_bone_global_pose(weapon, pike)
		for side in ["L", "R"]:
			var hand := globals[rig.find_bone("B_HAND" + side)]
			solve_limb(rig, ["BAT_UARM" + side, "BAT_FARM" + side, "B_HAND" + side], hand.origin + Vector3.UP * lift, hand.basis)
			var foot := globals[rig.find_bone("B_TOE" + side)]
			solve_limb(rig, ["BAT_THIGH" + side, "BAT_CALF" + side, "B_TOE" + side], foot.origin, foot.basis)
		for i in rig.get_bone_count():
			animation.position_track_insert_key(i * 2, time, rig.get_bone_pose_position(i))
			animation.rotation_track_insert_key(i * 2 + 1, time, rig.get_bone_pose_rotation(i))
	for i in original.size(): rig.set_bone_pose(i, original[i])
	return animation
