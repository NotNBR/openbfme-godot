## Lane UBER-1: the Uber performance mode's game gate (docs/UBER.md), scripted: game.gd --auto --map=<an 8-player map> --uber1=<troops>
## [--uber1-seconds=S] [--options-file=F with OpenBFMEUberPerformance = yes / no]. One count per run (a second battle would be made on top of the
## first: run the game again for each count). In the real client (the logic on its worker, the
## replay recording and its per-frame hash, drawables, terrain, HUD): two armies of hordes made in the middle of the map, the local player's facing the
## opponent's, until GameWorld.get_census() counts at least that many living troops (horde members one by one); every horde ordered to attack the
## horde facing it (GameWorld.order_attack: the player command path); 3 s to settle, then the render frames are timed for S seconds (default 20).
## Prints per count "UBER1 battle <n>: ..." with the average fps, the 1% low (the fps of the 99th percentile frame), the worst frame, the logic frames
## run per second (5 = the logic kept its clock), the living troops at the start and the end of the window, the profile and the renderer; the
## owner's bar is 144 fps with the 1% low at 144 or more (the line says met / missed: a measurement, not a failure). "UBER1 RESULT: <n> ok, <m>
## failed" ends the run (a failure is a battle that could not be made or measured).
extends "res://scripts/scenario_player.gd"

var game: Node
var hud: Node
var world: Node
var _profile_log := "" # optional buffered battle-only diagnostics; written after the timed window
var _action := "battle" # --uber1-action=move with allied lobby slots: mass movement, no warm-up
var _move_pattern := "crossing"
var _move_spacing := 75.0
var _move_field := "retail"
var _move_warmup := 20

const HORDES := ["GondorFighterHorde", "GondorFighterHorde", "GondorTowerShieldGuardHorde", "GondorArcherHorde"]
const FOES := ["MordorFighterHorde", "MordorFighterHorde", "MordorFighterHorde", "MordorArcherHorde"]
const SPACING := 75.0
const GAP := 160.0
const MARGIN := 200.0


func _logic_steps(frames: int) -> void:
	# game._step counts render frames; preparation here needs actual logic ticks.
	var target: int = world.get_presented_frame() + frames
	while world.get_presented_frame() < target:
		await game.get_tree().process_frame


func _run(p_game: Node, troops: int) -> void:
	game = p_game
	hud = game._hud
	world = game._world
	var seconds := 20.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--uber1-seconds="):
			seconds = a.substr(16).to_float()
		elif a.begins_with("--uber1-profile-log="):
			_profile_log = a.trim_prefix("--uber1-profile-log=")
		elif a.begins_with("--uber1-action="):
			_action = a.trim_prefix("--uber1-action=")
		elif a.begins_with("--uber1-move-pattern="):
			_move_pattern = a.trim_prefix("--uber1-move-pattern=")
		elif a.begins_with("--uber1-move-spacing="):
			_move_spacing = a.trim_prefix("--uber1-move-spacing=").to_float()
		elif a.begins_with("--uber1-move-field="):
			_move_field = a.trim_prefix("--uber1-move-field=")
		elif a.begins_with("--uber1-move-warmup="):
			_move_warmup = a.trim_prefix("--uber1-move-warmup=").to_int()
	await _run_scenarios(PackedStringArray(["battle %d" % troops]), [_battle.bind(troops, seconds)])


func _scenario_names(request: Variant) -> PackedStringArray:
	return PackedStringArray(["battle %d" % int(request)])


func _local_index() -> int:
	for p in world.get_economy().get("players", []):
		if p.name == game._local_name:
			return int(p.index)
	return -1


func _enemy_index() -> int:
	for p in world.get_economy().get("players", []):
		if p.playable and p.name != game._local_name:
			return int(p.index)
	return -1


