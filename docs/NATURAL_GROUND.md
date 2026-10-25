# Natural ground and camera-local grass

Press **F8** while playing to compare natural ground with the original terrain.
It starts off by default. To start with it on, pass `--natural-ground` after
Godot's `--` separator, or set `openbfme/rendering/natural_ground=true` in the
project settings. `--natural-ground=off` explicitly disables it at startup.
The F8 setting lasts for the current session and applies to subsequently loaded maps.

Example from the repository root (PowerShell, with `$env:GODOT` set):

```powershell
& $env:GODOT --path godot -- --natural-ground
```

This is an artistic rendering option for the Godot port. It adds world-anchored
short-turf relief, broad dry patches, broken bare-earth patches, reduced turf
gloss, and irregular grass-to-other-material transitions. The original map's
palette, painted material boundaries, fog, shroud and selection overlays still
apply. Steep ground fades back to the original treatment. Fine detail fades
with pixel footprint and uses mipmaps to reduce distant shimmer.

The F8 option changes the continuous surface. The separate F7 grass option below adds geometry.
Existing grass/bush objects stay as they are. Tree litter, shoreline moisture,
road wear, interactive trampling and full authored material height maps are
outside this version. Soil is procedural colour/relief variation, rather than
a new independently painted terrain layer. The blend uses procedural turf
height, not recovered height data from the original terrain textures.

## Choosing surfaces

Edit `godot/assets/natural_ground/profiles.json`. Case-insensitive substrings
in `include` identify meadow terrain class names. `exclude` takes precedence;
exact lower-case class names in `overrides` take final precedence, for example:

```json
"overrides": {"grasscustom01": true, "grasscustomruins02": false}
```

These rules operate on terrain class names, not pixel colours. The map builder's
`natural_ground` report lists the selected classes. Mixed materials within a
selected class receive that class's treatment; use an override to exclude such
a class. Separate road rendering is unaffected. This is not a portable retail
`.big` mod; the Godot shader provides the additional detail path.

The original detail asset contains no retail art. Regenerate it with:

```powershell
python tools/art/generate_turf_detail.py
```

Its channels are normal X/Y, turf height, and reserved soil grain. Keep its
import lossless, with mipmaps enabled and normal-map conversion disabled;
normal-map conversion would destroy the packed height channel.

## Verification

```powershell
& $env:GODOT --path godot --script res://tests/natural_ground_test.gd
& $env:GODOT --path godot --script res://tests/shader_test.gd
```

These require a GPU renderer. The first checks changed turf, pixel-identical
excluded stone, restoration when disabled or at zero strength, debug output,
F8 and shroud. It can save comparison images with
`-- --ground-captures=ABSOLUTE_DIRECTORY`. Add
`--ground-map="map mp harlindon"` to build and capture a real map using the
configured retail installations. The existing shader test checks retail
gamma blending, layer triangulation and cliff wrapping.


## Blade grass (F7)

Start with `--ground-cover` after Godot's `--` separator. F7 toggles the blade
field independently of the F8 texture treatment. Both options default off;
`--natural-ground --ground-cover` enables both. This is an optional Godot-port
visual enhancement, not a retail `.big` mod or simulation fix.

Inspired by the camera-local approach shown in the Dinolords grass renderer:
https://80.lv/articles/kacper-szwajka-s-custom-grass-renderer-for-unity-based-dinosaur-rts

The field uses individual five-vertex, three-triangle blades. Reusable
32-unit near tiles and 128-unit distant tiles cover the visible camera frustum,
including shallow views. There is no circle or rectangle around the camera's
ground focus that cuts the field off. Tiles share two 4096-slot instance buffers
(about 384 KiB of transforms); the node pool grows to the largest visible view
seen and is reused. Terrain and frustum bounds limit tile selection.

Projected blade size controls population and a smooth near/far blend in
perspective and orthographic cameras. Slightly wider medium-distance blades
retain coverage. Below roughly 1.5 pixels, blades blend into terrain canopy
shading using the same world-anchored density and palette. The terrain canopy
has no camera-distance cutoff. The 0.325-pixel cutoff doubles the previous
blade distance for a given camera projection. Tile selection updates when the camera moves.
World-position hashing anchors blades when patches recycle. Wind runs on the
GPU. Grass colour primarily follows the sampled terrain; broad density,
height and dry patches break up the lawn appearance.

Map-load guide textures store height, triangle orientation, terrain colour and
meadow eligibility. Placement follows the original terrain triangulation and
material blends. Roads, rivers, standing water and steep ground are excluded.
Grass retains 65% of the sampled terrain colour with a 35% muted meadow tint.
The canopy shares that palette, with
darker roots and varied tips. Fog and shroud apply to the grass. Original
map bushes and other objects remain untouched. MSAA 4x in graphics options
helps fine blade edges; this feature does not override the user's AA choice.
Grass uses alpha-to-coverage instead of screen-space noise, a minimum projected
width (limited to 3x widening), and less wind on unresolved blades to reduce
shimmer. The studio selects MSAA 8x while Grass is enabled and restores its
previous setting afterward. Real-map grass outputs gamma-space colour for the
map compositor; the standalone lab retains linear output.

This version does not yet include unit trails, dynamic building footprints,
interaction bending, or grass shadows. It uses a Godot MultiMesh/vertex-shader
implementation, not the Unity renderer's compute/indirect implementation.
The earlier experimental `grass_clumps.png` is retained but unused.

Verify with `--path godot --script res://tests/ground_cover_test.gd` and optional
`-- --ground-captures=ABSOLUTE_DIRECTORY`. It checks real-map rendering, F7,
shroud, camera recycling, continuous zoom/pan, orthographic LOD, bounded
allocation, far canopy coverage and blade culling, and
reports an off/on viewport GPU comparison. This is not a whole-match benchmark.


## Interactive grass lab

Open `godot/scenes/grass_lab.tscn` as a standalone Godot scene, or run:

```powershell
& $env:GODOT --path godot res://scenes/grass_lab.tscn
```

Nine labelled plots compare 25/50/100 percent population, a soft grass/earth
boundary, a hard stone edge, a winding path, short/tall blades and a 16-degree
slope. Sliders change population, height and wind live. Density comparisons
share the same procedural ground texture. The scene uses the production terrain
and blade shaders, with procedural test textures and a baked eligibility guide;
it does not exercise retail map-file parsing or multi-layer terrain blending.
Grass patches stay fixed here so the selected density remains comparable at
all viewing distances; the real-map ground_cover_test checks camera streaming
and distance LOD separately.

Controls: 1 overview, 2 density row, 3 transitions, 4 height/slope; WASD pans,
right-drag orbits, wheel zooms, G toggles blades, T toggles turf detail, Space
pauses wind. MSAA 4x applies only to this lab viewport. No retail assets required.

Add `-- --lab-smoke --lab-captures=ABSOLUTE_DIRECTORY` to validate the plot
counts and density settings, capture all four views, and exit.
