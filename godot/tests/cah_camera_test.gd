## Device camera framing remains an explicit S-1405 inference.
extends SceneTree

class MissingCameraWorld extends Node3D:
	func cah_view_info(_class_index: int, _subclass_index: int) -> Dictionary:
		return {"ok": false, "error": "missing camera settings"}

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	root.size = Vector2i(1024, 768)
	var view = load('res://scripts/create_a_hero_view.gd').new()
	root.add_child(view)
	view._cam = Camera3D.new()
	view.add_child(view._cam)
	view._cam.fov = rad_to_deg(0.83)
	view._cam.keep_aspect = Camera3D.KEEP_WIDTH
	view._cull_cam = Camera3D.new()
	view.add_child(view._cull_cam)
	# Retail ViewInfo rows: Olog-hai / Great Troll and Captain of Gondor.
	# Height bounds cover the visible body above the map's hero ground.
	for fixture in [
		{"near": [0.334, 0.262, 78.260, 56.000, 6.300], "far": [-0.036, 0.192, 15.760, 56.500, 15.000], "height": 60.0},
		{"near": [0.354, 0.254, 74.260, 40.000, 5.300], "far": [-0.066, 0.210, 15.760, 20.500, 5.900], "height": 50.0}
	]:
		view._info = fixture.duplicate()
		view._info.camera_offset = Vector3(0, -391, 300)
		view._info.camera_angle = -0.1
		view._facing = -PI / 2.0
		# Hero_0's map ground; translation to Hero_6 must not affect framing.
		for ground in [Vector3(290.5, 890.5, 49.179691), Vector3(690.5, 850.5, 48.984375)]:
			view._hero_sage = ground
			for t in [0.0, 1.0]:
				view._t = t
				view._place_camera('A')
				# Transform assignment decomposes and reconstructs the float32 basis.
				assert(view._cull_cam.global_transform.is_equal_approx(view._cam.global_transform))
				for height in [0.0, fixture.height]:
					var body := Vector3(ground.x, ground.z + height, -ground.y)
					assert(view._cam.is_position_in_frustum(body))
					var local: Vector3 = view._cam.to_local(body)
					# tolerance: camera frustum bounds, rather than exact device pixels.
					assert(-local.z > view._cam.near)
					# tolerance: visible body must fit the horizontal and vertical half-FOV.
					assert(abs(local.x / local.z) < tan(0.83 / 2.0))
					# tolerance: 4:3 is the retail movie viewport aspect.
					assert(abs(local.y / local.z) < tan(0.83 / 2.0) * 0.75)
	view._world = MissingCameraWorld.new()
	view.add_child(view._world)
	view._apply({"class": 0, "subclass": 0})
	assert(view._info.is_empty())
	assert(view.errors == ["missing camera settings"])
	view._place_camera('A')
	print('CAH CAMERA PASS')
	quit()
