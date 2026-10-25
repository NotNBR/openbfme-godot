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
var _occupancy := {}
var _occupancy_key: Array = []
var _guide := PackedByteArray()
var _guide_size := Vector2i.ZERO
var _habitat := PackedByteArray()
var _habitat_size := Vector2i.ZERO
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
 if _refresh_occupancy(): _last_view = []
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
    if not _has_grass(span, x, y): continue
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

# Patches where the terrain guide grows no grass and no litter draw only dead blades; skip them. Each patch is
# examined once, on first view, against the guide texels its blades can sample (grass_density's step(0.012, mask),
# the litter test guide.a + habitat.r >= 0.025, with bilinear filtering and the roots' reach past the patch edge).
func _refresh_occupancy() -> bool:
 var guide = _material.get_shader_parameter("terrain_guide")
 var litter_param = _material.get_shader_parameter("ground_litter_enabled")      # unset: the shader's default, on
 var litter: bool = (litter_param == null or bool(litter_param)) and _material.get_shader_parameter("habitat_enabled") == true
 var habitat = _material.get_shader_parameter("habitat_guide") if litter else null
 var key := [guide, habitat, _material.get_shader_parameter("world_origin"), _material.get_shader_parameter("grid_size")]
 if key == _occupancy_key: return false
 _occupancy_key = key
 _occupancy.clear()
 _guide = _texels(guide) if key[2] is Vector2 and key[3] is Vector2 else PackedByteArray()    # undecided: draw every patch
 _guide_size = Vector2i(guide.get_width(), guide.get_height()) if guide != null else Vector2i.ZERO
 _habitat = _texels(habitat)
 _habitat_size = Vector2i(habitat.get_width(), habitat.get_height()) if habitat != null else Vector2i.ZERO
 return true
func _texels(texture: Texture2D) -> PackedByteArray:
 if texture == null: return PackedByteArray()
 var image := texture.get_image()
 if image.is_compressed(): image.decompress()
 image.clear_mipmaps()
 if image.get_format() != Image.FORMAT_RGBA8: image.convert(Image.FORMAT_RGBA8)
 return image.get_data()
# The largest byte of `channel` among the texels bilinear sampling can read for ground points in [low, high].
func _peak(data: PackedByteArray, size: Vector2i, channel: int, low: Vector2, high: Vector2) -> int:
 var origin: Vector2 = _occupancy_key[2]
 var grid: Vector2 = _occupancy_key[3]
 var scale := Vector2(size)/(grid*10.0)
 var a := Vector2i(((low-origin)*scale-Vector2(0.5,0.5)).floor()).clamp(Vector2i.ZERO,size-Vector2i.ONE)
 var b := (Vector2i(((high-origin)*scale-Vector2(0.5,0.5)).floor())+Vector2i.ONE).clamp(Vector2i.ZERO,size-Vector2i.ONE)
 var peak := 0
 for row in range(a.y,b.y+1):
  var i := (row*size.x+a.x)*4+channel
  for column in range(a.x,b.x+1):
   peak = maxi(peak,data[i])
   i += 4
 return peak
func _has_grass(span: float, x: int, y: int) -> bool:
 if _guide.is_empty(): return true
 var key := Vector3i(x,y,int(span))
 if _occupancy.has(key): return _occupancy[key]
 # Roots reach span/75 outside their patch (cluster centre plus radius); godot z is -ground y.
 var margin := span/64.0
 var low := Vector2(x*span-margin,-(y*span+span+margin))
 var high := Vector2(x*span+span+margin,-(y*span-margin))
 var alpha := _peak(_guide,_guide_size,3,low,high)
 var grows := alpha >= 4                                   # 3/255 < 0.012
 if not grows and span < 64.0 and not _habitat.is_empty():
  grows = alpha+_peak(_habitat,_habitat_size,0,low,high) >= 7    # 6/255 < 0.025
 _occupancy[key] = grows
 return grows