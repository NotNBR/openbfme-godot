extends SceneTree
# Retail award clips must bind real images and use their locked grayscale mode.
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if OS.get_environment("ROTWK_INSTALL").is_empty() or OS.get_environment("BFME2_INSTALL").is_empty() or OS.get_environment("CAH_TEST_PROFILE").is_empty():
		print("SKIP: set ROTWK_INSTALL, BFME2_INSTALL and CAH_TEST_PROFILE to an empty temporary profile")
		quit(77)
		return
	root.size = Vector2i(1024, 768)
	var fs = ClassDB.instantiate("RetailFileSystem")
	assert(fs.mount_retail().ok)
	var world = ClassDB.instantiate("GameWorld")
	root.add_child(world)
	assert(world.setup(fs).ok)
	var shell = ClassDB.instantiate("AptMenuPlayer")
	root.add_child(shell)
	assert(shell.boot_shell(fs, world, {}).ok)
	assert(shell.set_create_a_hero(world, OS.get_environment("CAH_TEST_PROFILE")).ok)
	shell.set_auto_process(false)
	assert(shell.shell_push("CreateAHero.apt"))
	for i in 80: shell.tick(0.03)
	var level: int = shell.shell_top_level()
	assert(shell.shell_invoke(level, "ShowScreen", ["Manager"]).ok)
	for i in 80: shell.tick(0.03)
	var tab := "Main.mcManagerScreen.Screen.TabNav"
	var button: Dictionary = shell.find_button(level, tab + ".Tab_Nav_Button.UnselectedTabButtons.Awards")
	assert(button.found, str(button))
	shell.post_mouse_move_stage(Vector2(button.x, button.y))
	shell.post_mouse_button(true)
	shell.post_mouse_button(false)
	for i in 80: shell.tick(0.03)
	var image_path := tab + ".ScreenAwards.AwardList.mcAwards.0.Image"
	assert(shell.get_member(level, image_path, "_imageMap").value == "CahAward:Image_0")
	assert(shell.get_member(level, image_path, "_mode").value == "GRAYSCALE")
	shell.render(true)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--shot="): root.get_texture().get_image().save_png(arg.trim_prefix("--shot="))
	print("CAH AWARDS DISPLAY PASS")
	quit()
