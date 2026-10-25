## OpenBFME. GPL-3.0.
## Lane MENUFIX-2: OpenBFME's own lines over the menus follow the window's size (scripts/menu_text.gd): the corner lines' 11 stage pixels and a movie's
## error text (scripts/movie_player.gd, 14 stage pixels) scale with min(width / 1024, height / 768), as RotWK stretches its 1024 x 768 menus; the movie
## error follows a resize while it shows (Sol's MENUFIX-1 follow-up). One "MENUFIX2 ok|FAIL" line per check; "MENUFIX2 PASS" / "MENUFIX2 FAIL" last.
## Headless, no game files: the shell is not booted, so the face stays Godot's (the sizes are the property here).
extends SceneTree

const MenuText := preload("res://scripts/menu_text.gd")

var _ok := true


func _init() -> void:
	_run.call_deferred()


func _check(what: String, cond: bool, detail := "") -> void:
	print("MENUFIX2 %s %s%s" % ["ok  " if cond else "FAIL", what, ": " + detail if not cond or detail != "" else ""])
	_ok = _ok and cond


func _run() -> void:
	# the scale: 1920 x 1080 is limited by its height (1080 / 768 = 1.40625), 2560 x 1440 too (1.875), 1280 x 1024 by its width (1.25)
	_check("scale 1920x1080", MenuText.scale_of(Vector2(1920, 1080)) == 1.40625)
	_check("scale 2560x1440", MenuText.scale_of(Vector2(2560, 1440)) == 1.875)
	_check("scale 1280x1024", MenuText.scale_of(Vector2(1280, 1024)) == 1.25)
	# a corner line: 11 stage pixels -> 15 px at 1080p (15.47), 21 px at 1440p (20.6); the colour is the menus' label colour
	var line := Label.new()
	root.add_child(line)
	var errors: Array = []
	MenuText.apply(line, null, Vector2(1920, 1080), MenuText.CORNER_PX, errors)
	_check("corner line 1080p", line.get_theme_font_size("font_size") == 15, str(line.get_theme_font_size("font_size")))
	_check("corner line colour", line.get_theme_color("font_color") == MenuText.COLOR)
	MenuText.apply(line, null, Vector2(2560, 1440), MenuText.CORNER_PX, errors)
	_check("corner line 1440p", line.get_theme_font_size("font_size") == 21, str(line.get_theme_font_size("font_size")))
	_check("no shell: no face asked, nothing reported", errors.is_empty(), str(errors))
	# a movie's error text: 14 stage pixels; it follows the window while it shows
	var player: Node = load("res://scripts/movie_player.gd").new()
	root.add_child(player)
	var label := Label.new()
	root.add_child(label)
	root.size = Vector2i(1920, 1080)
	await process_frame
	player._size_error(label)
	_check("movie error 1080p", label.get_theme_font_size("font_size") == 20, str(label.get_theme_font_size("font_size"))) # 14 * 1.40625 = 19.7
	root.size = Vector2i(2560, 1440)
	await process_frame
	player._size_error(label)
	_check("movie error after a resize to 1440p", label.get_theme_font_size("font_size") == 26, str(label.get_theme_font_size("font_size"))) # 26.25
	print("MENUFIX2 PASS" if _ok else "MENUFIX2 FAIL")
	quit(0 if _ok else 1)
