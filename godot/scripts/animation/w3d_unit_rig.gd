## NOT RETAIL: an OpenBFME addition for tools and cinematics (docs/CUSTOM_ANIMATION.md). Presentation only; the simulation never reads it.
## A Skeleton3D that drives the pose of one W3DInstancer instance, so Godot's AnimationPlayer / AnimationTree tracks ("<rig>:<pivot name>")
## and skeleton modifiers animate a W3D unit. The instancer keeps drawing the unit with its own meshes and GPU skinning; this node only hands it
## the final pose (W3DInstancer.set_instance_rig_pose). No mesh, texture or animation data is copied.
##
##   attach(instancer, instance)  bones from the model's hierarchy (names, parents, rests), posed as the instance was at the instancer's last
##                                update; one rig per instance
##   flush_pose()                 hands the current pose to the instancer. Done after every skeleton update (after the modifier stack), with one
##                                deferred instancer update per frame; after a manual flush call the instancer's update_now() yourself
##   detach()                     releases the override; the instance's clip takes over again. Also done on leaving the tree and on free
##
## A call that fails returns an error code or false, changes nothing and sets last_error to the instancer's reason (its get_errors()).
## Track keys are local bone poses (relative to the parent bone, Skeleton3D's convention) in Godot axes; scale is refused (W3D skinning is rigid).
extends Skeleton3D

static var _owners := {}  # "<instancer object id>:<instance>" -> WeakRef of the rig that owns it
static var _updates := {} # instancer object id -> true while its deferred update_now is queued

var last_error := ""
var _target: WeakRef = null
var _instance := -1


func _init() -> void:
	skeleton_updated.connect(_on_skeleton_updated)


func attach(instancer: Node, instance: int) -> Error:
	detach()
	var model: int = instancer.get_instance_model(instance)
	if model < 0:
		return _fail(instancer, "get_instance_model:", ERR_INVALID_PARAMETER)
	var key := _key(instancer, instance)
	var holder = _owners.get(key)
	if holder is WeakRef and holder.get_ref() != null and holder.get_ref() != self:
		last_error = "instance %d already has a rig" % instance
		return ERR_ALREADY_IN_USE
	var rig: Array = instancer.get_model_rig(model)
	if rig.is_empty():
		return _fail(instancer, "get_model_rig:", ERR_INVALID_DATA)
	var pose: Array = instancer.get_instance_rig_pose(instance)
	if pose.size() != rig.size():
		return _fail(instancer, "get_instance_rig_pose:", ERR_INVALID_DATA)
	clear_bones()
	for i in rig.size():
		if add_bone(rig[i].name) != i:
			clear_bones()
			last_error = "pivot %d (%s) cannot be a Skeleton3D bone (an empty, repeated or ':' / '/' name)" % [i, rig[i].name]
			return ERR_INVALID_DATA
	for i in rig.size():
		var parent: int = rig[i].parent
		set_bone_parent(i, parent)
		set_bone_rest(i, rig[i].rest)
		set_bone_pose(i, pose[i] if parent < 0 else (pose[parent] as Transform3D).affine_inverse() * (pose[i] as Transform3D))
	_target = weakref(instancer)
	_instance = instance
	_owners[key] = weakref(self)
	last_error = ""
	return OK


## Hands the current global bone poses to the instancer. False (and last_error) when unattached or when the instancer refuses the pose.
func flush_pose() -> bool:
	var target = _target.get_ref() if _target != null else null
	if target == null:
		last_error = "not attached"
		return false
	var pose: Array[Transform3D] = []
	pose.resize(get_bone_count())
	for i in get_bone_count():
		pose[i] = get_bone_global_pose(i)
	if not target.set_instance_rig_pose(_instance, pose):
		_fail(target, "set_instance_rig_pose:", FAILED)
		return false
	last_error = ""
	return true


func detach() -> void:
	var target = _target.get_ref() if _target != null else null
	if target != null:
		target.set_instance_rig_pose(_instance, []) # a removed instance holds no override: clearing it succeeds
		_request_update(target)
		_owners.erase(_key(target, _instance))
	_target = null
	_instance = -1


func get_instancer() -> Node:
	return _target.get_ref() if _target != null else null


func get_instance() -> int:
	return _instance


func _on_skeleton_updated() -> void:
	if _target != null and flush_pose():
		_request_update(_target.get_ref())


## One update_now per instancer per frame, deferred to the end of the frame so every rig's pose of that frame is drawn in it.
func _request_update(target: Node) -> void:
	var id := target.get_instance_id()
	if _updates.has(id):
		return
	_updates[id] = true
	var run := func() -> void:
		_updates.erase(id)
		var node := instance_from_id(id)
		if node != null:
			node.update_now()
	run.call_deferred()


func _fail(instancer: Node, prefix: String, code: Error) -> Error:
	var errors: PackedStringArray = instancer.get_errors()
	for i in range(errors.size() - 1, -1, -1):
		if errors[i].begins_with(prefix):
			last_error = errors[i]
			return code
	last_error = prefix + " failed without a recorded reason"
	return code


func _key(instancer: Node, instance: int) -> String:
	return "%d:%d" % [instancer.get_instance_id(), instance]


func _exit_tree() -> void:
	detach()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		detach()
