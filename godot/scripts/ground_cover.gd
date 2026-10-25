## Two fixed camera-local rings: dense near blades and a sparse distant field.
extends Node3D
var height_image: Image
var world_origin := Vector2.ZERO
var enabled := false:
 set(value):
  enabled = value
  visible = value
  set_process(value)
var _patches: Array[MultiMeshInstance3D] = []
var _material: ShaderMaterial
func _ready() -> void:
 for child in get_children():
  if child is MultiMeshInstance3D: _patches.append(child)
 for i in _patches.size():
  _patches[i].set_instance_shader_parameter("patch_span", 128.0 if i >= 256 else 32.0)
  _patches[i].set_instance_shader_parameter("patch_density", 0.65 if i >= 256 else 1.0)
 if not _patches.is_empty():
  _material = _patches[0].material_override
  _material.set_shader_parameter("field_fade_enabled", true)
 visible = enabled
 set_process(enabled)
func _height_at(point: Vector3) -> float:
 var pixel := (Vector2(point.x, -point.z) - world_origin) / 10.0
 return height_image.get_pixel(clampi(roundi(pixel.x), 0, height_image.get_width()-1), clampi(roundi(pixel.y), 0, height_image.get_height()-1)).r
func _process(_delta: float) -> void:
 var camera := get_viewport().get_camera_3d()
 if camera == null or _material == null: return
 var eye := camera.global_position
 var direction := -camera.global_basis.z
 var focus := eye
 if direction.y < -0.05:
  for j in 4:
   focus = eye + direction * maxf(0.0, (eye.y - _height_at(focus)) / -direction.y)
 var center := Vector2(focus.x, focus.z)
 var zoom := 1.0 - smoothstep(1400.0, 3000.0, eye.distance_to(focus))
 _material.set_shader_parameter("field_center", center)
 _material.set_shader_parameter("field_zoom", zoom)
 for i in _patches.size():
  var patch := _patches[i]
  var outer := i >= 256
  var span := 128.0 if outer else 32.0
  var index := i % 256
  var anchor := (center / span).floor()
  var tile := anchor + Vector2(index % 16 - 8, floori(float(index) / 16.0) - 8)
  var position_xz := tile * span
  var next_position := Vector3(position_xz.x, 0, position_xz.y)
  if patch.position != next_position: patch.position = next_position
  var radius := (position_xz + Vector2.ONE * span * 0.5).distance_to(center)
  # Conservative patch culling; the shader fades each blade continuously, not whole tiles.
  var active := zoom > 0.001 and (radius < 1011.0 if outer else radius < 243.0)
  if outer and radius < 49.0: active = false
  if patch.visible != active: patch.visible = active
  var count := (2663 if outer else 4096) if active else 0
  if patch.multimesh.visible_instance_count != count: patch.multimesh.visible_instance_count = count
