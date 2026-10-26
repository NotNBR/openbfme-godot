# Custom unit animation API

`godot/scripts/animation/w3d_unit_rig.gd` is an opt-in `Skeleton3D` bridge for a
W3DInstancer instance. It lets Godot's normal `AnimationPlayer`,
`AnimationLibrary`, and procedural bone APIs drive the existing W3D meshes and
shadow geometry. It does not add an editor, replace meshes, or alter simulation.

## Why a bridge

The renderer batches units and skins them with a shared GPU palette; it does not
create a Godot skeleton for every unit. Creating a skeleton only for explicitly
controlled instances preserves that architecture. Godot already provides
[position and quaternion animation tracks](https://docs.godotengine.org/en/4.7/classes/class_animation.html)
and [skeleton modifiers](https://docs.godotengine.org/en/4.7/classes/class_skeletonmodifier3d.html).
There is no separate animation file format or interpolation engine here.

## Use

The engine must provide `get_instance_rig` and `set_instance_rig_pose`. Mount the
user's retail files, create a W3DInstancer, add a model and instance as usual.
Pose it at the desired starting frame before attaching the rig:

```gdscript
const UnitRig = preload("res://scripts/animation/w3d_unit_rig.gd")
const PikeStomp = preload("res://scripts/animation/uruk_pike_stomp.gd")

var rig = UnitRig.new()
rig.name = "Rig"
actor.add_child(rig)
assert(rig.attach(instancer, instance_id) == OK)

var library = AnimationLibrary.new()
library.add_animation("stomp", PikeStomp.create(rig))
var player = AnimationPlayer.new()
actor.add_child(player) # default root is actor; tracks target Rig:BoneName
player.add_animation_library("custom", library)
player.play("custom/stomp")
```

For your own animations, create `Animation.TYPE_POSITION_3D` and
`Animation.TYPE_ROTATION_3D` tracks with paths such as `Rig:BAT_SPINE2`. Keys are
absolute local bone poses, not offsets from rest. Read `rig.get_bone_pose()` to
capture the current pose and use quaternions for rotations. The rest and hierarchy
come from the loaded model. No humanoid retargeting is guessed.

Save authored resources with `ResourceSaver.save(library, path)` and load them
with `ResourceLoader.load(path)`. These are ordinary Godot `.tres` resources;
they are not W3D animations usable by the original BFME2 executable. Do not commit
retail-derived poses or other game assets to the public repository.

For deterministic/manual playback, set the player's process mode to
`AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL`, call `seek(time, true)`
or `advance(delta)`, then `rig.flush_pose()`. Normal playback uploads on
`skeleton_updated`, after the Godot modifier stack. This timing follows
[Skeleton3D's final-pose signal](https://docs.godotengine.org/en/4.7/classes/class_skeleton3d.html).

`rig.detach()` releases the pose override; normal W3D animation resumes at its
current time. Removing the rig from the tree also releases it. Only one bridge
may own an instance; the target is held weakly. The low-level setter is available
for callers with their own pose evaluator, who must coordinate ownership.

## Native boundary

- `set_instances_rig_pose(ids, pose)` validates an entire batch atomically and
  shares one immutable pose across its instances. Call `update_now()` once after
  assigning all batches. Studio's army preview samples at most sixteen timing
  phases per instancer instead of creating a skeleton/player for each soldier.
- `find_model_instances(model_name)` returns live instance IDs for a model,
  case-insensitively, including its house-color variants. IDs belong to that
  instancer and must be queried again after the map/instancer is rebuilt.
- `get_instance_rig(instance)` returns one dictionary per pivot: `name`, `parent`,
  local `rest`, and model-space `pose`. Invalid/removed instances return `[]`.
- `set_instance_rig_pose(instance, Array[Transform3D])` accepts a complete set of
  model-space transforms, or `[]` to clear the override. It validates count,
  finite values and rigid rotation before changing anything. It returns false
  on invalid input or a removed instance.
- Coordinates are Godot model space: Y up, one unit per SAGE world unit.
  The native boundary converts `(x,y,z)` from W3D to `(x,z,-y)`, including bone
  axes. Instance/world placement stays in `set_instance_transform`; root bone
  motion changes the rendered pose, not the unit's simulation position.
- Evaluated W3D visibility and opacity channels are retained. Custom transforms
  replace the final geometry pose, including wheel/bone spins. Visible and shadow
  batches use the same palette. Clearing the override restores normal evaluation.
- Scale/shear/reflections are rejected; W3D skinning assumes rigid bones.
  Use normal instance scaling for overall model size. Nonuniform animated bone
  scaling, arbitrary reparenting, mesh reweighting, and W3D export are out of scope.

Use this for authored units, cinematic groups and prototypes. Each attached rig
has Godot skeleton processing and uploads a full pose; this is not a replacement
for the batched army animation path. AnimationPlayer/AnimationTree integration
is available at the rig, but game orders and GameWorld drawable lifecycle are
not automatically mapped to it.

## Uruk pike stomp example

`uruk_pike_stomp.gd` generates an original 1.4-second loop at runtime from an
upright Isengard pikeman. It raises the weapon with both feet planted, drives it
down at the `impact` marker (0.66 s), recoils and settles. An analytic two-bone solve keeps
hands following the weapon and feet planted while the pelvis moves. The solve
runs while authoring the resource, not during playback. Exact contact keys are
retained between the 30 Hz samples. All poses come from the user's own assets at
runtime; no retail animation data is embedded in source.

Run with `ROTWK_INSTALL` and `BFME2_INSTALL` set:

```text
godot --path godot --script res://tests/uruk_pike_stomp_demo.gd
godot --headless --path godot --script res://tests/custom_rig_test.gd
```

The demo uses three independent rigs sharing one model, with fixed phase offsets
of up to 120 ms to keep the group close without perfect synchronization. Add
`-- --capture-dir=<local folder>` to save one cycle on a GPU backend. Tests cover
pose round trips, parent propagation, instance isolation, invalid input, scale,
ownership, detach, AnimationLibrary save/load, pike/foot contact and loop closure.
