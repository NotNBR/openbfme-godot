## Lane LENS-1: the pro camera (scripts/pro_camera.gd, pro_lens.gd, pro_lens_effect.gd; NOT RETAIL,
## an OpenBFME addition). No game files.
##
##   godot --path godot --script res://tests/pro_camera_test.gd      (add --headless to run phase 1 only)
##
## Phase 1 (anywhere): the lens maths against hand-worked values, the pose (look_at, turns, roll) and what apply() sets
## on a Camera3D, and attach() keeping the effect right after OpenBFME's gamma composite decode on a compositor that
## holds OpenBFME's own effects, however often it is called; log output making what follows it neutral (the map's colour
## grade off, the environment's tone map linear, glow and adjustments off) and putting it back. Phase 2 (needs a GPU and
## a window; reported as skipped when headless): grey stripes 20 units away (2 m) over the upper half of the picture and
## 2,000 away over the lower half, through an 85 mm lens: focused near at f/1.4, the near stripes keep their contrast
## and the far ones (a blur circle of about 48 pixels, capped at 38) lose most of it; +1 EV doubles the light, which is
## well over 1.15 times the picture's mean after the sRGB encode; with log_output each pixel is the ACEScct value of the
## same pixel's linear light without it (the stripes are grey, which AP1 keeps grey).
##
## Exit codes: 0 pass, 1 fail, 77 phase 1 passed and phase 2 skipped (no GPU or window), as OpenBFME's GPU tests do.
extends SceneTree

const Lens := preload("res://scripts/pro_lens.gd")
const ProCamera := preload("res://scripts/pro_camera.gd")
const ProCameraGlide := preload("res://scripts/pro_camera_glide.gd")
const LensEffect := preload("res://scripts/pro_lens_effect.gd")

var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	print("LENS %s: %s" % [what, "ok" if ok else "FAIL"])
	if not ok:
		_failed += 1


static func _near(a: float, b: float, within: float) -> bool:
	return absf(a - b) <= within


func _run() -> void:
	_lens_maths()
	_pose()
	_apply()
	_attach()
	var skipped := DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null
	if skipped:
		await _without_device()
		print("LENS phase 2: SKIP (no GPU or window: run without --headless)")
	else:
		await _render()
	print("LENS RESULT: %s (%d failed)" % ["PASS" if _failed == 0 else "FAIL", _failed])
	quit(1 if _failed > 0 else (77 if skipped else 0))


## Without a RenderingDevice the effect says why it draws nothing, and answers a distance request at once.
func _without_device() -> void:
	var effect := LensEffect.new()
	for i in 3:
		await process_frame
	_check(effect.problem.contains("RenderingDevice"), "without a RenderingDevice the effect says why it draws nothing")
	var asked := effect.ask_distance(Vector2i(10, 10))
	_check(effect.answered == asked and effect.distance_of(asked) < 0.0,
		"and answers a distance request at once, below 0")
	_check(is_nan(effect.distance_of(asked + 1)), "a request not made has no answer")


