## Lane LENS-1: a pro camera (NOT RETAIL: an OpenBFME addition, client state the simulation never reads).
## docs/PRO_CAMERA.md describes it.
##
## Where a camera is, where it looks and through which lens, put onto any Camera3D by apply(). It reads no input and
## owns no node, so whatever drives it decides how it moves: a script, keyframes, a replay or cutscene tool, a photo
## mode's controls. The pose is an eye and a turn: `heading` (degrees, 0 looks along -Z, OpenBFME's map north, 90 along
## +X, east), `pitch` (degrees above the horizon) and `roll` (degrees about the view, clockwise as seen from behind).
## The lens (pro_lens.gd): `focal` mm on a full-frame sensor, `aperture` (an f-number; 0 keeps everything sharp),
## `focus` (world units along the view) and `ev` (exposure in stops). `frame` is the aspect of the picture inside the
## window (0: the whole window): the focal length frames that crop of the sensor and the window shows more around it.
## `log_output` (off by default) writes the picture as ACEScct, a log encoding to colour grade later
## (pro_lens_effect.gd).
##
## It holds exactly what it is given and eases nothing by itself: how a shot moves (a Tween, a spring, keyframes, a cut)
## is the caller's choice; pro_camera_glide.gd is an optional helper that eases it towards targets. It needs neither
## that nor anything else above it. Godot world coordinates throughout; sage() turns an OpenBFME map point (x east, y
## north, z up) into them.
extends RefCounted

const Lens := preload("res://scripts/pro_lens.gd")
const LensEffect := preload("res://scripts/pro_lens_effect.gd")

var eye := Vector3.ZERO
var heading := 0.0
var pitch := 0.0
var roll := 0.0
var focal := Lens.focal_from_fov(50.0)
var aperture := 0.0
var focus := 1500.0
var ev := 0.0
var frame := 0.0
var units_per_metre := Lens.UNITS_PER_METRE
var log_output := false       # ACEScct, to grade later
var max_blur := Lens.MAX_BLUR # the largest blur circle the effect draws, a share of the image's width (a speed limit)
var taps := 128               # the blur's samples per pixel (more: smoother, slower)
var near := 2.0
var far := 60000.0
var effect: CompositorEffect  # the depth of field and exposure (pro_lens_effect.gd), made by the first apply()


## An OpenBFME map point (SAGE axes: x east, y north, z up) in Godot world coordinates.
static func sage(point: Vector3) -> Vector3:
	return Vector3(point.x, point.z, -point.y)


## An OpenBFME orientation (radians, 0 facing east, counter-clockwise seen from above; GameWorld's "angle") as a
## heading.
static func sage_heading(angle: float) -> float:
	return fposmod(90.0 - rad_to_deg(angle), 360.0)


## The heading and pitch (degrees) that look along `ahead`.
static func angles(ahead: Vector3) -> Vector2:
	var f := ahead.normalized()
	return Vector2(fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0), rad_to_deg(asin(clampf(f.y, -1.0, 1.0))))


## `offset` given in the frame of something facing `facing` (a heading, degrees), in world axes. The frame is Godot's:
## -Z ahead, +X to its right, +Y up; so Vector3(10, 30, 80) is 80 behind, 30 above and 10 to the right of it.
static func turned(offset: Vector3, facing: float) -> Vector3:
	return offset.rotated(Vector3.UP, -deg_to_rad(facing))


## The direction a heading and a pitch look along (degrees, as `heading` and `pitch`).
static func direction(heading_degrees: float, pitch_degrees: float) -> Vector3:
	var h := deg_to_rad(heading_degrees)
	var p := deg_to_rad(pitch_degrees)
	return Vector3(sin(h) * cos(p), sin(p), -cos(h) * cos(p))


## The right of a heading (degrees), level with the ground.
static func level_right(heading_degrees: float) -> Vector3:
	var h := deg_to_rad(heading_degrees)
	return Vector3(cos(h), 0.0, sin(h))


func forward() -> Vector3:
	return direction(heading, pitch)


## The view's right, level with the ground (roll aside).
func right() -> Vector3:
	return level_right(heading)


## The eye at `at` looking along `ahead`, roll level; focused `at_focus` along the view when that is given (> 0).
func place(at: Vector3, ahead: Vector3, at_focus := 0.0) -> void:
	var turn_to := angles(ahead)
	eye = at
	heading = turn_to.x
	pitch = turn_to.y
	roll = 0.0
	if at_focus > 0.0:
		focus = at_focus


