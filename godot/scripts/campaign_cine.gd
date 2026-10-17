## Lane SCRIPT-1: the presentation of the map script engine's client requests in a viewer (map_viewer.gd --campaign). The logic's ScriptEngine records
## the camera, letterbox, caption and fade actions (ScriptClientRequest); GameWorld.update_script_view applies them on the render clock
## (GameClient/ScriptCameraDirector: ZH W3DView moveCameraTo / resetCamera / rotateCamera as donor, stop S-1182) and this node places the camera and
## draws the letterbox bars, the military caption (the label's game text) and the fade. Every request is printed (SCRIPTREQ lines) for the reports.
extends Node

var world: Node3D
var camera: Camera3D
var target := Vector3.ZERO   # SAGE x, y, z the camera looks at
var angle := 0.0             # SAGE camera angle (radians)
var distance := 520.0        # camera distance from the look-at point (inference: the RotWK default framing is CAM-1's; S-1182)
var pitch := deg_to_rad(-40.0)
var _top: ColorRect
var _bottom: ColorRect
var _caption: Label
var _fade: ColorRect
var _status: Label
var _note: Label         # lane SCRIPT-2: DISPLAY_NOTIFICATION_BOX's text
var _objectives: Label   # lane SCRIPT-2: SHOW_MISSION_OBJECTIVE / MARK_MISSION_OBJECTIVE_COMPLETED
var _audio: Node         # lane SCRIPT-2: GameAudio (the listener follows the camera)
var drive := ""          # lane SCRIPT-2: "angmar" plays the first objective's part of the player (map_viewer --cine-drive); lane SCRIPT-3: "rhudaur" the whole mission
var _drive_frame := 0     # lane SCRIPT-3: the frame the current drive step started
var _look := ""           # lane SCRIPT-3: the unit / team the camera follows between the script's own moves
var _drive_step := 0
var _base_distance := 520.0
var _base_pitch := deg_to_rad(-40.0)
var hud_mode := false      # lane CAMP-1: in the game (scripts/campaign_flow.gd) the HUD's camera rules outside the cinematics (letterbox, a script move, input off)
var movie_hook := Callable() # lane CAMP-1H: PLAY_MOVIE_IN_GAME's title goes there (scripts/campaign_flow.gd plays it with scripts/movie_player.gd)
var dev_overlay := true      # lane CAMP-2: the developer text (logic frame, camera / input state, the objective list): the viewers' only; the game sets it from --dev-overlay
var input_hook := Callable() # lane OWNERFIX-1: the scripts' DISABLE_INPUT / ENABLE_INPUT (bool enable) (game.gd _script_input)
var _ui: CanvasLayer = null # lane SAVE-UI1: the presentation's layer (set_covered)
var control_bar_hook := Callable() # lane CAMP-2: HideControlBar / ShowControlBar (bool hidden) for CAMERA_LETTERBOX_BEGIN / END and HIDE_UI / SHOW_UI (game.gd)
# mapworkshop (openbfme-cinematics.patch): RotWK's cinematic maps' own requests (maps\cin *): OPTIONS_SET_DRAWICON_UI_MODE (game.gd _set_icons_drawn),
# SET_CAMERA_CLIP_DEPTH_MULTIPLIER and MOVE_CAMERA_BY_ANIMATION (_play_animation)
var icons_hook := Callable()
var _clip := 1.0           # the far plane's multiplier
var _base_far := 0.0       # the camera's far plane without it (outside HUD mode; in HUD mode the HUD sets retail's every frame before this node)
var _anim: Dictionary = {} # the camera animation playing (GameWorld.get_camera_animation), held at its last key once done
var _anim_ms := 0.0


## lane SAVE-UI1: a menu over the game (the quit menu and the screens it opens) covers the script presentation: retail draws the in-game UI before the
## window manager's movies (ZH W3DDisplay::draw: TheInGameUI, then the windows), so the letterbox, captions and notifications are under the menu
func set_covered(covered: bool) -> void:
	if _ui != null:
		_ui.visible = not covered