func _lens_maths() -> void:
	# the crop: 3:2 and wider are 36 mm wide, narrower 24 mm tall
	_check(Lens.sensor(16.0 / 9.0).is_equal_approx(Vector2(36.0, 20.25)), "a 16:9 picture is the sensor's full width")
	_check(Lens.sensor(1.0).is_equal_approx(Vector2(24.0, 24.0)), "a square picture is the sensor's full height")
	_check(Lens.image_size(16.0 / 9.0, 1.0).is_equal_approx(Vector2(24.0 * 16.0 / 9.0, 24.0)),
		"a square frame in a 16:9 window: the window shows more beside it")
	# 2 atan(18 / 39) = 49.6 degrees; the two ways round agree
	_check(_near(Lens.fov_from_focal(39.0), 49.55, 0.01), "39 mm frames about 50 degrees across 36 mm")
	_check(_near(Lens.focal_from_fov(Lens.fov_from_focal(85.0)), 85.0, 1e-4), "focal length and field of view invert")
	# thin lens at 85 mm f/1.4 focused 500 units (50 m): (85/1.4) * 85 / (50000 - 85) * |d - s| / d mm, 1920 px on 36 mm
	var far := Lens.blur_pixels(5000.0, 500.0, 85.0, 1.4, 36.0, 1920.0)
	var by_hand := (85.0 / 1.4) * 85.0 / (50000.0 - 85.0) * (500000.0 - 50000.0) / 500000.0 * 1920.0 / 36.0
	_check(_near(far, by_hand, 1e-3), "the blur circle is the thin lens's")
	_check(Lens.blur_pixels(500.0, 500.0, 85.0, 1.4, 36.0, 1920.0) < 1e-3, "what is in focus does not blur")
	_check(Lens.blur_pixels(5000.0, 500.0, 85.0, 8.0, 36.0, 1920.0) < far / 5.0, "a smaller aperture blurs less")
	_check(Lens.blur_pixels(5000.0, 500.0, 85.0, 0.0, 36.0, 1920.0) == 0.0, "no aperture: nothing blurs")
	var sharp := Lens.sharp_range(500.0, 50.0, 2.8, 1.5)
	_check(sharp.x < 500.0 and sharp.y > 500.0, "the sharp range holds the focus")
	var wide := Lens.sharp_range(500.0, 50.0, 1.4, 1.5)
	_check(wide.x > sharp.x and wide.y < sharp.y, "it closes in as the aperture opens")
	_check(is_inf(Lens.sharp_range(110.0, 50.0, 8.0, 1.5).y), "beyond the hyperfocal distance everything far is sharp")
	_check(Lens.frame_rect(Vector2i(1920, 1080), 1.0) == Rect2i(420, 0, 1080, 1080), "a square frame centred in 16:9")


func _pose() -> void:
	var c := ProCamera.new()
	c.look_at(Vector3(0, 10, 0), Vector3(0, 10, -100))
	_check(_near(c.heading, 0.0, 1e-4) and _near(c.pitch, 0.0, 1e-4), "heading 0 looks along -Z (map north)")
	_check(_near(c.focus, 100.0, 1e-4), "look_at focuses on its target")
	c.look_at(Vector3.ZERO, Vector3(100, 0, 0))
	_check(_near(c.heading, 90.0, 1e-4) and c.right().is_equal_approx(Vector3(0, 0, 1)),
		"heading 90 looks east, right is south")
	c.look_at(Vector3.ZERO, Vector3(0, 100, -100))
	_check(_near(c.pitch, 45.0, 1e-4) and c.forward().is_equal_approx(Vector3(0, 1, -1).normalized()),
		"pitch above the horizon")
	c.turn(30.0, 100.0)
	_check(_near(c.heading, 30.0, 1e-4) and _near(c.pitch, 89.9, 1e-4), "turns; the pitch stops short of straight up")
	_check(ProCamera.sage(Vector3(1, 2, 3)) == Vector3(1, 3, -2), "a map point (x east, y north, z up) in Godot axes")
	var e := ProCamera.new()
	e.place(Vector3.ZERO, Vector3.FORWARD)
	e.move_view(100.0, 0.0, 0.0)
	_check(e.eye.is_equal_approx(Vector3(0, 0, -100)), "move_view moves the eye at once (it eases nothing)")
	e.move_view(0.0, 10.0, 5.0)
	_check(e.eye.is_equal_approx(Vector3(10, 5, -100)), "to the view's right and up")
	e.pitch = 90.0
	_check(e.pitch == 90.0, "pitch set directly is not limited")
	_follow()
	_glide()


