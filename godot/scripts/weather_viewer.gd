## Weather viewer (lane WEATHER-1): a live game seen from the RTS camera while its weather plays: a snowy map's snow, Isengard's Freezing Rain (the
## snow manager's spell ramp) and Mordor's Darkness (the cloud effect's darkening of the terrain and the models). For the lane's screenshots; the spell
## is bought and cast through GameWorld's command API (purchase_science / cast_special_power), as a player's clicks would.
##
##   godot --path godot res://scenes/weather_viewer.tscn -- [options]
##
## Options (after `--`):
##   --scenario=<snow|rain|darkness>   (default snow: map mp withered heath; rain / darkness: map mp fall back 4p)
##   --map=<name>            another map
##   --seconds=<s>           game seconds before the shot (default: snow 3, rain 8, darkness 10)
##   --height=<h>            the camera's height above the look-at point (default 420)
##   --shots=<dir>           saves weather-<scenario>-before.png and weather-<scenario>.png there, then quits
extends Node3D

var _scenario := "snow"
var _map_name := ""
var _seconds := -1.0
var _height := 420.0
var _shots := ""
var _fs: RefCounted
var _world: Node3D
var _camera: Camera3D
var _label: Label
var _local := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="):
			_scenario = arg.substr(11)
		elif arg.begins_with("--map="):
			_map_name = arg.substr(6)
		elif arg.begins_with("--seconds="):
			_seconds = float(arg.substr(10))
		elif arg.begins_with("--height="):
			_height = float(arg.substr(9))
		elif arg.begins_with("--shots="):
			_shots = arg.substr(8)
	if _map_name == "":
		_map_name = "map mp withered heath" if _scenario == "snow" else "map mp fall back 4p"
	if _seconds < 0.0:
		_seconds = {"snow": 3.0, "rain": 8.0, "darkness": 10.0}.get(_scenario, 3.0)
	_fs = ClassDB.instantiate("RetailFileSystem")
	var mount: Dictionary = _fs.mount_retail()
	if not mount.ok:
		_fail("mount failed: %s" % [mount.errors])
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.near = 2.0
	_camera.far = 60000.0
	add_child(_camera)
	_world = ClassDB.instantiate("GameWorld")
	var setup: Dictionary = _world.setup(_fs)
	if not setup.ok:
		_fail("object world failed: %s" % [setup.errors])
		return
	var faction := "FactionIsengard" if _scenario == "rain" else "FactionMordor"
	var slots := [
		{"player": "Player_1", "faction": faction, "human": true, "team": 0, "start_index": 0},
		{"player": "Player_2", "faction": "FactionMen", "human": false, "team": 1, "start_index": 1},
	]
	var rep: Dictionary = _world.load_map(_map_name, {"slots": slots, "seed": 4711, "terrain": true})
	if not rep.ok:
		_fail("load_map failed: %s" % [rep.errors.slice(0, 5)])
		return
	add_child(_world)
	var idx := 0
	for pl in rep.players:
		if "Player_1" in str(pl):
			_local = idx
			break
		idx += 1
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(12, 8)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	_run()


func _fail(message: String) -> void:
	push_error(message)
	print("WEATHERVIEW FAIL: ", message)
	get_tree().quit(1)


## the camera over the local player's base (its first structure), RetailCamera's pitch 37.5 degrees
func _look_at_base() -> Vector2:
	var at := Vector2.ZERO
	var n := 0
	for o in _world.get_player_objects("Player_1"):
		var d: Dictionary = o if o is Dictionary else _world.get_object(int(o))
		if d.get("ok", true) and d.has("x"):
			at += Vector2(d.x, d.y)
			n += 1
	if n > 0:
		at /= n
	var g := Vector3(at.x, 0.0, -at.y)
	var pitch := deg_to_rad(37.5)
	_camera.position = g + Vector3(0.0, _height, _height / tan(pitch))
	_camera.look_at(g, Vector3.UP)
	return at


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		var dt := 1.0 / 30.0
		_world.advance(dt)
		t += dt
		var wr: Dictionary = _world.get_weather_report()
		_label.text = "%s on %s  t %.1f s  snow phase %d spacing %.1f particles %d  cloud phase %d counter %d  sound weather %d" % [
			_scenario, _map_name, t, wr.snow.phase, wr.snow.spacing, wr.snow.particles, wr.cloud.phase, wr.cloud.counter, wr.sound.weather]
		await get_tree().process_frame


func _shot(name: String) -> void:
	if _shots == "":
		return
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var path := _shots.path_join("weather-%s.png" % name)
	img.save_png(path)
	print("WEATHERVIEW shot ", path)


func _run() -> void:
	var at := _look_at_base()
	await _wait(1.0)
	await _shot(_scenario + "-before")
	if _scenario == "rain" or _scenario == "darkness":
		_world.debug_add_science_points(_local, 500)
		var buy: Array = ["SCIENCE_WildMenAllies", "SCIENCE_IsengardTaint", "SCIENCE_FreezingRain"] if _scenario == "rain" else ["SCIENCE_Barricade", "SCIENCE_UntamedAllegiance", "SCIENCE_Darkness"]
		for s in buy:
			_world.purchase_science(_local, s)
			await _wait(0.4)
		var power := "SpellBookFreezingRain" if _scenario == "rain" else "SpellBookDarkness"
		var ok: bool = _world.cast_special_power(_local, power, at.x, at.y)
		print("WEATHERVIEW cast %s at %s: %s" % [power, at, ok])
	await _wait(_seconds)
	var wr: Dictionary = _world.get_weather_report()
	print("WEATHERVIEW report ", JSON.stringify(wr))
	await _shot(_scenario)
	if _shots != "":
		get_tree().quit(0)
