## Fail-closed runner for the scripted scenario players. A GDScript error can
## return null or strand an await; neither is a successful empty String result.
extends RefCounted

class ScriptErrors extends Logger:
	var _mutex := Mutex.new()
	var _first := ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_SCRIPT:
			return
		_mutex.lock()
		if _first.is_empty():
			_first = "%s (%s:%d in %s)" % [rationale if not rationale.is_empty() else code, file, line, function]
		_mutex.unlock()

	func first() -> String:
		_mutex.lock()
		var result := _first
		_mutex.unlock()
		return result


var ok_count := 0
var fail_count := 1 # pending/aborted runs must not look successful to game.gd
var scenario_timeout_seconds := 3600.0
var _scenario_tree: SceneTree
var _scenario_errors: ScriptErrors
var _scenario_prefix := ""
var _scenario_expected := PackedStringArray()
var _scenario_reported := 0
var _scenario_failures := 0
var _scenario_returned := false
var _scenario_deadline := 0


func _scenario_names(request: Variant) -> PackedStringArray:
	return PackedStringArray([str(request)]) if request is String else PackedStringArray(request)


func _scenario_label() -> String:
	return get_script().resource_path.get_file().trim_suffix("_player.gd").to_upper()


func run(p_game: Node, request: Variant) -> void:
	ok_count = 0
	fail_count = 1
	_scenario_reported = 0
	_scenario_failures = 0
	_scenario_returned = false
	_scenario_tree = p_game.get_tree()
	_scenario_prefix = _scenario_label()
	_scenario_expected = _scenario_names(request)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario-timeout="):
			scenario_timeout_seconds = arg.trim_prefix("--scenario-timeout=").to_float()
	if not is_finite(scenario_timeout_seconds) or scenario_timeout_seconds <= 0.0:
		_scenario_expected = PackedStringArray(["configuration"])
		_record_scenario("scenario timeout must be finite and positive")
	elif _scenario_expected.is_empty():
		_scenario_expected = PackedStringArray(["<empty scenario list>"])
		_record_scenario("no scenarios requested")
	else:
		_scenario_errors = ScriptErrors.new()
		OS.add_logger(_scenario_errors)
		_reset_scenario_deadline()
		_execute_scenarios.call_deferred(p_game, request)
		while not _scenario_returned and _scenario_errors.first().is_empty() and Time.get_ticks_msec() < _scenario_deadline:
			await _scenario_tree.process_frame
		var reason := _scenario_errors.first()
		if not reason.is_empty():
			reason = "script error: " + reason
		elif not _scenario_returned:
			reason = "scenario did not complete within %.1f seconds (no result)" % scenario_timeout_seconds
		else:
			reason = "scenario produced no result (runner ended before reporting it)"
		while _scenario_reported < _scenario_expected.size():
			_record_scenario(reason)
		if (not _scenario_errors.first().is_empty() or not _scenario_returned) and _scenario_failures == 0:
			_record_scenario(reason)
		OS.remove_logger(_scenario_errors)
		_scenario_errors = null
	fail_count = _scenario_failures
	print("%s RESULT: %d ok, %d failed" % [_scenario_prefix, ok_count, fail_count])
	if fail_count != 0:
		_scenario_tree.quit(1)


func _reset_scenario_deadline() -> void:
	_scenario_deadline = Time.get_ticks_msec() + int(scenario_timeout_seconds * 1000.0)


func _execute_scenarios(p_game: Node, request: Variant) -> void:
	await call("_run", p_game, request)
	_scenario_returned = true


func _run_scenarios(names: PackedStringArray, calls: Array[Callable] = []) -> void:
	if names != _scenario_expected or _scenario_reported != 0 or (not calls.is_empty() and calls.size() != names.size()):
		_record_scenario("scenario list/result count does not match the requested run")
		return
	for i in names.size():
		_reset_scenario_deadline()
		var action := Callable(self, "_scenario_" + names[i]) if calls.is_empty() else calls[i]
		if not action.is_valid():
			_record_scenario("no such scenario")
			continue
		var result: Variant = await action.call()
		if not _scenario_errors.first().is_empty():
			return # the outer guard reports this and every unreported scenario
		if not result is String:
			_record_scenario("scenario died or returned no String result (final assertion not reached)")
		else:
			_record_scenario(result)


func _record_scenario(reason: String) -> void:
	var name := _scenario_expected[mini(_scenario_reported, _scenario_expected.size() - 1)]
	if _scenario_reported >= _scenario_expected.size():
		reason = "unexpected extra result: " + reason
	_scenario_reported += 1
	if reason.is_empty():
		ok_count += 1
		print("%s %s: ok" % [_scenario_prefix, name])
	else:
		_scenario_failures += 1
		print("%s %s: FAIL %s" % [_scenario_prefix, name, reason])
