## Optional visual mod. --natural-ground enables it; F8 compares against the original ground.
## The setting is read by MapTerrainBuilder, never by simulation or archive mounting.
extends Node

var enabled := false
var grass_enabled := false

func _enter_tree() -> void:
	enabled = bool(ProjectSettings.get_setting("openbfme/rendering/natural_ground", false))
	grass_enabled = bool(ProjectSettings.get_setting("openbfme/rendering/ground_cover", false))
	for arg in OS.get_cmdline_user_args():
		if arg == "--natural-ground" or arg == "--natural-ground=on":
			enabled = true
		elif arg == "--natural-ground=off":
			enabled = false
		elif arg == "--ground-cover" or arg == "--ground-cover=on" or arg == "--grass":
			grass_enabled = true
		elif arg == "--ground-cover=off":
			grass_enabled = false
	ProjectSettings.set_setting("openbfme/rendering/natural_ground", enabled)
	ProjectSettings.set_setting("openbfme/rendering/ground_cover", grass_enabled)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		grass_enabled = not grass_enabled
		var found := false
		for node in get_tree().root.find_children("GroundCover", "Node3D", true, false):
			if node.has_meta("ground_cover"):
				node.enabled = grass_enabled
				found = true
		print("Grass blades: ", ("on" if grass_enabled else "off") if found else "start with --ground-cover to load sprites")
		get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		enabled = not enabled
		ProjectSettings.set_setting("openbfme/rendering/natural_ground", enabled)
		var seen := {}
		for node in get_tree().root.find_children("*", "MeshInstance3D", true, false):
			if node.mesh == null:
				continue
			for surface in node.mesh.get_surface_count():
				var material = node.mesh.surface_get_material(surface)
				if material is ShaderMaterial and material.has_meta("natural_ground") and not seen.has(material):
					seen[material] = true
					material.set_shader_parameter("natural_ground_enabled", enabled)
		print("Natural ground: ", "on" if enabled else "off")
		get_viewport().set_input_as_handled()
