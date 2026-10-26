## Opt-in Skeleton3D bridge for a W3DInstancer instance. No meshes or retail assets are copied.
## Use normal Godot AnimationPlayer tracks (RigName:BoneName), or set bone poses procedurally.
## Coordinates are Godot model space, Y up. Scale is unsupported. See docs/CUSTOM_ANIMATION.md.
class_name W3DUnitRig
extends Skeleton3D

var last_error := ""
var _target: WeakRef
var _instance := -1
var _uploading := false

func _init() -> void:
	skeleton_updated.connect(_submit_pose)

func attach(instancer: Node, instance: int) -> Error:
	if not is_instance_valid(instancer) or not instancer.has_method("get_instance_rig"):
		last_error = "This runtime does not provide the custom rig API"
		return ERR_UNAVAILABLE
	var data: Array = instancer.get_instance_rig(instance)
	if data.is_empty():
		last_error = "The instance is missing, removed, or has no rig"
		return ERR_INVALID_PARAMETER
	var owners: Dictionary = instancer.get_meta("w3d_unit_rigs", {})
	var existing = owners.get(instance)
	if existing is WeakRef and is_instance_valid(existing.get_ref()) and existing.get_ref() != self:
		last_error = "This instance already has an attached rig"
		return ERR_ALREADY_IN_USE
	detach()
	clear_bones()
	for entry in data:
		add_bone(entry.name)
	for i in data.size():
		set_bone_parent(i, data[i].parent)
		set_bone_rest(i, data[i].rest)
		var parent: int = data[i].parent
		var local: Transform3D = data[i].pose
		if parent >= 0:
			local = (data[parent].pose as Transform3D).affine_inverse() * local
		set_bone_pose(i, local)
	_target = weakref(instancer)
	_instance = instance
	owners[instance] = weakref(self)
	instancer.set_meta("w3d_unit_rigs", owners)
	last_error = ""
	return OK

## Explicit upload after manual AnimationPlayer.advance()/seek() or procedural posing.
## Automatic uploads use skeleton_updated, after Godot's modifier stack has finished.
func flush_pose() -> bool:
	var target = _target.get_ref() if _target else null
	if not is_instance_valid(target):
		return false
	var pose: Array[Transform3D] = []
	for i in get_bone_count():
		pose.append(get_bone_global_pose(i))
	if not target.set_instance_rig_pose(_instance, pose):
		last_error = "Pose rejected: require the original bone count and finite rigid transforms"
		return false
	target.update_now()
	last_error = ""
	return true

func _submit_pose() -> void:
	if _uploading:
		return
	_uploading = true
	flush_pose()
	_uploading = false

## Release ownership; the instance resumes its normal W3D animation on the next update.
func detach() -> void:
	var target = _target.get_ref() if _target else null
	if is_instance_valid(target):
		target.set_instance_rig_pose(_instance, [])
		target.update_now()
		var owners: Dictionary = target.get_meta("w3d_unit_rigs", {})
		owners.erase(_instance)
		target.set_meta("w3d_unit_rigs", owners)
	_target = null
	_instance = -1

func _exit_tree() -> void:
	detach()
