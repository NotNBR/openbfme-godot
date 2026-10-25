## OpenBFME. GPL-3.0.
## Lane MENUFIX-1: OpenBFME's own lines over the menus (the version corner and its Logs link, "N players online", the online test note, the rules line on
## the loading screen, a movie's error) in the menus' own look. NOT RETAIL: retail has none of these lines; they follow the retail menus' style:
##   face    retail's menu face Albertus MT through the shell's font substitution (AptMenuPlayer.shell_font: the archives' AlbertusMT.otf, as the
##           menus and the replay controls draw it)
##   size    stage pixels scaled as the menus are: RotWK stretches its 1024 x 768 stage to the window (S-4555), a text grows with
##           min(width / 1024, height / 768) like the menus' tool tip (CursorTooltip.cpp)
##   colour  the menus' label colour (Options.apt's labels 0xFFBFEDFF, OpenBFMEOptionsPage.h) with a black shadow
## Before, they were Godot's default face at fixed window pixels: another face than every menu, and a quarter smaller at 2560 x 1440 than at 1920 x 1080.
extends RefCounted

const STAGE := Vector2(1024, 768)
const FACE := "Albertus MT"
const COLOR := Color(0xBF / 255.0, 0xED / 255.0, 1.0, 0.9)
const SHADOW := Color(0, 0, 0, 0.9)
const CORNER_PX := 11.0 # a corner line, in stage pixels
const MARGIN_PX := 5.0 # a corner line's distance from the window's edge, in stage pixels


## the menus' scale at a window of `size`: stage pixels to window pixels
static func scale_of(size: Vector2) -> float:
	return minf(size.x / STAGE.x, size.y / STAGE.y)


## The face, size, colour and shadow of a line of `stage_px` stage pixels at a window of `size`. Returns the line's height in window pixels.
## A shell without the face (the archives do not carry it) keeps Godot's face and says so once in `errors` (no silent default).
static func apply(control: Control, shell: Object, size: Vector2, stage_px: float, errors: Array, color: Color = COLOR) -> float:
	var k := scale_of(size)
	var px := maxi(8, roundi(stage_px * k))
	var font: Font = null
	if shell != null:
		var face: Dictionary = shell.shell_font(FACE, px)
		if face.get("font") != null and not face.get("fallback", false):
			font = face.font
		elif not errors.has(FACE):
			errors.append(FACE)
	if font != null:
		control.add_theme_font_override("font", font)
	control.add_theme_font_size_override("font_size", px)
	control.add_theme_color_override("font_color", color)
	if control is LinkButton:
		control.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	control.add_theme_color_override("font_shadow_color", SHADOW)
	var shadow := maxi(1, roundi(k))
	control.add_theme_constant_override("shadow_offset_x", shadow)
	control.add_theme_constant_override("shadow_offset_y", shadow)
	var f: Font = font if font != null else control.get_theme_default_font()
	return f.get_height(px)