func setup(w: Node3D, cam: Camera3D, start: Vector3, ui_parent: Node, audio: Node = null) -> void:
	process_priority = -50 # lane RENDERWAIT-1 r2: before GameWorld's process, inside the render frame's client window
	_audio = audio
	world = w
	camera = cam
	target = start
	var ui := CanvasLayer.new()
	ui.layer = 5
	_ui = ui
	_top = ColorRect.new()
	_top.color = Color.BLACK
	_bottom = ColorRect.new()
	_bottom.color = Color.BLACK
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption = Label.new()
	_caption.set_meta("game_text", true) # lane CAMP-2: SHOW_MILITARY_CAPTION's game text (game.gd _dev_text_on_screen)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.add_theme_font_size_override("font_size", 22)
	_caption.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	_caption.add_theme_color_override("font_outline_color", Color.BLACK)
	_caption.add_theme_constant_override("outline_size", 6)
	_status = Label.new()
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 4)
	ui.add_child(_fade)
	ui.add_child(_top)
	ui.add_child(_bottom)
	ui.add_child(_caption)
	ui.add_child(_status)
	_note = Label.new()
	_note.set_meta("game_text", true) # lane CAMP-2: DISPLAY_NOTIFICATION_BOX's game text
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", 18)
	_note.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_note.add_theme_color_override("font_outline_color", Color.BLACK)
	_note.add_theme_constant_override("outline_size", 5)
	ui.add_child(_note)
	_objectives = Label.new()
	_objectives.add_theme_font_size_override("font_size", 15)
	_objectives.add_theme_color_override("font_outline_color", Color.BLACK)
	_objectives.add_theme_constant_override("outline_size", 4)
	ui.add_child(_objectives)
	ui_parent.add_child(ui)
	_base_far = camera.far
	if hud_mode:
		_sky() # mapworkshop (openbfme-cinematics.patch): a skirmish or LAN game has the sky and the haze throughout
	_place_camera()


