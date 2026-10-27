## Shadowfax's retail colour is a JPEG with a companion PNG, not a DDS/TGA.
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _check_texture(texture: Texture2D, colour: Image, mask: Image) -> bool:
	if texture == null:
		return false
	var image := texture.get_image()
	if image == null or image.is_empty() or image.get_size() != colour.get_size():
		return false
	image.convert(Image.FORMAT_RGBA8)
	for point in [Vector2i(0, 0), Vector2i(32, 32), Vector2i(64, 64)]:
		var c := colour.get_pixelv(point)
		var m := mask.get_pixelv(point)
		# Convert through RGBA8 to match the decoder's stored pixel precision.
		var expected := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		expected.set_pixel(0, 0, Color(c.r * m.r, c.g * m.g, c.b * m.b, m.a))
		if image.get_pixelv(point) != expected.get_pixel(0, 0):
			return false
	return true

func _check_corrupt_mask() -> bool:
	# Synthetic mod assets keep retail bytes out of fixtures. A bad companion
	# must fail decoding instead of making an opaque JPEG appear successful.
	var temp := OS.get_environment("TMPDIR")
	if temp.is_empty():
		temp = OS.get_environment("TEMP")
	if temp.is_empty():
		temp = "/tmp"
	var mod_path := temp.path_join("openbfme-packed-texture-" + str(OS.get_process_id()))
	var folder := mod_path.path_join("art/compiledtextures/zz")
	assert(DirAccess.make_dir_recursive_absolute(folder) == OK)
	var jpg := folder.path_join("zzpackedprobe.jpg")
	var png := folder.path_join("zzpackedprobe.png")
	var plain_jpg := folder.path_join("zzpackedplain.jpg")
	var image := Image.create(2, 2, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	assert(image.save_jpg(jpg) == OK)
	assert(image.save_jpg(plain_jpg) == OK)
	var file := FileAccess.open(png, FileAccess.WRITE)
	assert(file != null)
	file.store_string("invalid PNG companion")
	file.close()
	var fs = ClassDB.instantiate("RetailFileSystem")
	fs.set_mods(PackedStringArray([mod_path]))
	assert(fs.mount_retail().ok)
	var builder = ClassDB.instantiate("W3DModelBuilder")
	var plain: Texture2D = builder.load_texture(fs, "ZZPackedPlain.tga")
	assert(plain != null and plain.get_width() == 2 and plain.get_height() == 2)
	assert(builder.get_report().errors.is_empty(), str(builder.get_report()))
	assert(builder.load_texture(fs, "ZZPackedProbe.tga") == null)
	assert(builder.get_report().errors.has("could not decode texture art\\compiledtextures\\zz\\zzpackedprobe.jpg"), str(builder.get_report()))
	DirAccess.remove_absolute(png)
	DirAccess.remove_absolute(jpg)
	DirAccess.remove_absolute(plain_jpg)
	for path in [folder, mod_path.path_join("art/compiledtextures"), mod_path.path_join("art"), mod_path]:
		DirAccess.remove_absolute(path)
	return true

func _run() -> void:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty():
		quit(77)
		return
	create_timer(90).timeout.connect(func(): push_error("Packed model texture test timed out"); quit(1))
	var fs = ClassDB.instantiate("RetailFileSystem")
	assert(fs.mount_retail().ok)
	var stem := "art/compiledtextures/gu/gushadowfaxh"
	var colour := Image.new()
	var mask := Image.new()
	assert(colour.load_jpg_from_buffer(fs.read_file(stem + ".jpg")) == OK)
	assert(mask.load_png_from_buffer(fs.read_file(stem + ".png")) == OK)
	colour.convert(Image.FORMAT_RGBA8)
	mask.convert(Image.FORMAT_RGBA8)
	assert(colour.get_size() == mask.get_size())
	var builder = ClassDB.instantiate("W3DModelBuilder")
	assert(_check_texture(builder.load_texture(fs, "GUShadowFaxH.tga"), colour, mask))
	assert(builder.get_report().errors.is_empty(), str(builder.get_report()))
	assert(str(builder.get_report().texture.packed_texture_stop).begins_with("[S-1482]"))
	var model_node = builder.build_model(fs, "GUGdfHrs_SKN")
	assert(model_node != null)
	assert(builder.get_report().errors.is_empty(), str(builder.get_report()))
	model_node.free()
	var renderer = ClassDB.instantiate("W3DInstancer")
	root.add_child(renderer)
	assert(renderer.setup(fs).ok)
	# The second model variant shares the texture cache and must retain S-1482.
	for name in ["GUGdfHrs_SKN", "GUGdfHrs_SKNL"]:
		var model: int = renderer.add_model(name)
		assert(model >= 0) # tolerance: model handles are nonnegative.
		var report: Dictionary = renderer.get_model_report(model)
		assert(report.errors.is_empty(), str(report))
		var packed_note := false
		for note in report.notes:
			packed_note = packed_note or (str(note).contains("[S-1482] model texture") and str(note).contains("gushadowfaxh.jpg"))
		assert(packed_note, str(report))
		assert(renderer.add_instance(model, Transform3D.IDENTITY) >= 0) # tolerance: instance handles are nonnegative.
	for i in 3:
		await process_frame
	var horse_textures := 0
	for child in renderer.get_children():
		if not child is MultiMeshInstance3D:
			continue
		var mesh: Mesh = child.multimesh.mesh
		for surface in mesh.get_surface_count():
			var material: ShaderMaterial = mesh.surface_get_material(surface)
			var texture: Texture2D = material.get_shader_parameter("w3d_tex0")
			if texture != null and texture.get_width() == colour.get_width() and texture.get_height() == colour.get_height():
				assert(_check_texture(texture, colour, mask))
				horse_textures += 1
	assert(horse_textures == 2)
	assert(_check_corrupt_mask())
	print("PACKED MODEL TEXTURE PASS")
	quit()