func _battle(troops: int, seconds: float) -> String:
	if _action not in ["battle", "move"]:
		return "unknown workload: " + _action
	var me := _local_index()
	var foe := _enemy_index()
	if me < 0 or foe < 0:
		return "no local player or opponent"
	var census: Dictionary = world.get_census()
	if not census.has("extent_x"):
		return "no census / extent (no game)"
	var cx: float = float(census.extent_x) * 0.5
	var cy: float = float(census.extent_y) * 0.5
	if _action == "move" and _move_spacing <= 0.0:
		return "movement spacing must be positive"
	var spacing := _move_spacing if _action == "move" else SPACING
	var rows := maxi(1, int((float(census.extent_y) - 2.0 * MARGIN) / spacing))
	var base_troops: int = int(census.troops)
	var base_hordes: int = int(census.battalions)
	var west: Array = []
	var east: Array = []
	var west_goals: Array[Vector2] = []
	var east_goals: Array[Vector2] = []
	var t0 := Time.get_ticks_msec()
	var column := 0
	var made := 0
	while made < troops:
		var dx := GAP + spacing * column
		if cx - dx < MARGIN:
			return "%d troops do not fit the map (%d made)" % [troops, made]
		for r in range(rows):
			var y := MARGIN + spacing * r + float(column % 2) * spacing * 0.5
			var a: int = world.create_object(HORDES[0] if _move_field == "open" else HORDES[(r + column) % 4], me, cx - dx, y, 0.0)
			var facing := 0.0 if _action == "move" and _move_pattern == "parallel" else PI
			var b: int = world.create_object(HORDES[0] if _move_field == "open" else FOES[(r + column) % 4], foe, cx + dx, y, facing)
			if a <= 0 or b <= 0:
				return "create_object failed: %s" % [str(world.get_command_errors()) if world.has_method("get_command_errors") else "?"]
			west.append(a)
			east.append(b)
			west_goals.append(Vector2(cx + dx, y))
			east_goals.append(Vector2(cx - dx, y))
			if west.size() % 16 == 0:
				var population: Dictionary = world.get_census()
				made = int(population.troops) - base_troops
				if _action == "move":
					made -= int(population.battalions) - base_hordes # HORDE controllers inherit INFANTRY
				if made >= troops:
					break
		var population: Dictionary = world.get_census()
		made = int(population.troops) - base_troops
		if _action == "move":
			made -= int(population.battalions) - base_hordes
		column += 1
	var spawn_s := (Time.get_ticks_msec() - t0) / 1000.0
	if _action == "move" and _move_pattern == "parallel":
		var distance := 2000.0
		for goal in west_goals:
			distance = minf(distance, float(census.extent_x) - MARGIN - goal.x)
		if distance <= 100.0:
			return "no room for parallel movement"
		for i in range(west_goals.size()):
			var west_x := east_goals[i].x
			var east_x := west_goals[i].x
			west_goals[i].x = west_x + distance
			east_goals[i].x = east_x + distance
	await game._step(4)
	if _action == "move" and _move_field == "open":
		await _logic_steps(2)
	hud.camera_look_at(Vector2(cx, cy))
	var start_census: Dictionary = {}
	var f0 := 0
	var waits0: Dictionary = {}
	var win0: Dictionary = {}
	var move_w0 := 0
	if _action == "move":
		# Observe before orders; do not let settling or a blocking census hide the burst.
		start_census = world.get_census()
		f0 = world.get_presented_frame()
		world.reset_logic_wait_sites()
		waits0 = world.get_frame_timings()
		win0 = world.get_client_window_stats()
		move_w0 = Time.get_ticks_usec()
	var command_start := Time.get_ticks_usec()
	for i in range(west.size()):
		if _action == "move":
			var a: Dictionary = world.order_move([west[i]], west_goals[i].x, west_goals[i].y)
			var b: Dictionary = world.order_move([east[i]], east_goals[i].x, east_goals[i].y)
			if not a.get("ok", false) or not b.get("ok", false):
				return "move command refused: %s / %s" % [a, b]
		else:
			world.order_attack([west[i]], east[i])
			world.order_attack([east[i]], west[i])
	var command_ms := (Time.get_ticks_usec() - command_start) / 1000.0
	var motion_begin: Dictionary = {}
	var motion_rows: Array = []
	if _action == "move" and _move_field == "open":
		await _logic_steps(_move_warmup)
		motion_begin = world.profile_army_motion(west + east)
		if int(motion_begin.get("tracked_troops", 0)) < troops:
			return "motion probe did not register the requested soldiers: %s" % motion_begin
		start_census = world.get_census()
		f0 = world.get_presented_frame()
		world.reset_logic_wait_sites()
		waits0 = world.get_frame_timings()
		win0 = world.get_client_window_stats()
		move_w0 = Time.get_ticks_usec()
	if _action == "battle":
		await game._step(2)
		var settle := Time.get_ticks_msec()
		while Time.get_ticks_msec() - settle < 3000:
			await game.get_tree().process_frame
	# the window
		start_census = world.get_census()
		f0 = world.get_presented_frame()
		world.reset_logic_wait_sites()
		waits0 = world.get_frame_timings()
		win0 = world.get_client_window_stats()
	var times: Array = []
	var profile_rows: Array = []
	# lane RENDERWAIT-1: the render's waits on the logic worker in the window (by site), and per second of the window the render frames against the
	# logic frames (non-blocking reads only: get_frame_timings, get_presented_frame)
	var seconds_rows: Array = []
	var row := {"frames": 0, "worst_render": 0.0, "logic0": world.get_presented_frame(), "worst_worker": 0.0}
	var w0 := move_w0 if _action == "move" else Time.get_ticks_usec()
	var last := w0
	var row_start := w0
	while Time.get_ticks_usec() - w0 < int(seconds * 1000000.0):
		await game.get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		times.append(ms)
		last = now
		var ft: Dictionary = world.get_frame_timings()
		if not motion_begin.is_empty():
			var motion: Dictionary = world.profile_army_motion()
			if motion.get("sampled", false):
				motion_rows.append(motion)
		if not _profile_log.is_empty():
			# get_frame_timings/get_presented_frame are non-blocking snapshots. A worker's
			# last completed frame may repeat across render frames; these are not new ticks.
			var detail := {"elapsed_us": now - w0, "interval_ms": ms,
				"logic_frame": world.get_presented_frame(), "timings": ft}
			if hud.has_method("get_frame_timings"):
				detail["hud"] = hud.get_frame_timings()
			if _action == "move":
				var poses: Array = []
				# Fixed population, non-blocking render-side reads; never select the most active objects anew.
				for k in range(8):
					var id: int = west[mini(west.size() - 1, int(k * west.size() / 8))]
					var pose: Dictionary = world.get_render_pose(id)
					pose["id"] = id
					poses.append(pose)
				detail["poses"] = poses
			profile_rows.append(detail)
		row.frames += 1
		row.worst_render = maxf(row.worst_render, ms)
		row.worst_worker = maxf(row.worst_worker, float(ft.get("worker_frame_ms", 0.0)))
		if now - row_start >= 1000000:
			row["logic"] = world.get_presented_frame() - int(row.logic0)
			seconds_rows.append(row)
			row = {"frames": 0, "worst_render": 0.0, "logic0": world.get_presented_frame(), "worst_worker": 0.0}
			row_start = now
	var motion_end: Dictionary = {}
	if not motion_begin.is_empty():
		motion_end = world.profile_army_motion()
		if motion_end.get("sampled", false):
			motion_rows.append(motion_end)
	var wall := (Time.get_ticks_usec() - w0) / 1000000.0
	var waits1: Dictionary = world.get_frame_timings()
	var win1: Dictionary = world.get_client_window_stats()
	var logic_frames: int = world.get_presented_frame() - f0 # the frames completed in the window (get_frame would wait for the worker's backlog)
	print("UBER1 waits %d: %d render-side waits on the logic worker in the window, %.1f ms (%d contended publication locks)" % [troops,
		int(waits1.get("logic_waits", 0)) - int(waits0.get("logic_waits", 0)), float(waits1.get("logic_wait_ms", 0.0)) - float(waits0.get("logic_wait_ms", 0.0)),
		int(waits1.get("contended_locks", 0)) - int(waits0.get("contended_locks", 0))])
	print("UBER1 client windows %d: %d render frames held the logic (the HUD's, audio's and effects' live work), %d found the worker inside a frame; the worker held %d times (%d timed out), %.1f ms with a frame to run (%.1f ms per logic frame); the longest window %.1f ms (S-4280)" % [troops,
		int(win1.get("opened", 0)) - int(win0.get("opened", 0)), int(win1.get("missed", 0)) - int(win0.get("missed", 0)), int(win1.get("parks", 0)) - int(win0.get("parks", 0)),
		int(win1.get("park_timeouts", 0)) - int(win0.get("park_timeouts", 0)), float(win1.get("worker_held_ms", 0.0)) - float(win0.get("worker_held_ms", 0.0)),
		(float(win1.get("worker_held_ms", 0.0)) - float(win0.get("worker_held_ms", 0.0))) / maxf(1.0, logic_frames), float(win1.get("max_window_ms", 0.0))])
	for w in world.get_logic_wait_sites():
		print("UBER1 wait site %s: %d waits, total %.1f ms, worst %.1f ms" % [w.site, w.count, w.total_ms, w.worst_ms])
	print("UBER1 seconds %d: second | render frames | worst render frame ms | logic frames presented | worst worker logic frame ms" % troops)
	for i in range(seconds_rows.size()):
		var r: Dictionary = seconds_rows[i]
		print("UBER1 second %d | %d | %.1f | %d | %.1f" % [i + 1, r.frames, r.worst_render, r.logic, r.worst_worker])
	var end_census: Dictionary = world.get_census()
	print("UBER1 workload: %s; commands %.3f ms; %d hordes ordered; pattern %s" % [_action, command_ms, west.size() + east.size(), _move_pattern])
	if not _profile_log.is_empty():
		var output := FileAccess.open(_profile_log, FileAccess.WRITE)
		if output == null:
			return "cannot write battle profiling log: %s" % _profile_log
		output.store_string(JSON.stringify({"schema": 1, "profile": world.simulation_profile(), "scenario": _action,
			"move_pattern": _move_pattern, "move_spacing": spacing, "move_field": _move_field, "command_ms": command_ms,
			"motion_begin": motion_begin, "motion_rows": motion_rows, "motion_end": motion_end,
			"requested_troops": troops, "wall_seconds": wall, "logic_frames": logic_frames,
			"census_start": start_census, "census_end": end_census, "waits_before": waits0,
			"waits_after": waits1, "client_before": win0, "client_after": win1,
			"rows": profile_rows}))
		output.close()
	if times.is_empty():
		return "no frames in the window"
	var sorted := times.duplicate()
	sorted.sort()
	var sum := 0.0
	for t in times:
		sum += t
	var n := times.size()
	var p99: float = sorted[mini(n - 1, int(n * 0.99))]
	var worst: float = sorted[n - 1]
	var avg_fps := n / wall
	var low_fps := 1000.0 / maxf(p99, 0.001)
	var met := avg_fps >= 144.0 and low_fps >= 144.0
	print("UBER1 battle %d: profile %s, living troops %d at the window's start, %d at its end (%d hordes made, spawn %.1f s); %d render frames in %.1f s: average %.1f fps (%.2f ms), 1%% low %.1f fps (p99 %.2f ms), worst frame %.2f ms; logic %.2f frames/s (5 = on its clock); window %s, renderer %s, %s; owner's bar 144 fps: %s" % [
		troops, world.simulation_profile(), int(start_census.troops) - base_troops, int(end_census.troops) - base_troops, west.size() + east.size(), spawn_s, n,
		wall, avg_fps, sum / n, low_fps, p99, worst, logic_frames / wall, str(game.get_viewport().get_visible_rect().size), DisplayServer.get_name(),
		RenderingServer.get_video_adapter_name(), "met" if met else "missed"])
	return ""