func _follow() -> void:
	_check(_near(ProCamera.sage_heading(0.0), 90.0, 1e-4) and _near(ProCamera.sage_heading(PI / 2.0), 0.0, 1e-4),
		"an OpenBFME orientation as a heading (0 faces east, a quarter turn north)")
	_check(ProCamera.turned(Vector3(0, 0, 1), 90.0).is_equal_approx(Vector3(-1, 0, 0))
		and ProCamera.turned(Vector3(1, 0, 0), 90.0).is_equal_approx(Vector3(0, 0, 1)),
		"an offset in the frame of something facing east: behind it is west, its right is south")
	var c := ProCamera.new()
	c.place(Vector3.ZERO, Vector3.FORWARD)
	_check(_near(c.depth_of(Vector3(50, 0, -100)), 100.0, 1e-4), "a point off centre lies along the view at its depth")
	_check(c.focus_on(Vector3(50, 0, -100)) and _near(c.focus, 100.0, 1e-4), "focus_on focuses at that depth")
	_check(not c.focus_on(Vector3(0, 0, 10)) and _near(c.focus, 100.0, 1e-4), "a point behind the eye leaves the focus")
	c.roll = 5.0
	c.aim(Vector3(100, 0, 0))
	_check(_near(c.heading, 90.0, 1e-4) and c.roll == 5.0 and _near(c.focus, 100.0, 1e-4),
		"aim turns from where the eye is, keeps the roll and focuses")
	c.follow(Vector3(100, 0, 0), Vector3(0, 0, 50), 90.0)
	_check(c.eye.is_equal_approx(Vector3(50, 0, 0)) and _near(c.heading, 90.0, 1e-4) and _near(c.focus, 50.0, 1e-4),
		"follow: 50 behind a unit facing east, looking at it and focused on it")


func _glide() -> void:
	var c := ProCamera.new()
	c.place(Vector3.ZERO, Vector3.FORWARD)
	var g := ProCameraGlide.new(c)
	g.move_view(100.0, 0.0, 0.0)
	g.update(0.1)
	_check(c.eye.z < 0.0 and c.eye.z > -100.0 and g.moving(), "the glide eases the eye towards its target")
	var halves := ProCamera.new()
	var h := ProCameraGlide.new(halves)
	h.move_view(100.0, 0.0, 0.0)
	h.update(0.05)
	h.update(0.05)
	_check(_near(halves.eye.z, c.eye.z, 1e-3), "two half steps reach where one whole step does")
	for i in 100:
		g.update(0.1)
	_check(c.eye.is_equal_approx(Vector3(0, 0, -100)) and not g.moving(), "it arrives and drops the target")
	c.focal = 50.0
	g.update(0.1)
	_check(c.focal == 50.0, "a property without a target is left alone")
	c.heading = 350.0
	g.set_target("heading", 10.0)
	g.update(0.1)
	_check(c.heading < 10.0, "the heading takes the short way round")
	g.rates = {"focus": 0.0}
	g.set_target("focus", 42.0)
	g.update(0.01)
	_check(c.focus == 42.0, "a rate of 0 jumps")
	c.aperture = 0.0
	g.set_target("aperture", 1.4)
	g.update(0.01)
	_check(c.aperture == 1.4, "the aperture jumps from 0 (no depth of field)")
	g.set_target("ev", 2.0)
	g.settle()
	_check(c.ev == 2.0 and not g.moving(), "settle() jumps to every target")
	var far := ProCamera.new()
	far.place(ProCamera.sage(Vector3(1660, 2890, 172)), Vector3.FORWARD)
	var goal := far.eye + Vector3.FORWARD * 100.0
	var fg := ProCameraGlide.new(far)
	fg.move_view(100.0, 0.0, 0.0)
	for i in 600:
		fg.update(1.0 / 60.0)
	_check(not fg.moving() and far.eye.is_equal_approx(goal), "at map coordinates too it arrives and drops the target")
	var still := ProCameraGlide.new(far)
	still.set_target("focus", 50.0)
	still.update(0.0)
	_check(still.moving(), "a step of no time moves nothing and keeps the target")
	g.rates = {}
	g.follow(Vector3(100, 0, 0), Vector3(0, 30, 40), 0.0)
	g.update(0.05)
	_check(g.moving() and not c.eye.is_equal_approx(Vector3(100, 30, 40)), "the glide's follow eases after the unit")
	for i in 100:
		g.update(0.1)
	var follow := ProCamera.new()
	follow.follow(Vector3(100, 0, 0), Vector3(0, 30, 40), 0.0)
	_check(c.eye.is_equal_approx(follow.eye) and _near(c.heading, follow.heading, 1e-3)
		and _near(c.pitch, follow.pitch, 1e-3) and _near(c.focus, follow.focus, 1e-3),
		"and arrives where the camera's follow puts it")
	_check(g.focus_on(Vector3(100, 0, 0) + c.right() * 20.0) and g.moving(), "the glide's focus_on sets a focus target")
	g.settle()
	_check(_near(c.focus, c.depth_of(Vector3(100, 0, 0) + c.right() * 20.0), 1e-3), "at the point's depth along the view")


