# Custom unit rigs

**NOT RETAIL.** An OpenBFME addition for tools, cinematics and prototypes: scripts can read a W3D
unit's hierarchy and pose and replace its bone transforms. It is presentation only. The simulation
never reads it, nothing in the game uses it, and a player notices nothing. Retail behaviour is
unchanged.

The API lives on `W3DInstancer` (`engine/src/GodotDevice/GodotW3DInstancer.h`). A `Skeleton3D`
bridge, `godot/scripts/animation/w3d_unit_rig.gd`, puts Godot's `AnimationPlayer`, `AnimationTree`
and skeleton modifiers on top of it. The instancer keeps drawing the unit with its own meshes and
GPU skinning; only the pose changes hands. No mesh, texture or animation data is copied, and
nothing is written in a W3D format.

## Contract

- **Axes.** Godot model axes: W3D `(x, y, z)` becomes `(x, z, -y)`, Y up, one unit per W3D unit.
  Bone axes are converted the same way (`A M A^T`). The conversion only moves and negates floats,
  so a pose read and written back is bit-identical.
- **Spaces.** `rest` is relative to the parent pivot. Poses are model space: the pivot's transform
  in the model, without the instance's placement. `bounds` is in the pivot's own frame.
- **Rigid bones.** A pose transform must be a rotation plus a translation. Scale, shear (beyond
  1e-4, the rounding of a composed pose), reflections and non-finite values are refused, because
  the W3D skinning assumes rigid bones. Use the instance transform to size a whole unit.
- **Precedence.** A rig pose replaces the clip's transforms, and the bone spins, until it is
  cleared with an empty array. `set_instance_clip` and `set_instance_pose` still change the clip
  underneath: its pivot visibility and fade keep applying, and it is what returns when the pose is
  cleared. A held pose is not evaluated again as the clock runs.
- **Timing.** Reads are "as of the last update": call `update_now()` after posing (the automatic
  update does it once per frame).
- **Clip names** follow `set_instance_clip`: `HIERARCHY.CLIP`, or a bare clip name resolved through
  the model's hierarchy (stop S-024).
- **Errors.** A call that fails returns an empty value or false, changes nothing, and records the
  reason in `get_errors()`. There are no silent defaults. A batch is checked as a whole before any
  instance changes.

## Native API

| Call | Returns |
|---|---|
| `get_model_rig(model)` | One dictionary per pivot, parents first: `name`, `parent` (-1 for the root), `rest`, `vertices` (the drawn vertices the pivot carries most), `bounds` (their AABB in the pivot's frame, bind pose). It tells a long thin weapon pivot from a cape pivot without a naming convention. |
| `get_clip_rig_pose(model, clip, frame)` | A clip's model-space pose at a frame (0 .. frames - 1, fractions interpolate), without an instance. |
| `get_instance_model(instance)` | The model the instance was added with. |
| `get_instance_transform(instance)` | The placement given to `add_instance` / `set_instance_transform`. |
| `find_model_instances(name)` | The live instances of every model of that name, case-insensitive, in creation order. An unknown name finds none (not an error). |
| `get_instance_rig_pose(instance)` | The instance's model-space pose. |
| `set_instance_rig_pose(instance, pose)` | Holds `pose` (one transform per pivot), or clears it with `[]`. |
| `set_instances_rig_pose(instances, pose)` | The same pose for several instances of one hierarchy; they share one copy. |

`remove_instance` releases a held pose; clearing a removed instance succeeds. The model rig's skin
data is computed on the first `get_model_rig` call per model, so models that are never asked pay
nothing.

## The Skeleton3D bridge

```gdscript
const UnitRig = preload("res://scripts/animation/w3d_unit_rig.gd")

var rig: Skeleton3D = UnitRig.new()
rig.name = "Rig"
actor.add_child(rig)
if rig.attach(instancer, instance_id) != OK:
	push_error(rig.last_error)

var player := AnimationPlayer.new()
actor.add_child(player)          # tracks are relative to actor: "Rig:<pivot name>"
player.add_animation_library("custom", library)
player.play("custom/lift")
```

- `attach` builds one bone per pivot (names, parents, rests) and poses them as the instance was at
  the last update. One rig owns an instance at a time; a second one gets `ERR_ALREADY_IN_USE`.
- Track keys are local bone poses (relative to the parent bone, `Skeleton3D`'s convention) in Godot
  axes. Use `TYPE_POSITION_3D` and `TYPE_ROTATION_3D` tracks; scale tracks are refused.
- After every skeleton update, after the modifier stack, the rig hands its pose to the instancer,
  and one deferred `update_now()` per instancer per frame draws it in the same frame. For manual
  playback (`ANIMATION_CALLBACK_MODE_PROCESS_MANUAL`, `seek`, `advance`), call `flush_pose()` and then
  `update_now()` yourself.
- `detach()`, leaving the tree, or freeing the rig releases the instance to its clip.
- On failure, `last_error` holds the instancer's reason.

Each attached rig is a `Skeleton3D` with Godot's per-frame skeleton processing. For crowds, compute
poses once and hand them to `set_instances_rig_pose` in batches instead of one rig per unit.

Authored `Animation` / `AnimationLibrary` resources are ordinary Godot resources, not W3D clips. Keep
poses captured from the retail models out of the repository: they are derived from game data.

## Tests

- `engine/tests/test_w3d_rig.cpp` (no game files): the axis conversion, the rigidity check and the
  bone skin on synthetic transforms and meshes.
- `godot/tests/custom_rig_test.gd` (manual, needs the user's installs): the API against the retail
  `IUPikeman_SKN` and `GUAragorn_SKN`. It covers the exact vertex count and pike box, the clip pose
  against an instance, the override's hold and release, batches, every refusal with its recorded
  text, and the bridge driven by an `AnimationPlayer`.

  ```text
  godot --headless --path godot --script res://tests/custom_rig_test.gd
  ```
