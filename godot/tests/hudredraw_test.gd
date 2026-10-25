## Lane HUDREDRAW-1: the spell store held open costs the frame about what the HUD costs with it closed (the owner's playtest on build 0dbea3d2ff: opening the
## spell book dropped the game to ~30 fps; the store's looping `_active` buttons made the shell player redraw every Apt level, the Palantir too, every frame).
##
##   godot --headless --path godot --script res://tests/hudredraw_test.gd
##
## Plays a skirmish with the scripted scenario spell3_player.gd hudredraw: power points given (the harness's logged test hook), 300 render frames with the
## store closed, the store opened by the Palantir's powers button, 300 frames open. FAIL when a rebuild of the open window draws the whole canvas again, when
## the Palantir or the store draws again more than 4 of its 50-odd segments a frame on average (the pulsing powers button and the money counter, the three
## looping `_active` buttons: everything else is kept), when the Apt / window manager note lists grow in either window, or when the open window's main thread
## CPU per frame exceeds the closed one's by more than x1.6 (a regression guard: headless there is no canvas submission, the part the kept segments save).
## Its SPELL3 lines are printed. Needs ROTWK_INSTALL and BFME2_INSTALL (else SKIP, exit 77).
## Exit codes: 0 pass, 1 fail, 77 skip.
extends SceneTree


func _initialize() -> void:
	var code: int = _run()
	print("HUDREDRAW %s" % ["PASS" if code == 0 else ("SKIP" if code == 77 else "FAIL")])
	quit(code)


func _run() -> int:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty():
		print("SKIP: set ROTWK_INSTALL and BFME2_INSTALL")
		return 77
	if not ClassDB.class_exists("GameWorld"):
		print("FAIL: the openbfme extension is not loaded")
		return 1
	var output: Array = []
	# headless: the window is 64 x 64 unless sized (every HUD pick would land at its middle); the CPU timing is the main thread's (a headless run has no GPU)
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--res=1280x720", "--no-intro", "--no-update-check", "--auto",
		"--faction=FactionMen", "--seed=42", "--spell3=hudredraw", "--hudredraw-budget=0.6"]
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = "".join(output)
	var ok := false
	for line in text.split("\n"):
		if line.begins_with("SPELL3") or line.begins_with("GAME FAIL"):
			print("    " + line)
		if line == "SPELL3 hudredraw: ok":
			ok = true
	print("  %s game.tscn --spell3=hudredraw exits %d" % ["ok  " if code == 0 else "FAIL", code])
	print("  %s SPELL3 hudredraw: ok" % ["ok  " if ok else "FAIL"])
	return 0 if code == 0 and ok else 1