func _apply() -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	root.size = Vector2i(1600, 900)
	var c := ProCamera.new()
	c.look_at(Vector3(5, 20, 30), Vector3(5, 20, -70))
	c.focal = 50.0
	c.roll = 90.0
	c.apply(camera, false)
	_check(camera.keep_aspect == Camera3D.KEEP_WIDTH and _near(camera.fov, Lens.fov_from_focal(50.0), 1e-4),
		"the field of view is horizontal, from the focal length")
	_check(camera.global_position.is_equal_approx(Vector3(5, 20, 30)), "the camera stands at the eye")
	_check((-camera.global_transform.basis.z).is_equal_approx(Vector3.FORWARD), "and looks along the view")
	# roll 90: clockwise as seen from behind, so the camera's up turns to the view's right (+X here)
	_check(camera.global_transform.basis.y.is_equal_approx(Vector3.RIGHT), "roll turns it clockwise about the view")
	# a steep pitch: the picture keeps turning smoothly, with no flip near straight up or down
	c.roll = 0.0
	var ups := []
	for pitch in [86.0, 87.0, 88.0, 89.0, 89.9, -86.0, -87.0, -88.0, -89.0]:
		c.pitch = pitch
		c.apply(camera, false)
		_check((-camera.global_transform.basis.z).is_equal_approx(c.forward()),
			"at pitch %.1f it looks along the view" % pitch)
		ups.append(camera.global_transform.basis.y)
	var smooth := true
	for i in [0, 1, 2, 3, 5, 6, 7]:
		smooth = smooth and ups[i].dot(ups[i + 1]) > 0.999
	_check(smooth, "its up turns by about a degree per degree of pitch, without a flip near the vertical")
	c.pitch = 0.0
	c.frame = 1.0
	c.roll = 0.0
	c.apply(camera, false)
	_check(_near(camera.fov, Lens.fov_from_focal(50.0, 24.0 * 1600.0 / 900.0), 1e-4),
		"a square frame keeps its crop; the window shows more beside it")
	_check(camera.compositor == null, "without the effect the compositor stays untouched")
	camera.queue_free()


func _attach() -> void:
	if not ClassDB.class_exists("GammaCompositeEffect"):
		_check(false, "OpenBFME's library loads (GammaCompositeEffect)")
		return
	var camera := Camera3D.new()
	root.add_child(camera)
	var encode: CompositorEffect = ClassDB.instantiate("GammaCompositeEffect")
	var decode: CompositorEffect = ClassDB.instantiate("GammaCompositeEffect")
	var grade := CompositorEffect.new()                    # stands for the map's colour grade, which keeps itself last
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [encode, decode, grade]
	var effect := LensEffect.new()
	for i in 3:
		LensEffect.attach(camera, effect)
	_check(camera.compositor.compositor_effects == [encode, decode, effect, grade],
		"right after the decode, before the grade")
	# OpenBFME puts its pair on a new current camera after the effect: attach() moves it behind them again
	camera.compositor.compositor_effects = [effect, encode, decode, grade]
	LensEffect.attach(camera, effect)
	_check(camera.compositor.compositor_effects == [encode, decode, effect, grade],
		"moved behind a pair installed after it")
	var bare := Camera3D.new()
	root.add_child(bare)
	LensEffect.attach(bare, effect)
	_check(bare.compositor != null and bare.compositor.compositor_effects == [effect], "a plain camera gets it alone")
	LensEffect.detach(camera, effect)
	_check(camera.compositor.compositor_effects == [encode, decode, grade], "detach takes it off")
	# log output: the map's colour grade off while it is on (it would bake a look in), on again after
	var lut: CompositorEffect = ClassDB.instantiate("LookupTablePostEffect")
	camera.compositor.compositor_effects = [encode, decode, lut]
	effect.log_output = true
	LensEffect.attach(camera, effect)
	_check(not lut.enabled, "log output switches the map's colour grade off")
	effect.log_output = false
	LensEffect.attach(camera, effect)
	_check(lut.enabled, "and on again without it")
	effect.log_output = true
	LensEffect.attach(camera, effect)
	LensEffect.detach(camera, effect)
	_check(lut.enabled and effect.log_output, "detach switches it on again and keeps the setting")
	# log output under OpenBFME's "enhanced" look: AgX and glow made neutral, and put back
	var look := Environment.new()
	look.tonemap_mode = Environment.TONE_MAPPER_AGX
	look.glow_enabled = true
	look.adjustment_enabled = true
	camera.environment = look
	LensEffect.attach(camera, effect)
	_check(look.tonemap_mode == Environment.TONE_MAPPER_LINEAR and not look.glow_enabled and not look.adjustment_enabled
		and look.tonemap_exposure == 1.0, "log output makes the environment neutral: a linear tone map, no glow")
	effect.log_output = false
	LensEffect.attach(camera, effect)
	_check(look.tonemap_mode == Environment.TONE_MAPPER_AGX and look.glow_enabled and look.adjustment_enabled,
		"and puts the look back without it")
	effect.log_output = true
	LensEffect.attach(camera, effect)
	camera.compositor.compositor_effects = []     # dropped by every holder without detach(): freed
	bare.compositor.compositor_effects = []
	effect = null
	_check(look.tonemap_mode == Environment.TONE_MAPPER_AGX and lut.enabled, "freeing the effect puts the look back too")
	camera.environment = null
	camera.queue_free()
	bare.queue_free()