func _process(delta: float) -> void:
	if world == null:
		return
	# lane RENDERWAIT-1 r2 (Sol r1 #2): the live reads of this function (the test drives, the terrain's height under the script's target, a drive's
	# follow) happen only in a render frame that holds the logic; the script requests, their camera and the followed object come from published data
	var held: bool = world.is_logic_held()
	if held:
		_drive()
	for r in world.take_script_requests():
		var ps: Array = []
		for p in r.params:
			ps.append(p.string if not String(p.string).is_empty() else (str(p.real) if p.type == 1 else str(p.int)))
		print("SCRIPTREQ frame %d %s(%s) [%s]" % [r.frame, r.action, ", ".join(ps), r.script])
		if r.action == "PLAY_MOVIE_IN_GAME" and movie_hook.is_valid() and r.params.size() > 0:
			movie_hook.call(String(r.params[0].string))
		# lane CAMP-2: ScriptActions::executeAction (RW 0x7CAFA5): cases 118 / 119 doLetterBoxMode (RW 0x7BC8B7: HideControlBar(true) or ShowControlBar(false),
		# then the display's letterbox), cases 347 / 348 HIDE_UI / SHOW_UI (HideControlBar(true) / ShowControlBar(false)); in the requests' order
		# lane OWNERFIX-1: DISABLE_INPUT / ENABLE_INPUT (RW 0x7BC586 / 0x7BC5E9): the HUD's input flag, the selection and the pointer (InGameHud::scriptInput)
		if input_hook.is_valid():
			if r.action == "DISABLE_INPUT":
				input_hook.call(false)
			elif r.action == "ENABLE_INPUT":
				input_hook.call(true)
		# mapworkshop (openbfme-cinematics.patch): a script move takes the camera from an animation; the cinematic maps' set-up requests
		if r.action == "MOVE_CAMERA_BY_ANIMATION" and r.params.size() > 0:
			_play_animation(String(r.params[0].string))
		elif r.action.begins_with("MOVE_CAMERA") or r.action == "RESET_CAMERA" or r.action == "SETUP_CAMERA" or r.action == "CAMERA_FOLLOW_NAMED":
			_anim = {}
		elif r.action == "OPTIONS_SET_DRAWICON_UI_MODE" and r.params.size() > 0 and icons_hook.is_valid():
			icons_hook.call(int(r.params[0].int) != 0)
		elif r.action == "SET_CAMERA_CLIP_DEPTH_MULTIPLIER" and r.params.size() > 0:
			_clip = maxf(float(r.params[0].real), 0.01)
		if control_bar_hook.is_valid():
			if r.action == "CAMERA_LETTERBOX_BEGIN" or r.action == "HIDE_UI":
				control_bar_hook.call(true)
			elif r.action == "CAMERA_LETTERBOX_END" or r.action == "SHOW_UI":
				control_bar_hook.call(false)
	var st: Dictionary = world.update_script_view(delta * 1000.0, {"x": target.x, "y": target.y, "z": target.z, "angle": angle})
	if st.has_target and (_look.is_empty() or st.moving): # a drive's follow (lane SCRIPT-3) holds the camera between the script's moves
		target = Vector3(st.x, st.y, world.get_ground_height(st.x, st.y) if held else target.z) # the height follows in the next held frame
	if st.has_angle:
		angle = st.angle
	if not st.moving and held:
		_look_at_now() # lane SCRIPT-3: a drive's follow between the script's own camera moves
	# ZOOM_CAMERA / PITCH_CAMERA: factors of the default framing (S-1182)
	distance = _base_distance * float(st.get("zoom", 1.0))
	pitch = _base_pitch * float(st.get("pitch", 1.0))
	if not _anim.is_empty():
		_anim_ms += delta * 1000.0
		_place_animation() # mapworkshop (openbfme-cinematics.patch): the animation has the camera
	elif not hud_mode or st.letterbox or st.moving or st.input_disabled:
		_place_camera()
	if _clip != 1.0:
		camera.far = (camera.far if hud_mode else _base_far) * _clip # mapworkshop (openbfme-cinematics.patch): SET_CAMERA_CLIP_DEPTH_MULTIPLIER
	if _audio != null:
		_audio.set_listener(Vector3(target.x, target.y, target.z), Vector3(sin(angle), cos(angle), 0.0))
	var size := get_viewport().get_visible_rect().size
	var bar := size.y * 0.12 if st.letterbox else 0.0
	_top.position = Vector2.ZERO
	_top.size = Vector2(size.x, bar)
	_bottom.position = Vector2(0, size.y - bar)
	_bottom.size = Vector2(size.x, bar)
	_top.visible = st.letterbox
	_bottom.visible = st.letterbox
	_fade.position = Vector2.ZERO
	_fade.size = size
	_fade.color = Color(0, 0, 0, st.fade)
	_caption.text = st.caption_text
	_caption.position = Vector2(size.x * 0.1, size.y - bar - 120.0)
	_caption.size = Vector2(size.x * 0.8, 100.0)
	_status.visible = dev_overlay # lane CAMP-2: developer text never shows in the real game (the owner saw "frame 90   input disabled")
	_objectives.visible = dev_overlay
	_status.text = "frame %d   %s%s" % [world.get_presented_frame(), "camera moving   " if st.moving else "", "input disabled" if st.input_disabled else ""] if dev_overlay else ""
	_status.position = Vector2(12, bar + 8.0)
	_note.text = st.get("notification_text", "")
	_note.position = Vector2(size.x * 0.15, bar + 40.0)
	_note.size = Vector2(size.x * 0.7, 60.0)
	var lines: PackedStringArray = []
	for o in st.get("objectives", []):
		lines.append(("[x] " if o.completed else "[ ] ") + "objective %d" % o.index)
	_objectives.text = "\n".join(lines) if dev_overlay else ""
	_objectives.position = Vector2(size.x - 220.0, bar + 40.0)


## mapworkshop (openbfme-cinematics.patch): MOVE_CAMERA_BY_ANIMATION plays the map's CameraAnimationList entry of that name: a "look" animation's
## camera keys and look-at keys, each through its keys by Catmull-Rom ('catm', or straight for 'line') at 30 frames a second (a RotWK capture: a
## still 7.5 s into a 14 s orbit matched that point, mapworkshop's docs/game/scripts.md); the camera keys' field of view (horizontal, the HUD's
## KEEP_WIDTH) and roll (radians about the line of sight, positive banking right: the picture turns anticlockwise) the same way. The camera holds the
## last pose until a script move or another animation. A "free" animation is not played: the convention of its rotation is not decoded (reported).
func _play_animation(name: String) -> void:
	var a: Dictionary = world.get_camera_animation(name)
	if not a.get("ok", false) or a["type"] != "look" or a["keys"].is_empty() or a["look_at"].is_empty():
		print("SCRIPTREQ camera animation '%s' not played: %s" % [name, "a free animation" if a.get("type", "") == "free" else "no look animation of that name"])
		return
	_anim = a
	_anim_ms = 0.0
	_sky()


