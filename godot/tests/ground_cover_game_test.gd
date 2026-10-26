## Live skirmish regression: flags build grass, and actual F7 input toggles it.
extends SceneTree
var failures := 0
func _initialize() -> void:
 call_deferred("run")
func check(ok: bool, label: String) -> void:
 print("LIVE GRASS ", "PASS " if ok else "FAIL ",label)
 if not ok: failures += 1
func run() -> void:
 var game = load("res://scenes/game.tscn").instantiate()
 root.add_child(game)
 current_scene = game
 var cover: Node3D
 var deadline := Time.get_ticks_msec()+120000
 while Time.get_ticks_msec()<deadline:
  var covers := root.find_children("GroundCover","Node3D",true,false)
  if not covers.is_empty() and game.get("_state")==game.State.PLAYING:
   cover=covers[0]
   break
  await process_frame
 check(cover!=null,"grass exists in a running skirmish")
 if cover!=null:
  check(cover.enabled and cover.visible,"launch flag enables grass")
  for i in 2:
   var key := InputEventKey.new()
   key.keycode=KEY_F7
   key.pressed=true
   Input.parse_input_event(key)
   await process_frame
   key=InputEventKey.new()
   key.keycode=KEY_F7
   key.pressed=false
   Input.parse_input_event(key)
   await process_frame
   check(cover.enabled==(i==1),"F7 toggles grass %s" % ("on" if i==1 else "off"))
 print("LIVE GRASS RESULT ",failures)
 quit(0 if failures==0 else 1)