## Stripes along x: `period` pixels each, in `colours`.
static func _stripes(period: int, a: Color, b: Color) -> ImageTexture:
	var image := Image.create(256, 4, false, Image.FORMAT_RGBA8)
	for x in 256:
		for y in 4:
			image.set_pixel(x, y, a if (x / period) % 2 == 0 else b)
	return ImageTexture.create_from_image(image)


static func _quad(size: Vector2, texture: Texture2D, at: Vector3) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	return node


## The spread of the luminance over a band of rows: how much contrast survives.
static func _contrast(image: Image, rows: Vector2i, columns: Vector2i) -> float:
	var values := PackedFloat32Array()
	for y in range(rows.x, rows.y):
		for x in range(columns.x, columns.y):
			values.append(image.get_pixel(x, y).get_luminance())
	var mean := 0.0
	for v in values:
		mean += v
	mean /= values.size()
	var spread := 0.0
	for v in values:
		spread += (v - mean) * (v - mean)
	return sqrt(spread / values.size())


static func _mean(image: Image) -> float:
	var total := 0.0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			total += image.get_pixel(x, y).get_luminance()
	return total / (ceilf(image.get_height() / 4.0) * ceilf(image.get_width() / 4.0))


## sRGB-encoded v back to linear light.
static func _srgb_decode(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)


## The ACEScct curve (Academy S-2016-001).
static func _acescct(x: float) -> float:
	return 10.5402377416545 * x + 0.0729055341958355 if x <= 0.0078125 else (log(x) / log(2.0) + 9.72) / 17.52


func _picture(camera: Camera3D, c) -> Image:
	c.apply(camera)
	for i in 6:
		await process_frame
	return root.get_texture().get_image()


