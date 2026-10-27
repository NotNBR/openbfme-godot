## Godot shadow maps as a presentation substitute for SAGE volume shadows (S-3304).
## The scene's existing main object light supplies coverage; the shaders retain their retail lighting.
extends RefCounted

static func configure(sun: DirectionalLight3D, lighting: Dictionary, lod: int = 3) -> void:
	var enabled := lod >= 2
	if lighting.has("direction"):
		var direction: Vector3 = lighting.direction
		enabled = enabled and direction.is_finite() and direction.length_squared() > 0.00000001
	sun.shadow_enabled = enabled
	if enabled:
		RenderingServer.directional_shadow_atlas_set_size(8192 if lod >= 4 else (4096 if lod == 3 else 2048), false)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	# SAGE world units: the tactical camera is hundreds of units above the ground.
	sun.directional_shadow_max_distance = 4000.0
	sun.directional_shadow_pancake_size = 0.0
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 0.5
	var packed := int(lighting.get("shadow_color", 0x7fa0a0a0))
	RenderingServer.global_shader_parameter_set("w3d_shadow", Vector4(
		float((packed >> 16) & 255) / 255.0,
		float((packed >> 8) & 255) / 255.0,
		float(packed & 255) / 255.0, 1.0 if enabled else 0.0))

static func disable() -> void:
	RenderingServer.global_shader_parameter_set("w3d_shadow", Vector4(1.0, 1.0, 1.0, 0.0))
