## Lane LENS-1: easing for a pro camera (NOT RETAIL: an OpenBFME addition, client state the simulation never reads).
## docs/PRO_CAMERA.md describes it.
##
## An optional helper on top of the camera (pro_camera.gd), which holds exactly what it is given: this eases it towards
## targets instead, for controls that should glide. set_target(), move_view() and turn() give a property a target, and
## update(dt) closes each property on its target by 1 - e^(-rate dt) of what is left, so it settles in about 3 / rate
## seconds whatever the frame rate. `rate` holds for every property, `rates` overrides it per property ({"focus": 4.0});
## 0 jumps. The heading takes the short way round. The aperture eases between f-numbers but jumps to and from 0, which
## is no depth of field rather than a wide-open lens. A property without a target is left alone, so the camera can still
## be set directly; a target is dropped once reached, and drop() lets go of them all.
extends RefCounted

const ProCamera := preload("res://scripts/pro_camera.gd")
const PROPERTIES: Array[String] = ["eye", "heading", "pitch", "roll", "focal", "aperture", "focus", "ev"]
const SETTLED := 1e-4         # what is left when a property counts as there (world units, degrees, mm, stops)

var camera                    # the pro camera it eases (pro_camera.gd)
var rate := 12.0              # 1/s, for every property without its own in `rates`; 0: at once
var rates := {}               # property name: 1/s

var _targets := {}


func _init(eased) -> void:
	camera = eased


## Where `property` is going: its target, or the camera's value when it has none.
func target(property: String) -> Variant:
	return _targets.get(property, camera.get(property))


## `property` (one of PROPERTIES) eased towards `value` from now on.
func set_target(property: String, value: Variant) -> void:
	if property not in PROPERTIES:
		push_error("pro_camera_glide: %s is not one of %s" % [property, PROPERTIES])
		return
	_targets[property] = fposmod(value, 360.0) if property == "heading" else value


## The eye's target moved along the target view, to its right (level) and up, in world units.
func move_view(ahead: float, side: float, up: float) -> void:
	var heading: float = target("heading")
	set_target("eye", target("eye") + ProCamera.direction(heading, target("pitch")) * ahead
		+ ProCamera.level_right(heading) * side + Vector3.UP * up)


## The eye's target moved by `offset` world units.
func move(offset: Vector3) -> void:
	set_target("eye", target("eye") + offset)


## The targets of a follow (the camera's follow()): the eye `offset` from `target` in the frame of something facing
## `facing`, the view turned to `target` from there and, unless `keep_focus`, the focus on it. While the eye is on its
## way the view eases on its own, so for an aim locked on a moving subject, call the camera's aim() after update().
func follow(target: Vector3, offset: Vector3, facing := 0.0, keep_focus := false) -> void:
	var at := target + ProCamera.turned(offset, facing)
	var turn_to := ProCamera.angles(target - at)
	set_target("eye", at)
	set_target("heading", turn_to.x)
	set_target("pitch", turn_to.y)
	if not keep_focus:
		set_target("focus", at.distance_to(target))


## The focus's target on `point`, seen from the targets of the eye and the view (the camera's focus_on()); false, and no
## target set, when the point is not in front of them.
func focus_on(point: Vector3) -> bool:
	var depth: float = (point - target("eye")).dot(ProCamera.direction(target("heading"), target("pitch")))
	if depth <= 0.0:
		return false
	set_target("focus", depth)
	return true


## The view's target turned by degrees, right and up; the pitch stops where the camera's turn() stops it.
func turn(right_degrees: float, up_degrees: float) -> void:
	set_target("heading", target("heading") + right_degrees)
	set_target("pitch", clampf(target("pitch") + up_degrees, -89.9, 89.9))


## Every property with a target eased `dt` seconds towards it.
func update(dt: float) -> void:
	for property: String in _targets.keys():
		var goal: Variant = _targets[property]
		var now: Variant = camera.get(property)
		var r: float = rates.get(property, rate)
		var k := 1.0 if r <= 0.0 or (property == "aperture" and (goal == 0.0 or now == 0.0)) else 1.0 - exp(-r * dt)
		var left: Variant = wrapf(goal - now, -180.0, 180.0) if property == "heading" else goal - now
		var rest: Variant = left * (1.0 - k)
		var next: Variant = fposmod(now + left * k, 360.0) if property == "heading" else now + left * k
		# there once what is left is below SETTLED, or once a step no longer moves it: far from the origin a float's step is
		# coarser than SETTLED (a map's thousands of units), and the rest would never close
		if k >= 1.0 or (rest.length() if rest is Vector3 else absf(rest)) < SETTLED or (k > 0.0 and next == now):
			camera.set(property, goal)
			_targets.erase(property)
		else:
			camera.set(property, next)


## Whether any property is still on its way.
func moving() -> bool:
	return not _targets.is_empty()


## Every property at its target at once, the targets dropped.
func settle() -> void:
	for property: String in _targets.keys():
		camera.set(property, _targets[property])
	_targets.clear()


## The targets dropped: the camera stays where it is.
func drop() -> void:
	_targets.clear()
