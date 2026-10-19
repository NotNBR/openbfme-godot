## Named-camera placement: Floor is an absolute plane, not hero Z + Floor.
extends SceneTree

class MissingCameraWorld extends Node3D:
	func cah_view_info(_class_index: int, _subclass_index: int) -> Dictionary:
		return {"ok": false, "error": "missing camera settings"}

func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var view = load('res://scripts/create_a_hero_view.gd').new()
	root.add_child(view)
	view._cam = Camera3D.new()
	view.add_child(view._cam)
	view._cull_cam = Camera3D.new()
	view.add_child(view._cull_cam)
	view._hero_sage = Vector3(0, 0, 50)
	view._t = 0.0
	view._info = {'near':[0.0,0.25,60.0,30.0,0.0], 'camera_offset':Vector3(0,-400,300)}
	view._place_camera('A')
	# Donor mode-1 example: scaled offset (0,-100,75), factor 1-60/75=0.2,
	# heading pi/2 -> (20,0,15), translated by point (30,0) and Floor 60.
	assert(view._cam.position.distance_to(Vector3(50,75,0)) < 0.0001) # tolerance: sin/cos(pi/2) and float32 camera transforms introduce rounding.
	assert(view._cull_cam.global_transform == view._cam.global_transform)
	view._world = MissingCameraWorld.new()
	view.add_child(view._world)
	view._apply({"class": 0, "subclass": 0})
	assert(view._info.is_empty())
	assert(view.errors == ["missing camera settings"])
	view._place_camera('A') # A failed refresh must not read camera_offset.
	print('CAH CAMERA PASS')
	quit()
