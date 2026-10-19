## Headless test of a direct network game in the Uber performance mode (lane UBER-1): a host (--net-host) and a joiner (--net-join), both with
## OpenBFMEUberPerformance = yes in their Options.ini (--options-file), play 40 logic frames with scripted players. Both take the Uber profile before
## the session opens, the game they start carries it, and both exit 0 (before, the session opened Faithful and prepare_new_game refused the start:
## "the game's simulation profile is faithful, this player's is uber").
##
##   godot --headless --path godot --script res://tests/net_uber_test.gd
##
## Needs ROTWK_INSTALL and BFME2_INSTALL (prints SKIP and exits 77 without). Exit codes: 0 pass, 1 fail, 77 skip.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	var code: int = _run()
	print("NETUBER %s" % ["PASS" if code == 0 else ("SKIP" if code == 77 else "FAIL")])
	quit(code)


func _check(ok: bool, what: String) -> void:
	print("  ", "ok   " if ok else "FAIL ", what)
	if not ok:
		_failures += 1


func _run() -> int:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty():
		print("NETUBER SKIP: ROTWK_INSTALL / BFME2_INSTALL are not set")
		return 77
	var godot_path := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var dir := OS.get_user_data_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	# both players' own Options.ini with the Uber mode on (the player's setting, not a command line switch)
	var options := "%s/net_uber_options.ini" % dir
	var f := FileAccess.open(options, FileAccess.WRITE)
	f.store_string("OpenBFMEUberPerformance = yes\n")
	f.close()
	var port := 33000 + (Time.get_ticks_msec() % 2000)
	# two processes started directly (no shell, so it runs under Windows too), each logging through Godot's own --log-file
	var common := ["--headless", "--path", project]
	var host_args: Array = common + ["--log-file", "%s/net_uber_host.log" % dir, "--", "--options-file=%s" % options, "--net-host=%d" % port, "--seed=9",
		"--net-slots=human:FactionMen:0:0;human:FactionMordor:1:1", "--net-script", "--net-frames=40"]
	var join_args: Array = common + ["--log-file", "%s/net_uber_join.log" % dir, "--", "--options-file=%s" % options, "--net-join=127.0.0.1:%d" % port,
		"--net-name=Joiner", "--net-script", "--net-frames=40"]
	for who in ["host", "join"]:
		DirAccess.remove_absolute("%s/net_uber_%s.log" % [dir, who])
	var pids := { "host": OS.create_process(godot_path, PackedStringArray(host_args)) }
	OS.delay_msec(3000)
	pids["join"] = OS.create_process(godot_path, PackedStringArray(join_args))
	var codes := {}
	var deadline := Time.get_ticks_msec() + 600000
	for who in ["host", "join"]:
		var pid: int = pids[who]
		while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
			OS.delay_msec(200)
		codes[who] = str(OS.get_process_exit_code(pid)) if pid > 0 and not OS.is_process_running(pid) else ""
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	for who in ["host", "join"]:
		var log := FileAccess.get_file_as_string("%s/net_uber_%s.log" % [dir, who])
		var rc: String = codes[who]
		_check(rc == "0", "%s exits 0 (got '%s')" % [who, rc])
		var synced := log.find("GAME simulation profile: uber (ok)")
		var opened := log.find("GAME NET open:")
		_check(synced >= 0 and opened > synced, "%s: the Uber profile is taken before the session opens" % who)
		_check(not log.contains("GAME FAIL"), "%s: the game starts (no profile mismatch)" % who)
		_check(log.contains("\"desyncs\":[]"), "%s: 40 frames without a desync" % who)
		if rc != "0":
			for line in log.split("\n"):
				if line.begins_with("GAME FAIL") or line.contains("handle_crash"):
					print("    ", line)
	return 0 if _failures == 0 else 1