## mapworkshop (openbfme-cinematics.patch): the world's background is black, and the skybox model RotWK's cinematic maps place (CINE_skybox_*)
## covers only part of a view: a camera high or far out looks past its rim into the black (the v2 battle film, 17 October 2026). A skirmish
## or LAN game, and a campaign mission while it plays a camera animation, gets a procedural sky behind the world and a light haze that fades
## the distance into that sky's horizon (INFERENCE: an approximation of RotWK's view). The ambient light stays the map's (a colour), and so do
## reflections (none).
func _sky() -> void:
	var env: Environment = camera.get_world_3d().environment if camera.get_world_3d() != null else null
	if env == null or env.background_mode == Environment.BG_SKY:
		return
	var horizon := Color(0.66, 0.65, 0.6)
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.3, 0.43, 0.6)
	mat.sky_horizon_color = horizon
	mat.ground_horizon_color = horizon
	mat.ground_bottom_color = Color(0.33, 0.3, 0.25)
	var sky := Sky.new()
	sky.sky_material = mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.fog_enabled = true
	env.fog_light_color = horizon
	env.fog_density = 0.0000075
	env.fog_sky_affect = 0.0


func _place_animation() -> void:
	var f := _anim_ms * 0.03
	var eye := _through(_anim["keys"], f)
	var at := _through(_anim["look_at"], f)
	var lens := _through(_anim["keys"], f, true)
	camera.position = Vector3(eye.x, eye.z, -eye.y)
	if not eye.is_equal_approx(at):
		camera.look_at(Vector3(at.x, at.z, -at.y))
	if lens.y != 0.0:
		camera.rotate_object_local(Vector3(0, 0, 1), -lens.y)
	camera.fov = clampf(rad_to_deg(lens.x), 1.0, 179.0)
	target = at


## the point of the keys (SAGE) at frame f; with `lens`, their field of view and roll (x, y) instead
func _through(keys: Array, f: float, lens := false) -> Vector3:
	var n := keys.size()
	if n == 1 or f <= float(keys[0].frame):
		return _key(keys[0], lens)
	if f >= float(keys[n - 1].frame):
		return _key(keys[n - 1], lens)
	var i := 0
	while i < n - 2 and f > float(keys[i + 1].frame):
		i += 1
	var p1 := _key(keys[i], lens)
	var p2 := _key(keys[i + 1], lens)
	var t := (f - float(keys[i].frame)) / maxf(float(keys[i + 1].frame - keys[i].frame), 1.0)
	if String(keys[i].interp) == "line":
		return p1.lerp(p2, t)
	var p0 := _key(keys[maxi(i - 1, 0)], lens)
	var p3 := _key(keys[mini(i + 2, n - 1)], lens)
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t)


func _key(key: Dictionary, lens: bool) -> Vector3:
	return Vector3(float(key.fov), float(key.roll), 0.0) if lens else key.pos


func _place_camera() -> void:
	var look := Vector3(target.x, target.z, -target.y)
	# the camera behind the look-at point along the SAGE angle (angle 0 looks north, +y SAGE = -z Godot)
	var back := Vector3(-sin(angle), 0.0, cos(angle))
	camera.position = look + back * distance * cos(pitch) + Vector3(0, distance * sin(-pitch), 0)
	camera.look_at(look)


## lane SCRIPT-2: the player's part of MAP ANG Angmar's first objective (the heroes reach Rogash, his attackers fall), by the GameWorld test hooks
func _drive() -> void:
	if drive.begins_with("kill:"):
		_drive_kill()
		return
	if drive == "rhudaur":
		_drive_rhudaur()
		return
	if drive != "angmar":
		return
	var f: int = world.get_frame()
	if _drive_step == 0 and f >= 200:
		_drive_step = 1
		for h in ["Witch King", "Morgomir"]:
			print("DRIVE place %s: %s" % [h, world.debug_script_place(h, "AT - Rogash Becomes Vulnerable")])
	elif _drive_step == 1 and f >= 204:
		_drive_step = 2
		for n in ["Rogash Attacker 1", "Rogash Attacker 2", "Surrender Monkeys"]:
			print("DRIVE kill %s: %s" % [n, world.debug_script_kill(n)])


