## Reusable blade pools with projected-size fading into continuous terrain coverage.
extends Node3D
var terrain_material: ShaderMaterial
var height_image: Image
var world_origin := Vector2.ZERO
var enabled := false:
 set(value):
  enabled = value
  visible = value
  set_process(value)
  if terrain_material != null: terrain_material.set_shader_parameter("grass_surface_enabled", value)
var _patches: Array[MultiMeshInstance3D] = []
var _near_batch: MultiMesh
var _far_batch: MultiMesh
var _last_view: Array = []
var _material: ShaderMaterial
func _ready() -> void:
 for child in get_children():
  if child is MultiMeshInstance3D: _patches.append(child)
 for i in _patches.size():
  _patches[i].set_instance_shader_parameter("patch_span", 128.0 if i >= 256 else 32.0)
  _patches[i].set_instance_shader_parameter("patch_density", 0.65 if i >= 256 else 1.0)
 _near_batch = _patches[0].multimesh
 _far_batch = _patches[256].multimesh
 _near_batch.visible_instance_count = 4096
 _far_batch.visible_instance_count = 2663
 if not _patches.is_empty():
  _material = _patches[0].material_override
  _material.set_shader_parameter("field_fade_enabled", true)
 if terrain_material != null:
  terrain_material.set_shader_parameter("field_fade_enabled", true)
  terrain_material.set_shader_parameter("grass_surface_enabled", enabled)
 visible = enabled
 set_process(enabled)
# Cover the visible frustum up to the depth at which blades become subpixel.
# Pools grow to the largest view seen and reuse shared instance buffers.
func _process(_delta: float) -> void:
 var camera := get_viewport().get_camera_3d()
 if camera == null or _material == null: return
 var eye := camera.global_position
 var direction := -camera.global_basis.z
 var screen := get_viewport().get_visible_rect().size
 var pixel_scale := absf(camera.get_camera_projection().y.y) * screen.y * 0.5
 var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
 for mat in [_material, terrain_material]:
  if mat == null: continue
  mat.set_shader_parameter("grass_projection_scale", pixel_scale)
  mat.set_shader_parameter("grass_orthographic", ortho)
 if terrain_material != null:
  terrain_material.set_shader_parameter("grass_wind_strength", _material.get_shader_parameter("wind_strength"))
 var view := [camera.global_transform,camera.get_camera_projection(),screen]
 if view == _last_view: return
 _last_view = view
 var planes := camera.get_frustum()
 var used := 0
 for layer in 2:
  var span := 32.0 if layer == 0 else 128.0
  var cutoff := 3.0 if layer == 0 else 0.325
  if ortho and 1.8 * pixel_scale <= cutoff: continue
  var depth := camera.far if ortho else minf(camera.far,1.8*pixel_scale/cutoff)
  var low := Vector2(INF,INF)
  var high := Vector2(-INF,-INF)
  for z in [camera.near, depth]:
   for corner in [Vector2.ZERO,Vector2(screen.x,0),screen,Vector2(0,screen.y)]:
    var point := camera.project_position(corner,z)
    low = low.min(Vector2(point.x,point.z))
    high = high.max(Vector2(point.x,point.z))
  # Include leaning blades whose roots are just outside the view.
  low = (low-Vector2.ONE*5).max(Vector2(world_origin.x,-world_origin.y-height_image.get_height()*10.0))
  high = (high+Vector2.ONE*5).min(Vector2(world_origin.x+height_image.get_width()*10.0,-world_origin.y))
  var begin := (low/span).floor()
  var end := (high/span).floor()
  var batch: MultiMesh = _near_batch if layer == 0 else _far_batch
  var bounds := batch.custom_aabb
  for y in range(int(begin.y),int(end.y)+1):
   for x in range(int(begin.x),int(end.x)+1):
    var position := Vector3(x*span,0,y*span)
    var middle := position+bounds.get_center()
    var extent := bounds.size*0.5
    var nearest := direction.dot(middle-eye)-direction.abs().dot(extent)
    var farthest := direction.dot(middle-eye)+direction.abs().dot(extent)
    if farthest < camera.near or nearest > depth: continue
    if layer == 1 and (ortho and 1.8*pixel_scale >= 7.0 or not ortho and farthest < 1.8*pixel_scale/7.0): continue
    var outside := false
    for plane in planes:
     if plane.distance_to(middle) > plane.normal.abs().dot(extent):
      outside = true
      break
    if outside: continue
    if used == _patches.size():
     var extra := MultiMeshInstance3D.new()
     extra.material_override = _material
     extra.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
     add_child(extra)
     _patches.append(extra)
    var patch := _patches[used]
    if patch.multimesh != batch:
     patch.multimesh = batch
     patch.set_instance_shader_parameter("patch_span",span)
     patch.set_instance_shader_parameter("patch_density",1.0 if layer == 0 else 0.65)
    if patch.position != position: patch.position = position
    if not patch.visible: patch.visible = true
    used += 1
 for i in range(used,_patches.size()): _patches[i].visible = false