## The eye at `at` looking at `target`, focused on it unless `keep_focus`.
func look_at(at: Vector3, target: Vector3, keep_focus := false) -> void:
	place(at, target - at, 0.0 if keep_focus else at.distance_to(target))


## The view turned to `target` from where the eye is, the roll kept; focused on it unless `keep_focus`.
func aim(target: Vector3, keep_focus := false) -> void:
	var turn_to := angles(target - eye)
	heading = turn_to.x
	pitch = turn_to.y
	if not keep_focus:
		focus = eye.distance_to(target)


## The eye `offset` from `target` in the frame of something facing `facing` (a heading; turned()), looking at it and
## focused on it unless `keep_focus`. With facing 0 the offset is in world axes.
func follow(target: Vector3, offset: Vector3, facing := 0.0, keep_focus := false) -> void:
	eye = target + turned(offset, facing)
	aim(target, keep_focus)


## How far `point` lies along the view, in world units: the focus that puts it in focus wherever it is in the picture
## (focus is measured along the view, not straight to the point); 0 or less when it is beside or behind the eye.
func depth_of(point: Vector3) -> float:
	return (point - eye).dot(forward())


## Focus on `point` wherever it is in the picture; false, and the focus unchanged, when it is not in front of the eye.
func focus_on(point: Vector3) -> bool:
	var depth := depth_of(point)
	if depth <= 0.0:
		return false
	focus = depth
	return true


## Turn by degrees: right and up. The pitch stops 0.1 degrees short of straight up or down, where a heading would mean
## nothing; `pitch` set directly is not limited.
func turn(right_degrees: float, up_degrees: float) -> void:
	heading = fposmod(heading + right_degrees, 360.0)
	pitch = clampf(pitch + up_degrees, -89.9, 89.9)


## The eye moved by `offset` world units.
func move(offset: Vector3) -> void:
	eye += offset


## The eye moved along the view, to its right (level) and up, in world units.
func move_view(ahead: float, side: float, up: float) -> void:
	eye += forward() * ahead + right() * side + Vector3.UP * up


## The aspect the lens frames in a window of `aspect`.
func frame_aspect(aspect: float) -> float:
	return frame if frame > 0.0 else aspect


## The window's width in mm on the sensor's scale: the frame's crop, and what the window shows beside it.
func image_mm(aspect: float) -> float:
	return Lens.image_size(aspect, frame).x


## The camera's horizontal field of view (degrees) across a window of `aspect`.
func window_fov(aspect: float) -> float:
	return Lens.fov_from_focal(focal, image_mm(aspect))


## (near, far) world units that stay sharp in a frame of `aspect` (pro_lens.gd sharp_range).
func sharp_range(aspect: float) -> Vector2:
	return Lens.sharp_range(focus, focal, aperture, frame_aspect(aspect), units_per_metre)


## Whether the lens changes the picture (an aperture, an exposure, log output), so the effect has work to do.
func changes_picture() -> bool:
	return aperture > 0.0 or absf(ev) > 1e-6 or log_output


## Put `camera` where this camera is, with its field of view across the camera's viewport (KEEP_WIDTH: the field of view
## is horizontal), near and far; with `with_effect`, the depth of field and exposure on its compositor too
## (pro_lens_effect.gd, kept after OpenBFME's own passes). Call it every frame the camera or the lens changes.
func apply(camera: Camera3D, with_effect := true) -> void:
	var size := camera.get_viewport().get_visible_rect().size
	if size.x < 1.0 or size.y < 1.0:
		return                # a viewport with no area yet (a window opening): nothing to frame
	var aspect := size.x / size.y
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = window_fov(aspect)
	camera.near = near
	camera.far = far
	# from the angles (yaw, then pitch, then roll about the view), which turn smoothly through every pitch, straight up and
	# down included; a basis looking along forward() would need an up, which flips near the vertical
	var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(-heading), deg_to_rad(-roll)))
	camera.global_transform = Transform3D(basis, eye)
	if not with_effect:
		return
	if effect == null:
		effect = LensEffect.new()
	effect.focal = focal
	effect.aperture = aperture
	effect.focus = focus
	effect.ev = ev
	effect.image_mm = image_mm(aspect)
	effect.units_per_metre = units_per_metre
	effect.log_output = log_output
	effect.max_blur = max_blur
	effect.taps = taps
	LensEffect.attach(camera, effect)


## The effect off `camera`'s compositor (the camera as OpenBFME draws it otherwise), the colour grade on again.
func detach(camera: Camera3D) -> void:
	if effect != null:
		LensEffect.detach(camera, effect)