## lane SCRIPT-3: the player's part of MAP ANG Rhudaur (the steps of test_script3_mission.cpp's playthrough), by the GameWorld test hooks: Hwaldar's
## barricade falls, the Witch King is seen at each village (the warriors hunt, TEAM_HUNT) and they are beaten, then the forts and King Argeleb fall;
## the map's scripts do the rest (the crew's waypoint path, the traitors, the objectives, the victory sequence). The camera looks at the action.
func _follow(what: String) -> void:
	_look = what


func _look_at_now() -> void:
	if _look.is_empty():
		return
	var d: Dictionary = world.debug_script_team(_look) if _look.contains("/") else world.debug_script_unit(_look)
	if d.get("ok", false):
		var goal := Vector3(d.x, d.y, d.z)
		target = target.lerp(goal, 0.08)


func _team_at(team: String) -> Dictionary:
	return world.debug_script_team(team)


func _drive_rhudaur() -> void:
	var f: int = world.get_frame()
	var villages := ["PlyrWildmen/SW Village Warriors", "PlyrWildmen/NW Village Warriors", "PlyrWildmen/NE Village Warriors"]
	match _drive_step:
		0:
			if f >= 172:
				print("DRIVE kill barricade: %s" % world.debug_script_kill("Hwaldar Barricade 1"))
				_follow("Hwaldar's Crew 1")
				_drive_step = 1
				_drive_frame = f
		1, 3, 5:
			# the Witch King is seen at a village: its warriors hunt
			if f >= _drive_frame + 30:
				var v: String = villages[(_drive_step - 1) / 2]
				var at := _team_at(v)
				if at.get("ok", false):
					print("DRIVE Witch King to %s: %s" % [v, world.debug_script_place_at("Witch King", float(at.x) + 120.0, float(at.y))])
				_follow(v)
				_drive_step += 1
				_drive_frame = f
		2, 4, 6:
			# the fight, then the village falls
			if f >= _drive_frame + 45:
				var v: String = villages[(_drive_step - 2) / 2]
				print("DRIVE beat %s: %s" % [v, world.debug_script_kill_team(v)])
				_drive_step += 1
				_drive_frame = f
		7:
			# the SE loyalists run away along their path (Hwaldar is free)
			var at := _team_at("PlyrWildmen/SE Village Warriors")
			if at.get("ok", false):
				print("DRIVE Witch King to SE: %s" % world.debug_script_place_at("Witch King", float(at.x), float(at.y)))
			_follow("PlyrWildmen/SE Village Warriors")
			_drive_step = 8
			_drive_frame = f
		8:
			if f >= _drive_frame + 110:
				_follow("North Fortress")
				_drive_step = 9
				_drive_frame = f
		9:
			if f >= _drive_frame + 20:
				for n in ["North Fortress", "South Fortress", "King Argeleb"]:
					print("DRIVE kill %s: %s" % [n, world.debug_script_kill(n)])
				_drive_step = 10
				_drive_frame = f
		10:
			if f >= _drive_frame + 25:
				_follow("Witch King")
				_drive_step = 11


## lane CAMP-1: --cine-drive=kill:<name>@<frame> (the montage of scripts/campaign_flow.gd's missions): the camera follows the named unit from 150 frames
## before, then the test hook kills it (the mission's decisive moment: a tower, a citadel, the Witch King); the map's scripts play the rest
func _drive_kill() -> void:
	var spec := drive.substr(5)
	var at := int(spec.get_slice("@", 1))
	var name := spec.get_slice("@", 0)
	var f: int = world.get_frame()
	if _drive_step == 0 and f >= at - 150:
		_follow(name)
		_drive_step = 1
	elif _drive_step == 1 and f >= at:
		print("DRIVE kill %s: %s" % [name, world.debug_script_kill(name)])
		_drive_step = 2