func _render() -> void:
	root.size = Vector2i(640, 360)
	var world := Node3D.new()
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.2, 0.2, 0.2)
	world.add_child(environment)
	# the near stripes fill the upper half of the picture 20 units away, the far ones the lower half 2,000 away, each the
	# view's width at its distance
	var half := tan(deg_to_rad(Lens.fov_from_focal(85.0)) / 2.0)
	var dark := Color(0.2, 0.2, 0.2)
	var light := Color(0.45, 0.45, 0.45)
	for at in [20.0, 2000.0]:
		var width: float = 2.0 * at * half
		var up: float = 1.0 if at < 100.0 else -1.0
		world.add_child(_quad(Vector2(width, width * 9.0 / 32.0), _stripes(8, dark, light),
			Vector3(0, up * width * 9.0 / 64.0, -at)))
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.current = true
	var c := ProCamera.new()
	c.place(Vector3.ZERO, Vector3.FORWARD, 20.0)
	c.focal = 85.0
	c.near = 1.0
	var top := Vector2i(30, 150)
	var bottom := Vector2i(210, 330)
	var columns := Vector2i(160, 480)
	var sharp: Image = await _picture(camera, c)
	c.aperture = 1.4
	var blurred: Image = await _picture(camera, c)
	var near_kept := _contrast(blurred, top, columns) / maxf(_contrast(sharp, top, columns), 1e-6)
	var far_kept := _contrast(blurred, bottom, columns) / maxf(_contrast(sharp, bottom, columns), 1e-6)
	print("LENS contrast kept at f/1.4 focused near: near %.2f, far %.2f" % [near_kept, far_kept])
	# tolerance: the effect samples the frame on a turning disc; near stripes in focus keep at least 80 % of their spread
	_check(near_kept > 0.8, "focused near, the near stripes stay sharp")
	# tolerance: 8-pixel stripes under a blur circle of about 48 pixels (capped at 38) lose most of their contrast
	_check(far_kept < 0.5, "and the far ones blur")
	c.aperture = 0.0
	c.ev = 1.0
	var bright: Image = await _picture(camera, c)
	# tolerance: 2x linear light is well over 1.15x after the sRGB encode, short of what clips at white
	_check(_mean(bright) > _mean(sharp) * 1.15, "+1 EV brightens the picture")
	c.ev = 0.0
	c.log_output = true
	var logged: Image = await _picture(camera, c)
	var worst := 0.0
	# below the top rows, where OpenBFME's build watermark is (2D, untouched by the effect)
	for y in range(60, logged.get_height(), 7):
		for x in range(0, logged.get_width(), 7):
			var expected := _acescct(_srgb_decode(sharp.get_pixel(x, y).r))
			worst = maxf(worst, absf(logged.get_pixel(x, y).r - expected))
	print("LENS log output: worst difference from ACEScct %.4f" % worst)
	# tolerance: two 8-bit steps, the output's rounding and the frame's 16-bit float buffer
	_check(worst <= 2.0 / 255.0, "log output is the ACEScct encode of the linear light")
	# the distance probe: the near stripes, the far ones, and a pixel outside the picture, all asked before the next
	# frame, so each answer must come from its own request's pixel
	c.log_output = false
	var asked := {}
	for pixel in [Vector2i(320, 90), Vector2i(320, 270), Vector2i(-4, 10)]:
		asked[pixel] = c.effect.ask_distance(pixel)
	for i in 8:
		c.apply(camera)
		await process_frame
		if c.effect.answered >= asked[Vector2i(-4, 10)]:
			break
	var probes := {}
	for pixel in asked:
		probes[pixel] = c.effect.distance_of(asked[pixel])
	print("LENS distance probe: near %.2f, far %.1f, outside %.1f"
		% [probes[Vector2i(320, 90)], probes[Vector2i(320, 270)], probes[Vector2i(-4, 10)]])
	# tolerance: the depth buffer's precision at 20 and 2,000 units
	_check(_near(probes[Vector2i(320, 90)], 20.0, 0.1) and _near(probes[Vector2i(320, 270)], 2000.0, 20.0),
		"ask_distance reads the distance along the view at a pixel")
	_check(probes[Vector2i(-4, 10)] < 0.0, "a pixel outside the picture answers below 0")
	# the effect on its own, on a plain camera set by hand: no camera layer
	c.detach(camera)
	var lens := LensEffect.new()
	lens.focal = 85.0
	lens.aperture = 1.4
	lens.focus = 20.0
	lens.image_mm = Lens.image_size(640.0 / 360.0).x
	camera.fov = Lens.fov_from_focal(lens.focal, lens.image_mm)
	LensEffect.attach(camera, lens)
	for i in 6:
		await process_frame
	var alone: Image = root.get_texture().get_image()
	var alone_far := _contrast(alone, bottom, columns) / maxf(_contrast(sharp, bottom, columns), 1e-6)
	print("LENS the effect alone: far contrast kept %.2f" % alone_far)
	# tolerance: as for the camera layer's f/1.4 picture above
	_check(alone_far < 0.5, "the effect on its own blurs the far stripes too")
	LensEffect.detach(camera, lens)
	world.queue_free()
